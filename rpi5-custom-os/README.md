# Custom Raspberry Pi 5 OS with SSH and Wi-Fi — Buildroot (main) + Yocto (bonus)

Build a Linux image for the Raspberry Pi 5 on WSL2, flash it, and prove SSH works — over Ethernet or Wi-Fi.

```
rpi5-custom-os/
├── config.env                  # hostname, password, key, Wi-Fi, versions  ← edit this
├── config.local.env.example    # copy to config.local.env (git-ignored) for Wi-Fi name/passphrase
├── common/
│   ├── lib.sh                  # WSL checks, PATH fix, key + password hash, wpa_supplicant.conf, export
│   └── target/rootfs-expand    # runs ON the Pi at first boot: grow / to the card size (both flows)
├── buildroot/
│   ├── README.md               # step-by-step guide to the Buildroot flow, file by file
│   ├── quick-build.sh          # the whole flow in one linear, commented script (no checks)
│   ├── br.sh                   # deps | fetch | configure | menuconfig | build | export | clean | all
│   └── board/
│       ├── post-build.sh       # fixes .ssh / Wi-Fi perms, sets sshd_config policy
│       └── overlay/etc/        # files dropped verbatim into the rootfs
│           ├── motd
│           ├── chrony.conf     # NTP servers + "step the clock at boot"
│           └── init.d/
│               ├── S05rootfs-expand  # first boot: runs rootfs-expand
│               └── S45wifi           # brings up wlan0: brcmfmac, wpa_supplicant, udhcpc
├── yocto/
│   ├── README.md               # step-by-step guide to the Yocto flow, file by file
│   ├── quick-build.sh          # the whole flow in one linear, commented script (no checks)
│   ├── yocto.sh                # deps | fetch | lock | update | configure | build | shell | export | clean | all
│   ├── layers.lock             # exact commit of every layer: same file = same image
│   └── meta-mylab/             # our layer: image + authorized_keys + wifi-config + rootfs-expand recipes
├── tools/
│   ├── flash.sh                # attach the card reader to WSL (usbipd), write, verify, detach
│   ├── verify-ssh.sh           # find the Pi (mDNS or scan), log in with the key, check it's our OS
│   └── lint.sh                 # static checks in seconds: shellcheck, line endings, exec bits, tests
├── .github/workflows/lint.yml  # runs lint.sh on every push
└── .gitattributes              # forces LF line endings, even with core.autocrlf=true
```

Versions pinned (checked 2026-10-10): **Buildroot 2026.08** (a release tag), **Yocto 6.0 "wrynose"** (bitbake 2.18, meta-raspberrypi `wrynose`, exact commits in `yocto/layers.lock`).

---

## The mental model

| | Buildroot | Yocto |
|---|---|---|
| Analogy | One recipe card, one pot. `make` cooks everything top to bottom. | A restaurant kitchen: recipe books (layers), a head chef scheduling thousands of small jobs (bitbake), and a fridge of pre-cooked parts (sstate-cache). |
| .NET analogy | A single `.csproj` with a `Directory.Build.props` override | A solution of many NuGet packages; you add your own package (layer) instead of editing others |
| Board selection | `raspberrypi5_defconfig` | `MACHINE = "raspberrypi5"` from `meta-raspberrypi` |
| "Add SSH" | `BR2_PACKAGE_OPENSSH=y` | `IMAGE_FEATURES += "ssh-server-openssh"` |
| "Add Wi-Fi" | firmware + `wpa_supplicant` packages, `mdev`, our `S45wifi` init script | firmware + `wpa-supplicant` packages, our `wifi-config` recipe (systemd unit + networkd) |
| Our customisation | defconfig **fragment** + rootfs **overlay** + **post-build** script | our own **layer** with an image recipe and a key recipe |
| First build | ~30–90 min, ~15 GB | ~2–6 h, ~80–120 GB |
| Output | `sdcard.img` | `mylab-image-raspberrypi5.rootfs.wic.xz` |

What ends up on the SD card is the same shape in both cases: a FAT **boot** partition (Pi firmware, `config.txt`, kernel, device tree) and an ext4 **root** partition (your userspace). The Pi 5 boot ROM reads the first, the kernel mounts the second.

**How SSH access is set up (both flows):**
- Your WSL public key (`~/.ssh/id_ed25519.pub`, auto-created if missing) is baked into root's `authorized_keys`.
- The root password is asked once, stored only as a SHA-512 hash (used for HDMI/serial console login).
- By default SSH is **key-only** for root (`PermitRootLogin prohibit-password`). Set `ALLOW_ROOT_PASSWORD_SSH=yes` in `config.env` if your instructor wants to log in with the password.
- Ethernet gets an address by DHCP. Host keys are generated on first boot.

