#!/usr/bin/env bash
# One-shot Buildroot build for the Raspberry Pi 5: same image as br.sh, without the checks.
# Assumes: Ubuntu on WSL2, repo inside the Linux filesystem, ~25 GB free, internet, sudo.
# Settings come from config.env / config.local.env (hostname, Wi-Fi, password, versions).
set -euo pipefail                                                   # stop on the first error
cd "$(dirname "$0")/.." && REPO="$(pwd)"                            # work from the repo root
source config.env                                                   # shared defaults
if [ -f config.local.env ]; then source config.local.env; fi        # your overrides (Wi-Fi etc.)

# ---- Host setup ------------------------------------------------------------
WIN_USER="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' || true)"   # Windows user, for the export at the end
PATH="$(tr ':' '\n' <<<"$PATH" | grep -v -e '^/mnt/' -e ' ' | paste -sd:)"    # drop Windows PATH entries (Buildroot rejects spaces)
sudo apt-get update                                                 # refresh package lists
sudo apt-get install -y build-essential git wget curl rsync bc cpio unzip file \
    python3 libncurses-dev openssl openssh-client ccache            # tools Buildroot needs on the PC

# ---- Paths -----------------------------------------------------------------
BR="$WORK_DIR/buildroot-$BUILDROOT_VERSION"                         # Buildroot source
OUT="$WORK_DIR/br-output"                                           # build output (out-of-tree)
OVL="$WORK_DIR/br-overlay"                                          # files copied into the image
mkdir -p "$WORK_DIR"                                                # create the work dir

# ---- Fetch Buildroot -------------------------------------------------------
[ -d "$BR" ] || git clone --depth 1 --branch "$BUILDROOT_VERSION" \
    https://gitlab.com/buildroot.org/buildroot.git "$BR"            # release tag, latest commit only

# ---- Secrets ---------------------------------------------------------------
[ -f "$SSH_PUBKEY" ] || ssh-keygen -t ed25519 -N "" -f "${SSH_PUBKEY%.pub}"    # SSH key pair, if you have none
if [ -z "$ROOT_PASSWORD" ]; then read -rsp "Root password for the Pi: " ROOT_PASSWORD; echo; fi
ROOT_HASH="$(openssl passwd -6 -stdin <<<"$ROOT_PASSWORD")"          # SHA-512 hash, the only form stored
if [ -n "$WIFI_SSID" ] && [ -z "$WIFI_PSK" ]; then read -rsp "Wi-Fi passphrase for $WIFI_SSID: " WIFI_PSK; echo; fi

# ---- Rootfs overlay (files dropped into the image as-is) -------------------
rm -rf "$OVL" && mkdir -p "$OVL/root/.ssh" "$OVL/usr/sbin"           # start clean
cp -a buildroot/board/overlay/. "$OVL/"                             # motd, chrony.conf, S05rootfs-expand, S45wifi
install -m 600 "$SSH_PUBKEY" "$OVL/root/.ssh/authorized_keys"       # your key -> root login over SSH
install -m 755 common/target/rootfs-expand "$OVL/usr/sbin/"         # first-boot resize script
cat > "$OVL/etc/wpa_supplicant.conf" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=0
update_config=1
${WIFI_COUNTRY:+country=${WIFI_COUNTRY^^}}
EOF
# Wi-Fi network block: assumes a WPA2 network and an SSID without quote characters.
if [ -n "$WIFI_SSID" ]; then
    PSK="$(python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha1", sys.argv[1].encode(), sys.argv[2].encode(), 4096, 32).hex())' "$WIFI_PSK" "$WIFI_SSID")"  # same as wpa_passphrase
    printf 'network={\n    ssid="%s"\n    psk=%s\n}\n' "$WIFI_SSID" "$PSK" >> "$OVL/etc/wpa_supplicant.conf"
fi

