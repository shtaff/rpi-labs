# Custom Raspberry Pi 5 OS with SSH and Wi-Fi — Yocto

Build a Linux image for the Raspberry Pi 5 with the Yocto Project on WSL2, flash it, and prove SSH works — over Ethernet or Wi-Fi.

```
rpi5-custom-os/
├── config.env                  # hostname, password, key, Wi-Fi, versions  ← edit this
├── config.local.env.example    # copy to config.local.env (git-ignored) for Wi-Fi name/passphrase
├── common/
│   ├── lib.sh                  # WSL checks, PATH fix, key + password hash, wpa_supplicant.conf, export
│   └── target/rootfs-expand    # runs ON the Pi at first boot: grow / to the card size
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

Versions pinned (checked 2026-10-10): **Yocto 6.0 "wrynose"** (bitbake 2.18, meta-raspberrypi `wrynose`, exact commits in `yocto/layers.lock`).

---

## The mental model

Yocto is a restaurant kitchen: recipe books (**layers**), a head chef scheduling thousands of small jobs (**bitbake**), and a fridge of pre-cooked parts (**sstate-cache**). In .NET terms: a solution of many NuGet packages; you add your own package (layer) instead of editing others.

| | |
|---|---|
| Board selection | `MACHINE = "raspberrypi5"` from `meta-raspberrypi` |
| "Add SSH" | `IMAGE_FEATURES += "ssh-server-openssh"` |
| "Add Wi-Fi" | firmware + `wpa-supplicant` packages, our `wifi-config` recipe (systemd unit + networkd) |
| Our customisation | our own **layer** `meta-mylab` with an image recipe and small config recipes |
| First build | ~2–6 h, ~80–120 GB |
| Output | `mylab-image-raspberrypi5.rootfs.wic.xz` |

What ends up on the SD card: a FAT **boot** partition (Pi firmware, `config.txt`, kernel, device tree) and an ext4 **root** partition (your userspace). The Pi 5 boot ROM reads the first, the kernel mounts the second.

**How SSH access is set up:**
- Your WSL public key (`~/.ssh/id_ed25519.pub`, auto-created if missing) is baked into root's `authorized_keys`.
- The root password is asked once, stored only as a SHA-512 hash (used for HDMI/serial console login).
- By default SSH is **key-only** for root (`PermitRootLogin prohibit-password`). Set `ALLOW_ROOT_PASSWORD_SSH=yes` in `config.env` if your instructor wants to log in with the password.
- Ethernet gets an address by DHCP. Host keys are generated on first boot.

**What else is in the image:**
- **First-boot resize.** The image is small; at first boot `rootfs-expand.service` grows the root partition and ext4 to fill the card, while mounted, no reboot. It runs once (marker: `/etc/rootfs-expanded`).
- **mDNS.** `avahi-daemon` announces the Pi as `mylab-rpi5.local` (your `RPI_HOSTNAME`) and advertises SSH, so `ssh root@mylab-rpi5.local` works from Windows, macOS and most Linux desktops.
- **Time sync.** The Pi 5's RTC has no battery by default, so it boots with a wrong clock. `systemd-timesyncd` (comes with systemd) fixes it once the network is up.

**How Wi-Fi is set up:**
- The Pi 5's radio is an Infineon CYW43455 on SDIO, driven by the `brcmfmac` kernel module. The image adds the **firmware** (`brcmfmac43455-sdio.*`), the **regulatory database**, **wpa_supplicant** (+ `wpa_cli`, `wpa_passphrase`) and `iw`.
- The network comes from `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY`. Put them in `config.local.env` (copy `config.local.env.example`, it's git-ignored). If `WIFI_PSK` is empty you are asked for it at `configure` time, like the root password.
- `configure` writes `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf`: the SSID hex-encoded (any characters work), the passphrase turned into the 256-bit WPA PSK (what `wpa_passphrase` does), so the plain text is never in the image. The PSK still lets someone join that network, so don't share the image.
- `wpa_supplicant-nl80211@wlan0.service` starts when `wlan0` appears; `systemd-networkd` runs DHCP on it (`30-wlan.network`). When both are up, Ethernet's default route wins (lower metric).
- Supported: WPA2-Personal (WPA2/WPA3 transition-mode networks connect as WPA2) and open networks. Not supported: WPA3-only (SAE) and enterprise (802.1X) networks.
- `WIFI_SSID` empty = Ethernet only. The Wi-Fi stack is still installed, so you can add a network on the Pi later:
  ```sh
  wpa_cli -i wlan0 add_network                       # prints an id, e.g. 0
  wpa_cli -i wlan0 set_network 0 ssid '"MyNet"'
  wpa_cli -i wlan0 set_network 0 psk '"passphrase"'
  wpa_cli -i wlan0 enable_network 0
  wpa_cli -i wlan0 save_config                       # persists across reboots
  ```
  Restart / status: `systemctl restart wpa_supplicant-nl80211@wlan0`, `networkctl status wlan0`.

---

## 0. One-time WSL setup

1. Use **WSL2** with Ubuntu 24.04 (`wsl -l -v` → VERSION 2).
2. Give WSL enough memory. Create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=16GB      # Yocto wants 16GB+
   swap=16GB
   processors=8
   ```
   Then in PowerShell: `wsl --shutdown`, reopen Ubuntu.
