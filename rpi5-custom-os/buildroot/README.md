# Buildroot flow: step by step

This folder builds a complete Raspberry Pi 5 Linux image with **Buildroot**: a cross-compiler, the Linux kernel, a small BusyBox-based root filesystem with OpenSSH, Wi-Fi, mDNS and NTP, all packed into one `sdcard.img` you flash to an SD card.

One script drives everything: [`br.sh`](br.sh). This document explains every file it uses, what each step does, and what happens on the Pi when it boots.

- [1. Files](#1-files)
- [2. The big picture](#2-the-big-picture)
- [3. Step by step](#3-step-by-step)
- [4. What happens when the Pi boots](#4-what-happens-when-the-pi-boots)
- [5. How to change things](#5-how-to-change-things)
- [6. Where everything ends up on disk](#6-where-everything-ends-up-on-disk)

---

## 1. Files

### In this folder

| File | What it is | Why it's needed |
|---|---|---|
| [`br.sh`](br.sh) | The driver script. Steps: `deps`, `fetch`, `configure`, `menuconfig`, `build`, `export`, `clean`, `all`. | Wraps the Buildroot commands so you don't run `make` by hand. It also fixes the WSL `PATH` and checks the result after each step. |
| [`board/post-build.sh`](board/post-build.sh) | Script Buildroot runs **after** assembling the root filesystem, **before** packing it into `rootfs.ext4`. | Fixes file permissions (`/root/.ssh`, the Wi-Fi config and the init scripts), sets the `sshd_config` login policy, deletes the "already resized" marker and creates `/var/lib/chrony`. |
| [`board/overlay/`](board/overlay/) | The **rootfs overlay**: files copied as-is on top of the root filesystem. | The simplest way to add or replace files in the image without writing a Buildroot package. |
| [`board/overlay/etc/motd`](board/overlay/etc/motd) | "Message of the day", shown after you log in. | Confirms you're on *your* image and lists useful commands. |
| [`board/overlay/etc/chrony.conf`](board/overlay/etc/chrony.conf) | Config for `chronyd`, the NTP client. | Replaces the package's example config: it uses `pool.ntp.org`, **jumps** the clock on the first sync (the Pi boots with a wrong date) and keeps the RTC in sync. |
| [`board/overlay/etc/init.d/S05rootfs-expand`](board/overlay/etc/init.d/S05rootfs-expand) | Boot script, runs early. | On the first boot it runs `/usr/sbin/rootfs-expand` to grow `/` to the size of the card. Afterwards it does nothing. |
| [`board/overlay/etc/init.d/S99boot-report`](board/overlay/etc/init.d/S99boot-report) | Boot script, runs last. | Diagnostics when the Pi isn't reachable. About 60 s after boot it writes `boot-report.txt` (IP addresses, routes, link state, Wi-Fi status, modules, firmware, kernel and syslog lines) to the FAT boot partition. Put the card in any PC and open it. |
| [`board/overlay/etc/init.d/S45wifi`](board/overlay/etc/init.d/S45wifi) | Boot script, runs after Ethernet is up. | Loads the Wi-Fi driver if needed, waits for `wlan0`, starts `wpa_supplicant`, then `udhcpc` for an IP address. Also takes `stop` and `restart`. |
| [`quick-build.sh`](quick-build.sh) | The whole flow (deps → fetch → configure → build → export) as one top-to-bottom script, one comment per line, no checks. | A quick read of the whole flow, or a one-command build. Builds the same image as `br.sh`. Its config fragment is a copy of the one in `br.sh`: keep the two in sync. |
| `README.md` | This document. | |

### Shared files this flow uses (outside this folder)

| File | Used for |
|---|---|
| [`../config.env`](../config.env) | All settings: hostname, root password policy, SSH key path, Wi-Fi, Buildroot version, `WORK_DIR`, `JOBS`. |
| `../config.local.env` | Your private overrides, mainly the Wi-Fi network name and passphrase. Git-ignored; create it from [`../config.local.env.example`](../config.local.env.example). |
| [`../common/lib.sh`](../common/lib.sh) | Helper functions: `preflight` (WSL/disk/RAM checks, `PATH` fix), `ensure_ssh_key`, `make_root_hash`, `make_wifi_conf`, `export_to_windows`. |
| [`../common/target/rootfs-expand`](../common/target/rootfs-expand) | The first-boot resize script. `configure` copies it into the overlay as `/usr/sbin/rootfs-expand`. The Yocto flow uses the same file. |
| [`../tools/flash.sh`](../tools/flash.sh) | Writes `sdcard.img` to an SD card from WSL, then checks it. |
| [`../tools/verify-ssh.sh`](../tools/verify-ssh.sh) | Finds the booted Pi, logs in with your key and checks everything works. |
| [`../tools/lint.sh`](../tools/lint.sh) | Static checks of all scripts, in seconds, without building. |

### Generated files (in `~/rpi5-os/`, never in the repo)

| Path | Created by | Contents |
|---|---|---|
| `buildroot-2026.08/` | `fetch` | Buildroot itself: Makefiles, the recipe for every package (`package/`), board configs (`configs/`, `board/`). |
| `br-overlay/` | `configure` | Built fresh on every `configure`: [`board/overlay/`](board/overlay/) **plus** your `authorized_keys`, the generated `wpa_supplicant.conf` and `rootfs-expand`. This is the overlay Buildroot actually uses. |
| `br-generated/mylab.fragment` | `configure` | Our config lines (see [step 3](#configure--decide-what-goes-into-the-image)). |
| `br-generated/mylab_rpi5_defconfig` | `configure` | Stock Pi 5 config + our fragment. Mode 600, because it holds the root password hash. |
| `br-output/` | `configure`, `build` | The out-of-tree build directory: `.config`, every compiled package, `target/` (the root filesystem) and `images/` (the result). |
| `br-dl/` | `build` | Downloaded source tarballs. Kept by `clean`, so rebuilds don't download again. |
| `br-ccache/` | `build` | Compiler cache. Makes rebuilds after `clean` much faster. |

---

## 2. The big picture

```
 config.env + config.local.env
            │
            ▼
 ┌─ configure ──────────────────────────────────────────────────────────────┐
 │ raspberrypi5_defconfig (stock) + mylab.fragment (ours) ─► .config         │
 │ board/overlay + your key + wpa_supplicant.conf + rootfs-expand ─► br-overlay
 └───────────────────────────────────────────────────────────────────────────┘
            │
            ▼
 ┌─ build (one `make`) ─────────────────────────────────────────────────────┐
 │ 1. toolchain      download the ready-made aarch64 cross-compiler          │
 │ 2. packages       for each selected package: download → patch →          │
 │                   configure → compile → install into output/target/      │
 │ 3. kernel         Raspberry Pi kernel (bcm2712 config) + device trees + modules
 │ 4. firmware       Pi boot files, Wi-Fi firmware                           │
 │ 5. finalize       copy br-overlay over target/ → run post-build scripts   │
 │ 6. filesystem     target/ ─► rootfs.ext4 (256 MB)                         │
 │ 7. post-image     genimage: boot.vfat + rootfs.ext4 ─► sdcard.img         │
 └───────────────────────────────────────────────────────────────────────────┘
            │
            ▼
 export ─► C:\Users\<you>\Downloads\rpi5-images\mylab-rpi5-buildroot-2026.08.img
```

Things to know about Buildroot:
- **One configuration file decides everything.** `.config` lists every option as `BR2_...=value`. You don't write build rules. You switch features on, and Buildroot's ~3000 built-in package recipes do the rest.
- **Cross-compiling.** Your PC is x86-64, the Pi is ARM64 (Cortex-A76). Everything is compiled on the PC with a cross-compiler that produces ARM code.
- **No package manager on the Pi.** The image is built whole. To add software, change the config and rebuild. Nothing is installed with `apt` on the Pi.
- **Out-of-tree build.** The Buildroot source (`buildroot-2026.08/`) stays clean; everything generated goes to `br-output/` (the `O=` argument in `br.sh`).

---

## 3. Step by step

Run everything from the repo root inside WSL (Linux filesystem, not `/mnt/c`):

```bash
./buildroot/br.sh deps      # once
./buildroot/br.sh all       # = fetch → configure → build → export
```

Every step except `deps` and `clean` starts with `preflight` from `lib.sh`. It checks that you're in WSL2, that `WORK_DIR` isn't on the Windows drive, that at least 25 GB are free, and warns if RAM + swap is below 8 GB. Then it removes the Windows folders WSL adds to `PATH`. Buildroot refuses to run when `PATH` contains spaces, as `/mnt/c/Program Files/...` does.

### `deps`: install build tools on your PC

Runs `apt-get install` for the tools Buildroot needs on the **host** (your WSL Ubuntu):
- compilers and build tools (`build-essential`, `make`, `patch`, `perl`, `python3`, `bc`, `cpio`, `rsync`, `file`)
- download and unpack tools (`wget`, `curl`, `git`, `unzip`, `xz-utils`, `bzip2`)
- `libncurses-dev` for the `menuconfig` text UI
- `openssl` to hash the root password, `openssh-client` for `ssh-keygen` and `ssh`
- `ccache` (compiler cache), `bmap-tools` and `parted` (used by `flash.sh`)

Needs `sudo`, once per machine.

### `fetch`: download Buildroot

1. Clones Buildroot at tag `2026.08` (`BUILDROOT_VERSION`), latest commit only (`--depth 1`), into `~/rpi5-os/buildroot-2026.08`. Uses GitLab first and GitHub if that fails.
2. Skips the clone if it's already there.
3. Checks that `configs/raspberrypi5_defconfig` exists. This file is the official starting configuration for the Pi 5.

A release tag never changes, so this is reproducible. Buildroot also checks a SHA-256 hash for every source tarball it downloads later.

### `configure`: decide what goes into the image

This step builds the configuration in five sub-steps. You can re-run it any time.

**3.1 Your SSH key** (`ensure_ssh_key` in `lib.sh`). If `~/.ssh/id_ed25519.pub` doesn't exist, it creates a new ed25519 key pair. The **public** half goes into the image; the private half stays on your PC.

**3.2 Root password** (`make_root_hash`). Asks for the password twice, unless `ROOT_PASSWORD` is set, and turns it into a SHA-512 crypt hash with `openssl passwd -6`. Only the hash goes into the image, in the same format as `/etc/shadow`. You need the password for console login (HDMI or serial). Whether SSH accepts it is decided by `ALLOW_ROOT_PASSWORD_SSH`.

**3.3 Build the rootfs overlay** in `~/rpi5-os/br-overlay/`. It's deleted and rebuilt every time:

| Goes to (on the Pi) | Comes from |
|---|---|
| `/root/.ssh/authorized_keys` (mode 600, dir 700) | your public key (`SSH_PUBKEY`) |
| `/etc/motd`, `/etc/chrony.conf`, `/etc/init.d/S05rootfs-expand`, `/etc/init.d/S45wifi` | [`board/overlay/`](board/overlay/) |
| `/etc/wpa_supplicant.conf` (mode 600) | generated by `make_wifi_conf` from `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY`; asks for the passphrase if it's empty |
| `/usr/sbin/rootfs-expand` | [`../common/target/rootfs-expand`](../common/target/rootfs-expand) |

How `make_wifi_conf` writes the Wi-Fi config:
- The SSID is written in **hex**, so any characters (spaces, quotes, accents) work without escaping.
- The passphrase is turned into the 256-bit **PSK** with PBKDF2-SHA1(passphrase, SSID, 4096 rounds), the same calculation `wpa_passphrase` does. The plain passphrase never enters the image.
- `ctrl_interface` and `update_config=1` let you change networks later on the Pi with `wpa_cli`.
- If `WIFI_SSID` is empty, the file has no `network={}` block: the Wi-Fi software is installed but joins nothing.

**3.4 Write our config fragment** (`br-generated/mylab.fragment`). Each line switches on an option:

| Lines | What they do |
|---|---|
| `BR2_DL_DIR`, `BR2_CCACHE`, `BR2_CCACHE_DIR` | Keep downloads and compiler cache outside `br-output/`, so `clean` doesn't throw them away. |
| `BR2_TARGET_GENERIC_HOSTNAME`, `_ISSUE` | Hostname (`/etc/hostname`) and the login banner (`/etc/issue`). |
| `BR2_TARGET_ENABLE_ROOT_LOGIN`, `BR2_TARGET_GENERIC_ROOT_PASSWD` | Root account and its password hash. Every `$` is doubled (`$$`) because `make` would otherwise expand it as a variable. |
| `BR2_PACKAGE_OPENSSH` + `_SERVER`, `_CLIENT`, `_KEY_UTILS` | OpenSSH: `sshd`, `ssh`, `ssh-keygen`. Buildroot adds its own `S50sshd` init script, which creates host keys on first boot. |
| `BR2_ROOTFS_OVERLAY` | Points Buildroot at `br-overlay/`. |
| `BR2_ROOTFS_POST_BUILD_SCRIPT` (+ `_ARGS`) | Runs **two** scripts: the stock `board/raspberrypi5/post-build.sh` (adds an HDMI login console on `tty1`), then [ours](board/post-build.sh) with `ALLOW_ROOT_PASSWORD_SSH` as its argument. |
| `BR2_TARGET_ROOTFS_EXT2_SIZE="256M"` | Root filesystem size inside the image (stock: 120M). It grows to the full card on first boot. |
| `BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_MDEV` | Uses BusyBox **mdev** to handle hot-plug events. Without it nothing loads kernel modules automatically, so the Wi-Fi driver would never load. |
| `BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI` + `_WIFI` | Firmware for the Pi 5's Wi-Fi chip (Infineon CYW43455), into `/lib/firmware/brcm/`. The kernel driver `brcmfmac` loads it. |
| `BR2_PACKAGE_WIRELESS_REGDB` | Database of legal radio channels and power per country. |
| `BR2_PACKAGE_IW` | `iw`, a low-level Wi-Fi diagnostics tool (`iw dev wlan0 link`). |
| `BR2_PACKAGE_WPA_SUPPLICANT` + `_NL80211`, `_CTRL_IFACE`, `_CLI`, `_PASSPHRASE` | The program that joins WPA networks, with the modern kernel interface, the control socket, `wpa_cli` and `wpa_passphrase`. |
| `BR2_PACKAGE_UTIL_LINUX` + `_BINARIES`, `_PARTX`; `BR2_PACKAGE_E2FSPROGS` + `_RESIZE2FS` | `sfdisk`, `partx` and `resize2fs`, used by the first-boot resize. |
| `BR2_PACKAGE_AVAHI` + `_DAEMON`, `_DEFAULT_SERVICES` | mDNS: the Pi answers to `mylab-rpi5.local` and advertises its SSH service. |
| `BR2_PACKAGE_CHRONY` | NTP client. The Pi 5 RTC has no battery by default, so the clock is wrong after power-off until this syncs it. |
| `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS` | Puts the firmware's `overlays/` folder on the boot partition (stock: off). Newer Pi 5 boards (Rev 1.1, D0 chip) need `overlays/bcm2712d0.dtbo`. Without it the kernel gets the older C1 chip's pin layout and panics about 1.5 s into boot (`SError` in `bcm2712_pull_config_set`). |

**3.5 Combine and apply.**
1. `cat raspberrypi5_defconfig mylab.fragment > mylab_rpi5_defconfig`. The stock file sets the board basics: ARM64 Cortex-A76, an external cross-toolchain, the Raspberry Pi kernel with the `bcm2712` config and Pi 5 device trees, Pi boot firmware, DHCP on `eth0`, an ext4 root filesystem. When an option appears twice, the **last** value wins, so our fragment overrides the stock one (for example the 256M size).
2. `make O=~/rpi5-os/br-output BR2_DEFCONFIG=... defconfig` expands this short file into the full `br-output/.config`. Every option not mentioned gets its default, and options selected by others (for example `libnl` for `wpa_supplicant`) are switched on automatically.
3. **Checks**: `grep` confirms that key options (OpenSSH, Cortex-A76, mdev, Wi-Fi firmware, `wpa_supplicant`, util-linux, resize2fs, avahi, chrony) and the hostname really are in `.config`. This catches an option that was silently dropped because one of its dependencies wasn't met.

### `menuconfig` (optional): browse the options

Opens Buildroot's text UI on `br-output/.config`. It's a good way to see what exists (*Target packages → Networking applications*). Changes made here are lost on the next `configure`. To keep a change, add the line to the fragment in `br.sh`.

### `build`: compile everything

Runs one `make` in `br-output/` with `BR2_JLEVEL=$JOBS` (parallel jobs **inside** each package; Buildroot doesn't build packages in parallel). Output goes to the screen and to `br-output/build.log`. First build: 30–90 minutes. What `make` does, in order:

1. **Toolchain.** Downloads the ready-made Bootlin aarch64 glibc cross-compiler (no time spent building GCC) and sets up `br-output/host/`.
2. **Host tools.** Builds the tools the build itself needs on the PC: `genimage`, `mtools`, `dosfstools`, `kmod`, and so on.
3. **Packages.** For each selected package, in dependency order: download the source to `br-dl/` (and check its hash) → unpack into `br-output/build/<pkg>-<ver>/` → apply patches → configure → compile → install into `br-output/target/` (the future root filesystem) and `br-output/staging/` (headers and libraries for linking other packages). BusyBox provides the shell, `init`, `mdev`, `udhcpc` and the basic commands.
4. **Kernel.** Builds the Raspberry Pi kernel (`Image`), the Pi 5 device trees (`bcm2712-rpi-5-b.dtb` and others) and the modules into `target/lib/modules/<version>/`. The Wi-Fi driver `brcmfmac.ko` is one of those modules.
5. **Boot firmware.** `rpi-firmware` puts the Pi boot files plus our `config.txt` and `cmdline.txt` into `br-output/images/rpi-firmware/`.
6. **Target finalize.**
   - Applies the system settings: hostname, the root hash in `/etc/shadow`, `/etc/issue`, `/etc/network/interfaces` (DHCP on `eth0`). The basic skeleton (`/etc/inittab`, `/etc/init.d/rcS`, `/etc/fstab`) was installed at the start, like a package.
   - Copies `br-overlay/` over `target/`. Our files win over package files: `chrony.conf` and `wpa_supplicant.conf` replace the packages' samples.
   - Runs the stock post-build script (adds the `tty1` console to `/etc/inittab`), then [ours](board/post-build.sh):
     - `chmod` on `.ssh`, `authorized_keys`, `wpa_supplicant.conf` and our init scripts. A Windows checkout can lose the executable bit; without it the scripts wouldn't run at boot.
     - removes `/etc/rootfs-expanded`, so the image always resizes on its first boot
     - creates `/var/lib/chrony` for chrony's drift file
     - edits `/etc/ssh/sshd_config`: `PubkeyAuthentication yes`, and either `PermitRootLogin prohibit-password` + `PasswordAuthentication no` (key only, the default) or `PermitRootLogin yes` + `PasswordAuthentication yes`
7. **Filesystem image.** Packs `target/` into `images/rootfs.ext4` (256 MB).
8. **Post-image.** The stock `board/raspberrypi5/post-image.sh` runs `genimage`. It creates a FAT `boot.vfat` holding the kernel, the device trees, `overlays/`, `config.txt` and `cmdline.txt`, then writes an MBR `sdcard.img` with partition 1 = boot (FAT) and partition 2 = root (ext4).

After `make`, `br.sh` checks `br-output/target/` (the unpacked root filesystem) to catch a broken build before you flash it:
- **must exist** (the build fails otherwise): `sshd`, `authorized_keys`, an `S*sshd` init script, `wpa_supplicant`, `S45wifi`, `wpa_supplicant.conf`, `sfdisk`, `partx`, `resize2fs`, `rootfs-expand`, `avahi-daemon`, `chronyd`, and the init scripts `S05rootfs-expand`, `S49chronyd`, `S50avahi-daemon`
- **warning only**: `brcmfmac.ko` and the CYW43455 firmware (their paths can vary between kernel and firmware versions)

### `export`: hand the image to Windows

1. Copies `sdcard.img` to `br-output/images/mylab-rpi5-buildroot-2026.08.img`.
2. Detects your Windows user and copies the file to `C:\Users\<you>\Downloads\rpi5-images\`, for Raspberry Pi Imager or balenaEtcher. You can change the folder with `WIN_EXPORT_DIR`.
3. Prints the next steps: flash, boot, verify.

### `clean`: start the build over

Deletes `br-output/`. Downloads (`br-dl/`) and the compiler cache (`br-ccache/`) are kept, so a rebuild is mostly CPU time.

**When you need it:** Buildroot doesn't track which packages are affected when you change the configuration. After adding or removing packages, changing the kernel or changing the device manager (for example the mdev switch for Wi-Fi), run `clean` before `build`. Changing only overlay files, the root password or the Wi-Fi settings doesn't need `clean`: `configure` + `build` re-runs the finalize stage.

---

## 4. What happens when the Pi boots

1. **Bootloader (in the Pi 5's EEPROM)** reads partition 1 (FAT): `config.txt`, the device tree for the board, and the kernel `Image`. It starts the kernel with the arguments from `cmdline.txt`, which name partition 2 as root (`root=/dev/mmcblk0p2`).
2. **Kernel** starts, mounts the ext4 root filesystem and runs `/sbin/init` (BusyBox).
3. **`/etc/inittab`** mounts `/proc`, remounts `/` read-write, mounts the rest from `/etc/fstab` (`/sys`, `/tmp`, ...), then runs `/etc/init.d/rcS`. (The kernel has already mounted `/dev` as devtmpfs.) That runs every `/etc/init.d/S??*` script in name order. The ones that matter here:

| Script | From | What it does |
|---|---|---|
| `S01syslogd`, `S02klogd` | BusyBox | System and kernel logging. |
| **`S05rootfs-expand`** | our overlay | **First boot only.** Runs `rootfs-expand` (log in `/var/log/rootfs-expand.log`). Finds the device mounted on `/` via `/proc/self/mountinfo`, extends the partition with `sfdisk`, tells the kernel with `partx -u` and grows ext4 with `resize2fs`, all while mounted. Writes `/etc/rootfs-expanded` so it never runs again. |
| `S10mdev` | BusyBox (mdev) | Starts mdev and loads the kernel modules for devices found at boot (their `modalias`). The SDIO Wi-Fi chip announces itself and mdev runs `modprobe brcmfmac`. The driver loads the firmware and `wlan0` appears. |
| `S40network` | Buildroot | `ifup -a`: brings up `lo` and requests DHCP on `eth0`. Without a cable this waits a few seconds, then continues. |
| **`S45wifi`** | our overlay | Runs `modprobe brcmfmac` again (in case mdev didn't), waits up to 15 s for `wlan0`, starts `wpa_supplicant -B -D nl80211 -i wlan0 -c /etc/wpa_supplicant.conf`, then `udhcpc -b`. `udhcpc` runs in the background and keeps asking for a DHCP address until the network is joined. |
| `S49chronyd` | chrony | Starts NTP. On the first good server response the clock jumps to the correct time (`makestep`). |
| `S50avahi-daemon` | avahi | Announces `mylab-rpi5.local` and the SSH service. |
| `S50sshd` | OpenSSH | First boot: creates host keys in `/etc/ssh/`. Then starts `sshd` on port 22. |
| **`S99boot-report`** | our overlay | 60 s later, in the background: writes `boot-report.txt` to the boot partition (see the file table). |

4. **Login prompts**: on the serial console (Pi 5 UART connector, 115200 baud) and on HDMI (`tty1`).

---

## 5. How to change things

| I want to... | Change | Then run |
|---|---|---|
| Change hostname, password policy, Wi-Fi network | `config.env` / `config.local.env` | `configure` + `build` |
| Add a file to the image (config, script) | Put it under [`board/overlay/`](board/overlay/) at its target path. For a boot script, use a name like `S60name` and add a `chmod 0755` to `post-build.sh`. | `configure` + `build` |
| Change a file after packages are installed (edit a package's config) | Add it to [`board/post-build.sh`](board/post-build.sh) (`$1` is the root filesystem directory) | `configure` + `build` |
| Add a package (for example `htop`) | Find the option with `menuconfig` (search with `/`), then add `BR2_PACKAGE_HTOP=y` to the fragment in `br.sh` | `configure` + `clean` + `build` |
| Change a kernel option | Easiest: `make -C ~/rpi5-os/buildroot-2026.08 O=~/rpi5-os/br-output linux-menuconfig`. To make it permanent, add a config fragment file with `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` in the fragment. | `clean` + `build` |
| Change Wi-Fi without rebuilding | On the Pi: `wpa_cli -i wlan0 ...` then `save_config` (see the main [README](../README.md#how-wi-fi-is-set-up-both-flows)) | — |
| Rebuild a single package | `make -C ~/rpi5-os/buildroot-2026.08 O=~/rpi5-os/br-output <pkg>-dirclean all` | — |

---

## 6. Where everything ends up on disk

```
~/rpi5-os/
├── buildroot-2026.08/          Buildroot source (from fetch)
├── br-dl/                      downloaded tarballs (kept by clean)
├── br-ccache/                  compiler cache (kept by clean)
├── br-generated/
│   ├── mylab.fragment          our options
│   └── mylab_rpi5_defconfig    stock + ours (mode 600: password hash)
├── br-overlay/                 the overlay actually used (regenerated by configure)
└── br-output/                  everything `clean` deletes
    ├── .config                 the full configuration
    ├── build.log               output of the last build
    ├── build/<pkg>-<ver>/      each package's unpacked, compiled source
    ├── host/                   cross-compiler and host tools
    ├── staging/                target headers/libraries used while compiling
    ├── target/                 the root filesystem, unpacked (inspect it!)
    └── images/
        ├── Image               the kernel
        ├── *.dtb               device trees
        ├── rpi-firmware/       config.txt, cmdline.txt, overlays/
        ├── boot.vfat           partition 1
        ├── rootfs.ext4         partition 2
        ├── sdcard.img          the full card image  ← flash this
        └── mylab-rpi5-buildroot-2026.08.img   copy made by export
```

`br-output/target/` is the most useful folder for learning: it is exactly what ends up as `/` on the Pi (except file ownership, which is applied while packing). `ls` around in it after a build.