# ---- Configuration: stock Pi 5 defconfig + our additions -------------------
mkdir -p "$WORK_DIR/br-generated"                                   # where the combined defconfig goes
DEFCONFIG="$WORK_DIR/br-generated/mylab_rpi5_defconfig"             # stock + ours, last value wins
cat "$BR/configs/raspberrypi5_defconfig" - > "$DEFCONFIG" <<EOF
BR2_DL_DIR="$WORK_DIR/br-dl"
BR2_CCACHE=y
BR2_CCACHE_DIR="$WORK_DIR/br-ccache"
BR2_TARGET_GENERIC_HOSTNAME="$RPI_HOSTNAME"
BR2_TARGET_GENERIC_ISSUE="Welcome to $RPI_HOSTNAME (Buildroot $BUILDROOT_VERSION)"
BR2_TARGET_ENABLE_ROOT_LOGIN=y
BR2_TARGET_GENERIC_ROOT_PASSWD="${ROOT_HASH//\$/\$\$}"
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_OPENSSH_SERVER=y
BR2_PACKAGE_OPENSSH_CLIENT=y
BR2_PACKAGE_OPENSSH_KEY_UTILS=y
BR2_ROOTFS_OVERLAY="$OVL"
BR2_ROOTFS_POST_BUILD_SCRIPT="board/raspberrypi5/post-build.sh $REPO/buildroot/board/post-build.sh"
BR2_ROOTFS_POST_BUILD_SCRIPT_ARGS="$ALLOW_ROOT_PASSWORD_SSH"
BR2_TARGET_ROOTFS_EXT2_SIZE="256M"
BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_MDEV=y
BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI=y
BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI_WIFI=y
BR2_PACKAGE_WIRELESS_REGDB=y
BR2_PACKAGE_IW=y
BR2_PACKAGE_WPA_SUPPLICANT=y
BR2_PACKAGE_WPA_SUPPLICANT_NL80211=y
BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE=y
BR2_PACKAGE_WPA_SUPPLICANT_CLI=y
BR2_PACKAGE_WPA_SUPPLICANT_PASSPHRASE=y
BR2_PACKAGE_UTIL_LINUX=y
BR2_PACKAGE_UTIL_LINUX_BINARIES=y
BR2_PACKAGE_UTIL_LINUX_PARTX=y
BR2_PACKAGE_E2FSPROGS=y
BR2_PACKAGE_E2FSPROGS_RESIZE2FS=y
BR2_PACKAGE_AVAHI=y
BR2_PACKAGE_AVAHI_DAEMON=y
BR2_PACKAGE_AVAHI_DEFAULT_SERVICES=y
BR2_PACKAGE_CHRONY=y
EOF
chmod 600 "$DEFCONFIG"                                              # it contains the password hash
make -C "$BR" O="$OUT" BR2_DEFCONFIG="$DEFCONFIG" defconfig         # expand into the full .config

# ---- Build -----------------------------------------------------------------
make -C "$BR" O="$OUT" BR2_JLEVEL="$JOBS" 2>&1 | tee "$OUT/build.log"   # toolchain, packages, kernel, sdcard.img (30-90 min)

# ---- Export ----------------------------------------------------------------
IMG="$OUT/images/$RPI_HOSTNAME-buildroot-$BUILDROOT_VERSION.img"    # friendlier file name
cp -f "$OUT/images/sdcard.img" "$IMG"                               # copy the card image
WIN_DIR="/mnt/c/Users/$WIN_USER/Downloads/rpi5-images"             # Windows Downloads\rpi5-images
if [ -n "$WIN_USER" ]; then mkdir -p "$WIN_DIR" && cp -f "$IMG" "$WIN_DIR/"; fi   # for Raspberry Pi Imager
echo "Done: $IMG"                                                   # flash it: ./tools/flash.sh buildroot
echo "Then boot the Pi and run: ./tools/verify-ssh.sh"              # finds mylab-rpi5.local and checks everything