3. Put this folder **inside the Linux filesystem**, e.g. `~/rpi5-custom-os`, not `/mnt/c/...`.

**Why not /mnt/c?** Files there go through a Windows↔Linux translation layer — like doing every DB call over a slow network share. Builds are ~10× slower, and NTFS is case-insensitive, which breaks the Linux kernel sources (`xt_TCPMSS.h` vs `xt_tcpmss.h`). The scripts refuse to run there.

**The PATH gotcha:** WSL appends Windows folders like `/mnt/c/Program Files/...` to `PATH`. The scripts strip `/mnt/*` entries automatically; to fix it permanently add to `/etc/wsl.conf`:
```ini
[interop]
appendWindowsPath=false
```

```bash
cd ~/rpi5-custom-os
chmod +x yocto/*.sh tools/*.sh   # only needed if you copied instead of git clone
./tools/lint.sh          # optional, seconds: catches broken line endings / exec bits / typos
nano config.env          # optional: hostname, password policy
cp config.local.env.example config.local.env
nano config.local.env    # Wi-Fi: WIFI_SSID, WIFI_COUNTRY (and WIFI_PSK, or be asked)
```

---

## 1. Build

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

**Why `layers.lock`?** A branch like `wrynose` keeps receiving fixes, so "build `wrynose`" means different sources next month. Pinning commits makes a rebuild produce the same image — the same idea as `package-lock.json` / `packages.lock.json`.

Clean rebuilds are cheap thanks to sstate: `./yocto/yocto.sh clean && ./yocto/yocto.sh build`.

---

## 2. Flash

### 2a. From WSL, the Linux way (`tools/flash.sh`)

WSL2 is a VM, so USB devices belong to Windows by default. **usbipd-win** is the extension cord: Windows lets go of the card reader and forwards it over USB/IP, and the Linux kernel sees a real `/dev/sdX`.

One-time setup, in PowerShell:
```powershell
winget install usbipd
```
Then reopen WSL, insert the card, and run:
```bash
./tools/flash.sh                    # the Yocto image (or a path to any .img/.wic/.xz)
./tools/flash.sh --dry-run          # see every command without writing anything
```

What it does, step by step:

| Step | Linux concept you're practising |
|---|---|
| Lists USB devices via `usbipd list`, picks the card reader, `bind`s it once (UAC prompt), `attach --wsl` | Device passthrough |
| Waits for a **new** disk to appear in `lsblk` | Kernel hot-plug and enumeration (`dmesg \| tail` shows it) |
| Refuses anything that isn't a whole, USB/removable disk ≤ 256 GB, holds `/`, or is smaller than the image; makes you type the device name | The `dd` "disk destroyer" safety habits |
| Unmounts partitions and writes with `bmaptool copy` and the `.bmap` (writes only blocks with data, checks sha256); falls back to `dd oflag=direct conv=fsync` | Block devices, page cache, fsync |
| Reads the card back and `cmp`s it with the image (dd path) | Verifying writes, not trusting them |
| Re-reads the partition table, mounts both partitions read-only, checks `config.txt`, the bcm2712 kernel/DTB, `sshd`, your key, the hostname and the Wi-Fi config | MBR partitions, vfat boot + ext4 rootfs |
| `usbipd detach`, so the reader goes back to Windows (`--keep-attached` to skip) | — |

