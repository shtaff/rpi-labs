#!/usr/bin/env bash
# One-shot Yocto build for the Raspberry Pi 5: same image as yocto.sh, without the checks.
# Assumes: Ubuntu on WSL2, repo inside the Linux filesystem, ~120 GB free, 16 GB+ RAM, internet, sudo.
# Settings come from config.env / config.local.env; layer versions from yocto/layers.lock.
set -euo pipefail                                                   # stop on the first error
cd "$(dirname "$0")/.." && REPO="$(pwd)"                            # work from the repo root
source config.env                                                   # shared defaults
if [ -f config.local.env ]; then source config.local.env; fi        # your overrides (Wi-Fi etc.)

# ---- Host setup ------------------------------------------------------------
WIN_USER="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' || true)"   # Windows user, for the export at the end
PATH="$(tr ':' '\n' <<<"$PATH" | grep -v -e '^/mnt/' -e ' ' | paste -sd:)"    # drop Windows PATH entries
sudo apt-get update                                                 # refresh package lists
sudo apt-get install -y build-essential chrpath cpio debianutils diffstat file gawk gcc git \
    iputils-ping libacl1 lz4 locales python3 python3-git python3-jinja2 python3-pexpect \
    python3-pip python3-subunit socat texinfo unzip wget xz-utils zstd openssl openssh-client   # Yocto host tools
sudo locale-gen en_US.UTF-8                                         # bitbake requires a UTF-8 locale
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8                          # ...and uses it

# ---- Paths -----------------------------------------------------------------
Y="$WORK_DIR/yocto"                                                 # layers + build dir
BUILD="$Y/build"                                                    # bitbake build directory
mkdir -p "$Y" "$BUILD/conf"                                         # create them

# ---- Fetch the layers at the commits in layers.lock (GitHub mirrors) -------
declare -A GH=(
    [bitbake]=openembedded/bitbake                                  # the build tool
    [openembedded-core]=openembedded/openembedded-core              # core recipes + classes
    [meta-yocto]=yoctoproject/meta-yocto                            # the poky distro
    [meta-raspberrypi]=agherzan/meta-raspberrypi                    # Pi 5 machine, kernel, firmware
)
while read -r name rev _; do
    [ "$(git -C "$Y/$name" rev-parse HEAD 2>/dev/null || true)" = "$rev" ] && continue   # already there
    git init -q "$Y/$name"                                          # empty repo (no-op if it exists)
    git -C "$Y/$name" fetch -q --depth 1 "https://github.com/${GH[$name]}" "$rev"      # just that commit
    git -C "$Y/$name" checkout -q --detach FETCH_HEAD               # check it out
done < <(grep -v -e '^#' -e '^$' yocto/layers.lock)

# ---- Secrets ---------------------------------------------------------------
[ -f "$SSH_PUBKEY" ] || ssh-keygen -t ed25519 -N "" -f "${SSH_PUBKEY%.pub}"    # SSH key pair, if you have none
if [ -z "$ROOT_PASSWORD" ]; then read -rsp "Root password for the Pi: " ROOT_PASSWORD; echo; fi
ROOT_HASH="$(openssl passwd -6 -stdin <<<"$ROOT_PASSWORD")"          # SHA-512 hash, the only form stored
if [ -n "$WIFI_SSID" ] && [ -z "$WIFI_PSK" ]; then read -rsp "Wi-Fi passphrase for $WIFI_SSID: " WIFI_PSK; echo; fi

# ---- Our layer, plus the files generated from your settings ----------------
L="$Y/meta-mylab/recipes-mylab"                                     # our recipes, in the copy
rm -rf "$Y/meta-mylab" && cp -a yocto/meta-mylab "$Y/meta-mylab"    # fresh copy of meta-mylab
install -D -m 644 "$SSH_PUBKEY" "$L/ssh-root-key/files/authorized_keys"        # your key -> root login over SSH
install -m 755 common/target/rootfs-expand "$L/rootfs-expand/files/"           # first-boot resize script
WPA="$L/wifi-config/files/wpa_supplicant-nl80211-wlan0.conf"        # Wi-Fi settings file
cat > "$WPA" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=0
update_config=1
${WIFI_COUNTRY:+country=${WIFI_COUNTRY^^}}
EOF
# Wi-Fi network block: assumes a WPA2 network and an SSID without quote characters.
if [ -n "$WIFI_SSID" ]; then
    PSK="$(python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha1", sys.argv[1].encode(), sys.argv[2].encode(), 4096, 32).hex())' "$WIFI_PSK" "$WIFI_SSID")"  # same as wpa_passphrase
    printf 'network={\n    ssid="%s"\n    psk=%s\n}\n' "$WIFI_SSID" "$PSK" >> "$WPA"
fi
chmod 600 "$WPA"                                                    # holds the network key

# ---- Build configuration ---------------------------------------------------
cat > "$BUILD/conf/bblayers.conf" <<EOF
POKY_BBLAYERS_CONF_VERSION = "2"
LCONF_VERSION = "7"
BBPATH = "\${TOPDIR}"
BBFILES ?= ""
BBLAYERS ?= "$Y/openembedded-core/meta $Y/meta-yocto/meta-poky $Y/meta-raspberrypi $Y/meta-mylab"
EOF
cat > "$BUILD/conf/local.conf" <<EOF
CONF_VERSION = "2"
MACHINE = "raspberrypi5"
DISTRO = "poky"
INIT_MANAGER = "systemd"
DISTRO_FEATURES:append = " wifi"
PACKAGE_CLASSES = "package_ipk"
DL_DIR = "$WORK_DIR/yocto-downloads"
SSTATE_DIR = "$WORK_DIR/yocto-sstate"
BB_NUMBER_THREADS = "$JOBS"
PARALLEL_MAKE = "-j $JOBS"
INHERIT += "rm_work"
ENABLE_UART = "1"
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"
IMAGE_FSTYPES = "wic.xz wic.bmap"
hostname:pn-base-files = "$RPI_HOSTNAME"
MYLAB_ROOT_HASH = "${ROOT_HASH//\$/\\\$}"
MYLAB_ALLOW_ROOT_PASSWORD_SSH = "$ALLOW_ROOT_PASSWORD_SSH"
PATCHRESOLVE = "noop"
EOF
chmod 600 "$BUILD/conf/local.conf"                                  # it contains the password hash

# ---- Build -----------------------------------------------------------------
cd "$Y/openembedded-core"                                           # the env script lives here
set +eu; source ./oe-init-build-env "$BUILD" >/dev/null; set -eu   # puts bitbake on PATH (not strict-mode safe)
bitbake mylab-image                                                 # kernel, packages, rootfs, .wic.xz (2-6 h first time)

# ---- Export ----------------------------------------------------------------
IMG="$WORK_DIR/$RPI_HOSTNAME-yocto-$YOCTO_RELEASE.wic.xz"           # friendlier file name
cp -fL "$BUILD"/tmp/deploy/images/raspberrypi5/mylab-image-raspberrypi5.rootfs.wic.xz "$IMG"   # -L: follow the deploy symlink
WIN_DIR="/mnt/c/Users/$WIN_USER/Downloads/rpi5-images"             # Windows Downloads\rpi5-images
if [ -n "$WIN_USER" ]; then mkdir -p "$WIN_DIR" && cp -f "$IMG" "$WIN_DIR/"; fi   # for Raspberry Pi Imager
echo "Done: $IMG"                                                   # flash it: ./tools/flash.sh yocto
echo "Then boot the Pi and run: cd $REPO && ./tools/verify-ssh.sh"  # finds mylab-rpi5.local and checks everything