**What else is in both images:**
- **First-boot resize.** The image is small (~400 MB); at first boot `rootfs-expand` grows the root partition and ext4 to fill the card, while mounted, no reboot. It runs once (marker: `/etc/rootfs-expanded`). The script is shared: Buildroot runs it from `S05rootfs-expand`, Yocto from `rootfs-expand.service`.
- **mDNS.** `avahi-daemon` announces the Pi as `mylab-rpi5.local` (your `RPI_HOSTNAME`) and advertises SSH, so you don't need its IP: `ssh root@mylab-rpi5.local` works from Windows, macOS and most Linux desktops.
- **Time sync.** The Pi 5's RTC has no battery by default, so it boots with a wrong clock (bad for TLS and logs). Buildroot runs `chrony` (`/etc/chrony.conf`: steps the clock on first sync); Yocto uses `systemd-timesyncd`, which comes with systemd.

**How Wi-Fi is set up (both flows):**
- The Pi 5's radio is an Infineon CYW43455 on SDIO, driven by the `brcmfmac` kernel module. The kernel already has the driver; the image adds the **firmware** (`brcmfmac43455-sdio.*`), the **regulatory database**, **wpa_supplicant** (+ `wpa_cli`, `wpa_passphrase`) and `iw`.
- The network comes from `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY`. Put them in `config.local.env` (copy `config.local.env.example`, it's git-ignored). If `WIFI_PSK` is empty you are asked for it at `configure` time, like the root password.
- `configure` writes a `wpa_supplicant` config: the SSID hex-encoded (any characters work), the passphrase turned into the 256-bit WPA PSK (what `wpa_passphrase` does), so the plain text is never in the image. The PSK still lets someone join that network, so don't share the image.
- `wlan0` gets an address by DHCP. On Yocto, when both are up, Ethernet's default route wins (lower metric).
- Supported: WPA2-Personal (WPA2/WPA3 transition-mode networks connect as WPA2) and open networks. Not supported: WPA3-only (SAE) and enterprise (802.1X) networks.
- `WIFI_SSID` empty = Ethernet only. The Wi-Fi stack is still installed, so you can add a network on the Pi later:
  ```sh
  wpa_cli -i wlan0 add_network                       # prints an id, e.g. 0
  wpa_cli -i wlan0 set_network 0 ssid '"MyNet"'
  wpa_cli -i wlan0 set_network 0 psk '"passphrase"'
  wpa_cli -i wlan0 enable_network 0
  wpa_cli -i wlan0 save_config                       # persists across reboots
  ```

| | Buildroot | Yocto |
|---|---|---|
| Config file on the Pi | `/etc/wpa_supplicant.conf` | `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf` |
| Who loads the driver | `mdev` (module autoload from the SDIO modalias), `S45wifi` as a fallback | `systemd-udevd` |
| Who starts the supplicant | `/etc/init.d/S45wifi` | `wpa_supplicant-nl80211@wlan0.service`, started when `wlan0` appears |
| Who runs DHCP | `udhcpc` (started by `S45wifi`) | `systemd-networkd` (`/etc/systemd/network/30-wlan.network`) |
| Restart / status | `/etc/init.d/S45wifi restart` | `systemctl restart wpa_supplicant-nl80211@wlan0`, `networkctl status wlan0` |

---

## 0. One-time WSL setup

1. Use **WSL2** with Ubuntu 24.04 (`wsl -l -v` → VERSION 2).
2. Give WSL enough memory. Create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=16GB      # Buildroot is fine with 8GB; Yocto wants 16GB+
   swap=16GB
   processors=8
   ```
   Then in PowerShell: `wsl --shutdown`, reopen Ubuntu.
3. Put this folder **inside the Linux filesystem**, e.g. `~/rpi5-custom-os`, not `/mnt/c/...`.

**Why not /mnt/c?** Files there go through a Windows↔Linux translation layer — like doing every DB call over a slow network share. Builds are ~10× slower, and NTFS is case-insensitive, which breaks the Linux kernel sources (`xt_TCPMSS.h` vs `xt_tcpmss.h`). The scripts refuse to run there.

**The PATH gotcha:** WSL appends Windows folders like `/mnt/c/Program Files/...` to `PATH`. Buildroot refuses to build with spaces in `PATH`. The scripts strip `/mnt/*` entries automatically; to fix it permanently add to `/etc/wsl.conf`:
```ini
[interop]
appendWindowsPath=false
```

```bash
cd ~/rpi5-custom-os
chmod +x buildroot/br.sh yocto/yocto.sh tools/*.sh   # only needed if you copied instead of git clone
./tools/lint.sh          # optional, seconds: catches broken line endings / exec bits / typos
nano config.env          # optional: hostname, password policy
cp config.local.env.example config.local.env
nano config.local.env    # Wi-Fi: WIFI_SSID, WIFI_COUNTRY (and WIFI_PSK, or be asked)
```

---

## 1. Buildroot (main task)

> Full walkthrough, every file and every build stage: [buildroot/README.md](buildroot/README.md)

```bash
./buildroot/br.sh deps       # apt packages (sudo), once
./buildroot/br.sh all        # fetch → configure → build → export
```

Or step by step, to understand each stage:

| Step | What happens |
|---|---|
| `fetch` | Clones Buildroot 2026.08 to `~/rpi5-os/buildroot-2026.08` |
| `configure` | Asks root password (and Wi-Fi passphrase), builds the overlay with your key and `wpa_supplicant.conf`, writes `~/rpi5-os/br-generated/mylab_rpi5_defconfig` = stock `raspberrypi5_defconfig` + our fragment, applies it into `~/rpi5-os/br-output/.config`, then checks the key options stuck |
| `menuconfig` | Optional: browse/tweak options in the ncurses UI (e.g. *Target packages → Networking applications → openssh*) |
| `build` | `make` — downloads sources, builds the cross-toolchain-based rootfs, kernel, firmware, packs `sdcard.img`; checks sshd + key are in the rootfs |
| `export` | Copies the image to `C:\Users\<you>\Downloads\rpi5-images\` |

What the fragment adds (see `br.sh` → `step_configure`):
```
BR2_TARGET_GENERIC_HOSTNAME="mylab-rpi5"
BR2_TARGET_GENERIC_ROOT_PASSWD="$$6$$..."      # hashed; $ doubled for make
BR2_PACKAGE_OPENSSH=y / _SERVER=y / _CLIENT=y / _KEY_UTILS=y
BR2_ROOTFS_OVERLAY=".../br-overlay"            # puts /root/.ssh/authorized_keys in
BR2_ROOTFS_POST_BUILD_SCRIPT="board/raspberrypi5/post-build.sh .../post-build.sh"
BR2_TARGET_ROOTFS_EXT2_SIZE="256M"
BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_MDEV=y          # autoloads brcmfmac
BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI=y / _WIFI=y  # CYW43455 firmware
BR2_PACKAGE_WIRELESS_REGDB=y, BR2_PACKAGE_IW=y
BR2_PACKAGE_WPA_SUPPLICANT=y / _NL80211=y / _CTRL_IFACE=y / _CLI=y / _PASSPHRASE=y
BR2_PACKAGE_UTIL_LINUX_BINARIES=y / _PARTX=y, BR2_PACKAGE_E2FSPROGS_RESIZE2FS=y  # first-boot resize
BR2_PACKAGE_AVAHI_DAEMON=y / _DEFAULT_SERVICES=y   # mylab-rpi5.local
BR2_PACKAGE_CHRONY=y                               # NTP
```
Rebuild after changing config: `./buildroot/br.sh configure && ./buildroot/br.sh build`.
Changed a package option or the kernel? `./buildroot/br.sh clean` first (Buildroot doesn't track config changes per package — downloads are kept, so it's mostly CPU time).

## 2. Yocto (bonus)

> Full walkthrough, every file and every build stage: [yocto/README.md](yocto/README.md)

```bash
./yocto/yocto.sh deps        # apt packages + en_US.UTF-8 locale (sudo), once
./yocto/yocto.sh all         # fetch → configure → build → export
```

| Step | What happens |
|---|---|
| `fetch` | Fetches bitbake 2.18, openembedded-core, meta-yocto (poky distro), meta-raspberrypi — all `wrynose` — into `~/rpi5-os/yocto/`, each at the exact commit in `yocto/layers.lock` (falls back to the GitHub mirrors if the primary server is down) |
| `update` | Moves every layer to its branch tip and rewrites `layers.lock`. Do this on purpose, rebuild, test, then commit the lock file. `lock` alone just records what is checked out. |
| `configure` | Copies `meta-mylab` in with your key and the generated Wi-Fi config, writes `build/conf/bblayers.conf` and `local.conf` (MACHINE, systemd, UART, hostname, password hash, caches), runs `bitbake-layers show-layers` |
| `build` | `bitbake mylab-image`; checks the image manifest contains `openssh-sshd`, `ssh-root-key`, `wpa-supplicant`, `wifi-config`, the Wi-Fi firmware, `rootfs-expand` and `avahi-daemon` |
| `shell` | Drops you into a shell with `bitbake` on PATH, for exploring (`bitbake -e mylab-image \| less`, `bitbake -c menuconfig virtual/kernel`) |
| `export` | Copies `.wic.xz` to Windows Downloads |

The layer, file by file:
- `meta-mylab/recipes-core/images/mylab-image.bb` — `require core-image-minimal.bb`, then `IMAGE_FEATURES += "ssh-server-openssh"`, root password via `extrausers`, optional `allow-root-login`.
- `meta-mylab/recipes-mylab/ssh-root-key/ssh-root-key.bb` — tiny package that installs `${ROOT_HOME}/.ssh/authorized_keys` with mode 600.
- `meta-mylab/recipes-mylab/wifi-config/wifi-config.bb` — installs the generated `wpa_supplicant-nl80211-wlan0.conf` (mode 600) and `30-wlan.network`, and enables `wpa_supplicant-nl80211@wlan0.service`. The image also adds `linux-firmware-rpidistro-bcm43455`, `wireless-regdb-static`, `wpa-supplicant(-cli,-passphrase)` and `iw`.
- `meta-mylab/recipes-mylab/rootfs-expand/rootfs-expand.bb` — installs `common/target/rootfs-expand` (copied in at `configure`) and a one-shot `rootfs-expand.service`; pulls in `sfdisk`, `partx` and `resize2fs`.

**Why `layers.lock`?** A branch like `wrynose` keeps receiving fixes, so "build `wrynose`" means different sources next month. Pinning commits makes a rebuild produce the same image — the same idea as `package-lock.json` / `packages.lock.json`. Buildroot doesn't need this: it is fetched by release tag, and its own hashes pin every package.

Clean rebuilds are cheap thanks to sstate: `./yocto/yocto.sh clean && ./yocto/yocto.sh build`.

---

## 3. Flash

### 3a. From WSL, the Linux way (`tools/flash.sh`)

WSL2 is a VM, so USB devices belong to Windows by default. **usbipd-win** is the extension cord: Windows lets go of the card reader and forwards it over USB/IP, and the Linux kernel sees a real `/dev/sdX`.

One-time setup, in PowerShell:
```powershell
winget install usbipd
```
Then reopen WSL, insert the card, and run:
```bash
./tools/flash.sh buildroot          # or: yocto, or a path to any .img/.wic/.xz
./tools/flash.sh yocto --dry-run    # see every command without writing anything
```

What it does, step by step:

| Step | Linux concept you're practising |
|---|---|
| Lists USB devices via `usbipd list`, picks the card reader, `bind`s it once (UAC prompt), `attach --wsl` | Device passthrough |
| Waits for a **new** disk to appear in `lsblk` | Kernel hot-plug and enumeration (`dmesg \| tail` shows it) |
| Refuses anything that isn't a whole, USB/removable disk ≤ 256 GB, holds `/`, or is smaller than the image; makes you type the device name | The `dd` "disk destroyer" safety habits |
| Unmounts partitions and writes. Yocto uses `bmaptool copy` with the `.bmap` (writes only blocks with data, checks sha256). Buildroot uses `dd oflag=direct conv=fsync` | Block devices, page cache, fsync |
| Reads the card back and `cmp`s it with the image (dd path) | Verifying writes, not trusting them |
| Re-reads the partition table, mounts both partitions read-only, checks `config.txt`, the bcm2712 kernel/DTB, `sshd`, your key, the hostname and the Wi-Fi config | MBR partitions, vfat boot + ext4 rootfs |
| `usbipd detach`, so the reader goes back to Windows (`--keep-attached` to skip) | — |

Limitation: built-in laptop SD slots are often PCIe (SDHCI), not USB, and usbipd can't forward them. A USB card reader always works.

On native Linux the script skips the usbipd part and works the same.

### 3b. From Windows (fallback)

**Raspberry Pi Imager** → *Choose OS* → *Use custom* → pick the file from `Downloads\rpi5-images` → choose the card → **"No"** to OS customisation (that only works for Raspberry Pi OS; our image is already configured). balenaEtcher works the same way.

## 4. Boot and verify SSH

1. SD card in, **Ethernet cable** to your router (optional if Wi-Fi is configured), power on. Give it ~20 s (Yocto: ~30 s on first boot).
2. From WSL:
   ```bash
   ./tools/verify-ssh.sh                 # finds mylab-rpi5.local via mDNS, else scans your LAN
   ./tools/verify-ssh.sh --scan          # only scan the LAN for port 22
   ./tools/verify-ssh.sh 192.168.1.57    # a known IP (from the router's DHCP list)
   ```
   It checks: port 22 + banner → offered auth methods → key login as root → hostname is `mylab-rpi5`, `aarch64`, board model `Raspberry Pi 5`, sshd running, Wi-Fi joined with an IPv4 address (if `WIFI_SSID` is set), the clock within 2 min of your PC's (NTP works), avahi running, and the root filesystem size vs. the card. Ends with **PASS**.

   WSL2 in its default NAT mode can't see LAN multicast, so the script asks Windows to resolve `.local` names (Windows speaks mDNS).
3. Manual login:
   ```bash
   ssh -i ~/.ssh/id_ed25519 root@mylab-rpi5.local     # or root@<pi-ip>
   ```

Sample of what to hand in as the result: the `PASS` output of `verify-ssh.sh`, plus `uname -a` and `cat /etc/os-release` from the SSH session.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Your PATH contains spaces` | You ran `make` by hand; use `br.sh`, or set `appendWindowsPath=false` (see §0). |
| Build killed, `cc1plus: Killed` / bitbake `-9` | Out of RAM. Raise `.wslconfig` memory/swap, or `JOBS=4 ./yocto/yocto.sh build`. |
| `mylab-rpi5.local` doesn't resolve | Wait ~30 s after boot. Guest / office Wi-Fi often blocks multicast between clients: use `--scan` or the IP. On the Pi: `pidof avahi-daemon`. |
| `/` still small after first boot | Buildroot: `cat /var/log/rootfs-expand.log`. Yocto: `journalctl -u rootfs-expand`. Re-run by hand: `rm /etc/rootfs-expanded; rootfs-expand`. |
| Clock wrong / TLS "certificate not yet valid" | Needs Internet access to NTP (UDP 123). Buildroot: `chronyc sources`, `/etc/init.d/S49chronyd restart`. Yocto: `timedatectl timesync-status`. |
| `bash\r: No such file or directory` | Scripts got CRLF line endings (a Windows checkout made before `.gitattributes` existed). Commit or stash your own changes first (the next command discards them), then `git rm --cached -r -q . && git reset --hard`. `./tools/lint.sh` lists affected files. |
| `--scan` finds nothing | Check the router's DHCP client list. With a monitor on HDMI you'll see a login prompt (root + your password), then `ip addr`. |
| Rainbow screen / no boot | Bad flash or old Pi 5 bootloader EEPROM. Re-flash; update the EEPROM once with Raspberry Pi OS. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Every rebuild creates new host keys. `verify-ssh.sh` uses its own `~/rpi5-os/known_hosts`; for plain `ssh` run `ssh-keygen -R <pi-ip>`. |
| `Permission denied (publickey)` | Key mismatch: the image has the key from `SSH_PUBKEY` at configure time. Re-run `configure` + `build` after changing keys. |
| Pi not reachable at all, no screen (Buildroot) | Leave it powered for 2 minutes, then put the SD card in your PC and open `boot-report.txt` on the boot drive. It shows IP addresses, link state (`carrier=1` = cable link), DHCP and Wi-Fi status, and the relevant kernel and syslog lines. |
| `flash.sh`: "hostname is 'X' but config says 'Y'" | The image was built with different settings, usually because `config.local.env` is git-ignored and wasn't copied to the WSL folder you built from. Copy it, then rebuild. |
| No `wlan0` | `dmesg \| grep brcmfmac`. "firmware load failed": firmware missing from `/lib/firmware/brcm`. No output at all: driver not loaded, try `modprobe brcmfmac`. |
| `wlan0` exists but doesn't connect | `wpa_cli -i wlan0 status` (look at `wpa_state`), `iw dev wlan0 link`, `wpa_cli -i wlan0 scan; wpa_cli -i wlan0 scan_results` to see if the SSID is visible. Common causes: wrong passphrase, 5 GHz channel blocked because `WIFI_COUNTRY` is unset, WPA3-only access point. |
| Wi-Fi connected but no IP | Buildroot: `ps \| grep udhcpc`, `/etc/init.d/S45wifi restart`. Yocto: `networkctl status wlan0`, `journalctl -u systemd-networkd`. |
| Buildroot boot pauses without Ethernet | The stock `eth0` DHCP waits for a lease first. Harmless: Wi-Fi comes up right after. |
| Serial console | Pi 5 has a dedicated 3-pin UART connector (`ttyAMA10`, 115200 8N1) — useful when the network is the problem. |
| Yocto: user-namespace / `unshare` errors | Ubuntu 24.04 AppArmor rule: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`. |