Limitation: built-in laptop SD slots are often PCIe (SDHCI), not USB, and usbipd can't forward them. A USB card reader always works.

On native Linux the script skips the usbipd part and works the same.

### 2b. From Windows (fallback)

**Raspberry Pi Imager** → *Choose OS* → *Use custom* → pick the file from `Downloads\rpi5-images` → choose the card → **"No"** to OS customisation (that only works for Raspberry Pi OS; our image is already configured). balenaEtcher works the same way.

## 3. Boot and verify SSH

1. SD card in, **Ethernet cable** to your router (optional if Wi-Fi is configured), power on. Give it ~30 s on first boot.
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

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Build killed, `cc1plus: Killed` / bitbake `-9` | Out of RAM. Raise `.wslconfig` memory/swap, or `JOBS=4 ./yocto/yocto.sh build`. |
| `mylab-rpi5.local` doesn't resolve | Wait ~30 s after boot. Guest / office Wi-Fi often blocks multicast between clients: use `--scan` or the IP. On the Pi: `pidof avahi-daemon`. |
| `/` still small after first boot | `journalctl -u rootfs-expand`. Re-run by hand: `rm /etc/rootfs-expanded; rootfs-expand`. |
| Clock wrong / TLS "certificate not yet valid" | Needs Internet access to NTP (UDP 123). `timedatectl timesync-status`. |
| `bash\r: No such file or directory` | Scripts got CRLF line endings (a Windows checkout made before `.gitattributes` existed). Commit or stash your own changes first (the next command discards them), then `git rm --cached -r -q . && git reset --hard`. `./tools/lint.sh` lists affected files. |
| `--scan` finds nothing | Check the router's DHCP client list. With a monitor on HDMI you'll see a login prompt (root + your password), then `ip addr`. |
| Pi not reachable, no screen | `./tools/flash.sh --inspect` with the card back in the reader: shows how far the boot got (rootfs mounted, resize ran, SSH host keys created). |
| Rainbow screen / no boot | Bad flash or old Pi 5 bootloader EEPROM. Re-flash; update the EEPROM once with Raspberry Pi OS. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Every rebuild creates new host keys. `verify-ssh.sh` uses its own `~/rpi5-os/known_hosts`; for plain `ssh` run `ssh-keygen -R <pi-ip>`. |
| `Permission denied (publickey)` | Key mismatch: the image has the key from `SSH_PUBKEY` at configure time. Re-run `configure` + `build` after changing keys. |
| `flash.sh`: "hostname is 'X' but config says 'Y'" | The image was built with different settings, usually because `config.local.env` is git-ignored and wasn't copied to the WSL folder you built from. Copy it, then rebuild. |
| No `wlan0` | `dmesg \| grep brcmfmac`. "firmware load failed": firmware missing from `/lib/firmware/brcm`. No output at all: driver not loaded, try `modprobe brcmfmac`. |
| `wlan0` exists but doesn't connect | `wpa_cli -i wlan0 status` (look at `wpa_state`), `iw dev wlan0 link`, `wpa_cli -i wlan0 scan; wpa_cli -i wlan0 scan_results` to see if the SSID is visible. Common causes: wrong passphrase, 5 GHz channel blocked because `WIFI_COUNTRY` is unset, WPA3-only access point. |
| Wi-Fi connected but no IP | `networkctl status wlan0`, `journalctl -u systemd-networkd`. |
| Serial console | Pi 5 has a dedicated 3-pin UART connector (`ttyAMA10`, 115200 8N1) — useful when the network is the problem. |
| User-namespace / `unshare` errors | Ubuntu 24.04 AppArmor rule: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`. |
