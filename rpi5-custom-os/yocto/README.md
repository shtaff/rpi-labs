# Yocto flow: step by step

This folder builds a Raspberry Pi 5 Linux image with the **Yocto Project** (release 6.0 "wrynose"). It contains OpenSSH with your key, Wi-Fi, first-boot resize, mDNS, NTP and **ROS 2 Jazzy** with our `counter_demo` nodes, built the Yocto way: from **layers** of **recipes**, scheduled by **bitbake**, with systemd as the init system.

One script drives everything: [`yocto.sh`](yocto.sh). This document explains every file it uses, what each step does, and what happens on the Pi when it boots.

- [1. Files](#1-files)
- [2. Yocto in five ideas](#2-yocto-in-five-ideas)
- [3. Step by step](#3-step-by-step)
- [4. What happens when the Pi boots](#4-what-happens-when-the-pi-boots)
- [5. How to change things](#5-how-to-change-things)
- [6. Where everything ends up on disk](#6-where-everything-ends-up-on-disk)

---

## 1. Files

### In this folder

| File | What it is | Why it's needed |
|---|---|---|
| [`yocto.sh`](yocto.sh) | The driver script. Steps: `deps`, `fetch`, `update`, `configure`, `build`, `shell`, `export`, `clean`, `all`. | Fetches the layers, writes the build configuration, runs `bitbake` in the right environment and checks the result. |
| [`layers/`](layers/) | The upstream layers (bitbake, openembedded-core, meta-yocto, meta-raspberrypi, meta-openembedded, meta-ros) as **git submodules**; URLs and branches in `.gitmodules` at the git root. | Makes builds **reproducible**: the repo records the exact commit of each layer, so the same checkout gives the same sources, even months later. Same idea as `package-lock.json`. Changed only by `update` + a commit. |
| [`meta-mylab/`](meta-mylab/) | **Our layer**: everything this project adds to Yocto. | In Yocto you never edit other people's layers; you add your own on top. |
| [`meta-mylab/conf/layer.conf`](meta-mylab/conf/layer.conf) | Layer definition. | Tells bitbake where our recipes are (`recipes-*/*/*.bb`), the layer's priority (10), which layers it needs (`core`, `raspberrypi`) and which Yocto release it works with (`wrynose`). Also sets `MYLAB_REPO` (the repo root, where recipes take `common/target/` and `ros2_ws/src/` from) and `MYLAB_GENERATED_DIR` (`build/conf/mylab/`, your key and Wi-Fi config). |
| [`meta-mylab/conf/distro/mylab.conf`](meta-mylab/conf/distro/mylab.conf) | **Our distro**: `require`s poky, then sets systemd, the `wifi` feature, the Wi-Fi firmware licence flag and the meta-ros QA setting. | The fixed policy of the image lives in the layer, versioned with it, instead of in a generated `local.conf`. |
| [`meta-mylab/conf/templates/mylab/local.conf.sample`](meta-mylab/conf/templates/mylab/local.conf.sample) | Template for `build/conf/local.conf`. | `oe-init-build-env` copies it once (`TEMPLATECONF`); after that `local.conf` is yours to edit. |
| [`meta-mylab/recipes-core/images/mylab-image.bb`](meta-mylab/recipes-core/images/mylab-image.bb) | **The image recipe**: what goes into the root filesystem. | Starts from `core-image-minimal` and adds the SSH server, kernel modules, `iproute2`, the Wi-Fi packages, `rootfs-expand` and `avahi-daemon`. Sets the root password hash with `extrausers`. Adds 128 MB of free space. Output `.wic.xz` + `.wic.bmap`. `mylab_check_packages` fails the build if `MYLAB_REQUIRED_PACKAGES` aren't installed. |
| [`meta-mylab/recipes-mylab/ssh-root-key/ssh-root-key.bb`](meta-mylab/recipes-mylab/ssh-root-key/ssh-root-key.bb) | Recipe for a tiny package. | Installs your public key (from `build/conf/mylab/authorized_keys`) as `${ROOT_HOME}/.ssh/authorized_keys` (`/home/root/.ssh/` in Yocto), mode 600. |
| [`meta-mylab/recipes-mylab/wifi-config/wifi-config.bb`](meta-mylab/recipes-mylab/wifi-config/wifi-config.bb) | Recipe for the Wi-Fi configuration package. | Installs the `wpa_supplicant` config (generated into `build/conf/mylab/`; it holds the PSK) and the network file, and enables `wpa_supplicant-nl80211@wlan0.service`. Needs `systemd` and `wifi` in `DISTRO_FEATURES`. |
| [`meta-mylab/recipes-mylab/wifi-config/files/30-wlan.network`](meta-mylab/recipes-mylab/wifi-config/files/30-wlan.network) | systemd-networkd config for `wlan0`. | DHCP on Wi-Fi, with a higher route metric (2048) so Ethernet is preferred when both are connected. |
| [`meta-mylab/recipes-mylab/rootfs-expand/rootfs-expand.bb`](meta-mylab/recipes-mylab/rootfs-expand/rootfs-expand.bb) | Recipe for the first-boot resize. | Installs `/usr/sbin/rootfs-expand` (from [`../common/target/`](../common/target/rootfs-expand)) and `rootfs-expand.service`, enables the service, and pulls in `sfdisk`, `partx` and `resize2fs`. |
| [`meta-mylab/recipes-mylab/rootfs-expand/files/rootfs-expand.service`](meta-mylab/recipes-mylab/rootfs-expand/files/rootfs-expand.service) | systemd unit. | Runs the resize once at boot, after `/` is writable. Skipped once `/etc/rootfs-expanded` exists. |
| [`meta-mylab-ros/`](meta-mylab-ros/) | **Our ROS 2 layer**, separate from `meta-mylab`. | Adds ROS 2 and our package to `mylab-image` with a `.bbappend`, so `meta-mylab` stays ROS-free. |
| [`meta-mylab-ros/conf/layer.conf`](meta-mylab-ros/conf/layer.conf) | Layer definition. | Priority 13; needs `mylab` (the image it extends) and meta-ros' `ros2-layer`. |
| [`meta-mylab-ros/recipes-core/images/mylab-image.bbappend`](meta-mylab-ros/recipes-core/images/mylab-image.bbappend) | Additions to our image recipe. | `IMAGE_INSTALL` += `ros-core` (rclcpp, rclpy, launch, `ros2` CLI, Fast DDS), `demo-nodes-cpp`, `counter-demo`, `ros2-profile`. |
| [`meta-mylab-ros/recipes-ros/counter-demo/counter-demo_1.0.0.bb`](meta-mylab-ros/recipes-ros/counter-demo/counter-demo_1.0.0.bb) | Recipe for our ROS 2 package. | Builds [`../ros2_ws/src/counter_demo`](../ros2_ws/src/counter_demo), read in place, with meta-ros' `ros_ament_cmake` class into `/opt/ros/jazzy`, and installs and enables `counter-demo.service`. |
| [`meta-mylab-ros/recipes-ros/counter-demo/files/counter-demo.service`](meta-mylab-ros/recipes-ros/counter-demo/files/counter-demo.service) | systemd unit. | Runs `ros2 launch counter_demo counter.launch.py` at boot. |
| [`meta-mylab-ros/recipes-ros/ros2-profile/ros2-profile.bb`](meta-mylab-ros/recipes-ros/ros2-profile/ros2-profile.bb) | Recipe for `/etc/profile.d/ros2.sh`. | Sources `/opt/ros/jazzy/setup.sh` in login shells, so `ros2` just works over SSH. |
| [`quick-build.sh`](quick-build.sh) | The whole flow (deps → fetch → configure → build → export) as one top-to-bottom script, one comment per line, no checks. Checks out the layer submodules at their recorded commits. | A quick read of the whole flow, or a one-command build. Builds the same image as `yocto.sh`. Its `bblayers.conf` and `auto.conf` mirror the ones `yocto.sh` writes: keep the two in sync. |
| `README.md` | This document. | |

### Shared files this flow uses (outside this folder)

| File | Used for |
|---|---|
| [`../config.env`](../config.env) | All settings: hostname, root password policy, SSH key path, Wi-Fi, `YOCTO_RELEASE`, `ROS2_DISTRO`, `WORK_DIR`, `JOBS`. |
| `../config.local.env` | Your private overrides, mainly the Wi-Fi network name and passphrase. Git-ignored; create it from [`../config.local.env.example`](../config.local.env.example). |
| [`../common/lib.sh`](../common/lib.sh) | Helper functions: `preflight` (WSL/disk/RAM checks, `PATH` fix), `ensure_ssh_key`, `make_root_hash`, `make_wifi_conf`, `export_to_windows`. |
| [`../common/target/rootfs-expand`](../common/target/rootfs-expand) | The first-boot resize script (runs on the Pi). |
| [`../tools/flash.sh`](../tools/flash.sh) | Writes the `.wic.xz` to an SD card from WSL, using `bmaptool` and the `.bmap` file. |
| [`../tools/verify-ssh.sh`](../tools/verify-ssh.sh) | Finds the booted Pi, logs in with your key and checks everything works. |
| [`../tools/lint.sh`](../tools/lint.sh) | Static checks of all scripts and of the layer submodules, in seconds. |
| [`../ros2_ws/src/counter_demo/`](../ros2_ws/src/counter_demo/) | The ROS 2 package built by `counter-demo.bb` (the same source you build on the PC with colcon). |
| [`../tools/ros2.sh`](../tools/ros2.sh) | ROS 2 on the PC (install, official demo, build, check) and `ros2.sh pi`: the check on the Pi over SSH. |

### Generated files (in `~/rpi5-os/`, never in the repo)

The upstream layers are the one exception: `fetch` checks them out **in the repo**, as submodules in `yocto/layers/`:

| Path (in `yocto/layers/`) | Created by | Contents |
|---|---|---|
| `bitbake/` | `fetch` | The bitbake build tool. |
| `openembedded-core/` | `fetch` | **oe-core**: the base layer (`meta/`) with ~1000 recipes (gcc, glibc, systemd, openssh, wpa-supplicant, ...), the core classes and `oe-init-build-env`. |
| `meta-yocto/` | `fetch` | Contains `meta-poky`, which defines the **poky** distribution (default distro policy). |
| `meta-raspberrypi/` | `fetch` | The **BSP** (board support) layer: the `raspberrypi5` machine, the Raspberry Pi kernel, boot firmware, `config.txt` generation, Wi-Fi firmware recipes, the SD card layout. |
| `meta-openembedded/` | `fetch` | Extra layers on top of oe-core. We use `meta-oe`, `meta-python` and `meta-networking`: libraries and Python modules ROS needs. |
| `meta-ros/` | `fetch` | **meta-ros**: `meta-ros-common` and `meta-ros2` (ROS build classes such as `ros_ament_cmake`) and `meta-ros2-jazzy` (the Jazzy package recipes, generated from each package's `package.xml`). |

In `~/rpi5-os/`:

| Path | Created by | Contents |
|---|---|---|
| `yocto/build/conf/mylab/` | `configure` | `authorized_keys` and `wpa_supplicant-nl80211-wlan0.conf`: your data, read by the recipes. |
| `yocto/build/conf/bblayers.conf`, `auto.conf` | `configure` | Which layers to use; the settings from `config.env`. Rewritten on every `configure`. |
| `yocto/build/conf/local.conf` | first `configure` | The build settings, from the template. Yours to edit, never rewritten. |
| `yocto/build/tmp/` | `build` | Work directories, packages, the root filesystem and the final images. `clean` deletes this. |
| `yocto-downloads/` | `build` | Every source tarball and git repo bitbake fetched (`DL_DIR`). Kept by `clean`. |
| `yocto-sstate/` | `build` | **Shared state cache**: saved output of every finished task (`SSTATE_DIR`). Kept by `clean`; this is what makes rebuilds fast. |

---

## 2. Yocto in five ideas

1. **Recipe (`.bb`)**: how to build one piece of software: where the source is (`SRC_URI`), how to compile and install it (`do_compile`, `do_install`), and which **packages** to split the result into (`FILES:...`). One recipe often makes several packages: `wpa-supplicant` makes `wpa-supplicant`, `wpa-supplicant-cli`, `wpa-supplicant-passphrase`, and so on.
2. **Layer (`meta-*`)**: a folder of recipes and configuration. Layers are stacked; a higher-priority layer can add to or override a lower one without editing it (`.bbappend`). We use eight upstream layers plus `meta-mylab` and `meta-mylab-ros`.
3. **MACHINE, DISTRO, IMAGE**: three independent choices.
   - `MACHINE = "raspberrypi5"` (from meta-raspberrypi): CPU tuning (Cortex-A76), kernel, device trees, boot files, serial console.
   - `DISTRO = "mylab"` (ours, built on poky from meta-poky): policy, such as which C library, init system (systemd) and features like `wifi`.
   - `IMAGE = mylab-image` (ours): which packages go into the root filesystem.
4. **bitbake and tasks**: bitbake reads all the recipes, works out the dependencies, and runs each recipe's **tasks** (`do_fetch`, `do_unpack`, `do_patch`, `do_configure`, `do_compile`, `do_install`, `do_package`, ...) in parallel, as soon as their inputs are ready.
5. **sstate (shared state)**: each task's output is saved, keyed by a hash of all its inputs (source, recipe, configuration, dependencies). If nothing changed, the next build reuses the saved output instead of rebuilding. The first build takes hours; a rebuild after a small change takes minutes.

Compared to a single-config build system such as Buildroot, Yocto is more setup, but you can rebuild a single package, keep a package feed, and reuse sstate across machines and projects. That is why it is common in industry, and why it needs ~100 GB and 16 GB+ RAM.

---

## 3. Step by step

Run everything from the repo root inside WSL (Linux filesystem, not `/mnt/c`), as a normal user (bitbake refuses to run as root):

```bash
./yocto/yocto.sh deps       # once
./yocto/yocto.sh all        # = fetch → configure → build → export
```

Every step except `deps`, `shell`, `export` and `clean` starts with `yocto_preflight`:
- `preflight` from `lib.sh`: WSL2 check, `WORK_DIR` not on the Windows drive, at least **120 GB** free, a warning if RAM + swap is below **16 GB**, Windows folders removed from `PATH`
- refuses to run as root, or with the repo on the Windows drive (the layers are checked out inside it)
- warns if Ubuntu's AppArmor setting `apparmor_restrict_unprivileged_userns=1` is on, because bitbake uses user namespaces to cut tasks off from the network
- sets `LANG=en_US.UTF-8`, which bitbake requires

### `deps`: install build tools on your PC

Runs `apt-get install` for the host tools the Yocto manual lists (`gawk`, `diffstat`, `chrpath`, `texinfo`, `socat`, `cpio`, `lz4`, `zstd`, Python modules `git`, `jinja2`, `pexpect`, `subunit`, ...), plus `openssl`, `openssh-client`, `bmap-tools` and `parted`. Then generates the `en_US.UTF-8` locale. Needs `sudo`, once per machine.

Yocto builds most of its own tools, including the cross-compiler, from source. That is why so few host packages are needed and why the first build is long.

### `fetch`: check out the layers (at the recorded commits)

Every upstream layer is a git submodule in [`layers/`](layers/), declared in `.gitmodules` at the git root:

| Layer | Branch (for `update`) | URL |
|---|---|---|
| `bitbake` | `2.18` | github.com/openembedded/bitbake |
| `openembedded-core` | `wrynose` | github.com/openembedded/openembedded-core |
| `meta-yocto` | `wrynose` | github.com/yoctoproject/meta-yocto |
| `meta-raspberrypi` | `wrynose` | github.com/agherzan/meta-raspberrypi |
| `meta-openembedded` | `wrynose` | github.com/openembedded/meta-openembedded |
| `meta-ros` | `wrynose` | github.com/ros/meta-ros |

`fetch` runs `git submodule sync` (picks up URL changes) and `git submodule update --init --depth 1 -- yocto/layers`: each layer is checked out at the commit this repo records, with no history (detached HEAD). Layers already at that commit are left alone. Then it checks that `meta-raspberrypi/conf/machine/raspberrypi5.conf` and `meta-ros/meta-ros2-jazzy` (from `ROS2_DISTRO`) exist.

The URLs are the GitHub copies, because a shallow checkout of a pinned commit needs a server that serves commits by hash. To use another server (e.g. git.yoctoproject.org) without changing the repo: `git config submodule.<path>.url <url>` in your clone, or a `url.<base>.insteadOf` rule.

`bitbake/` must sit next to `openembedded-core/`: the environment script `oe-init-build-env` looks for it there.

### `update`: change the pinned versions (on purpose)

`update` runs `git submodule update --remote --depth 1`: every layer moves to the tip of its branch in `.gitmodules`, and the script shows which commits changed. Rebuild, test, then `git add yocto/layers` and commit. Until you commit, `fetch` (and so `configure` and `all`) puts the layers back on the recorded commits. To move a single layer, `cd yocto/layers/<name>`, `git fetch --depth 1 origin <commit>`, `git checkout FETCH_HEAD`, and commit the new gitlink.

Why bother: `wrynose` is a stable branch that keeps receiving fixes. Without pinning, "build wrynose" today and in three months gives different images, and a build that worked can break with nothing changed on your side.

### `configure`: set up the build directory

**3.0 Fetch.** Runs `fetch` first, so layers added or moved since the last build (e.g. by a `git pull`) are checked out; layers already at their recorded commit are skipped.

**3.1 SSH key and root password** (`ensure_ssh_key`, `make_root_hash`): a key pair is created if missing, and the password becomes a SHA-512 crypt hash.

**3.2 Write your data.** Our layers are used **in place**, straight from the repo; only two files depend on you, and they go to `build/conf/mylab/` (mode 700), outside the repo:

| File | Generated from | Read by |
|---|---|---|
| `authorized_keys` | your public key (`SSH_PUBKEY`) | `ssh-root-key.bb` |
| `wpa_supplicant-nl80211-wlan0.conf` | `make_wifi_conf` (see below) | `wifi-config.bb` |

The recipes find them through `FILESEXTRAPATHS:prepend = "${MYLAB_GENERATED_DIR}:"`: an extra folder bitbake searches for `file://` sources. `rootfs-expand.bb` and `counter-demo.bb` do the same with `${MYLAB_REPO}/common/target` and `${MYLAB_REPO}/ros2_ws/src`, so the resize script and the ROS package are read from where you edit them.

How `make_wifi_conf` (in `common/lib.sh`) writes the Wi-Fi config:
- The SSID is written in **hex**, so any characters work.
- The passphrase becomes the 256-bit PSK: PBKDF2-SHA1(passphrase, SSID, 4096 rounds), what `wpa_passphrase` calculates. The plain passphrase never enters the image.
- `ctrl_interface` and `update_config=1` let you change networks on the Pi with `wpa_cli`.
- If `WIFI_PSK` is empty you're asked for it; an empty answer means an open network. If `WIFI_SSID` is empty, no network is configured.

Bitbake notices when a file in `SRC_URI` changes (it hashes the files), so changing the key or the Wi-Fi settings rebuilds only those two small packages, and editing the C++ code in `ros2_ws/src/counter_demo` rebuilds only `counter-demo` and the image.

It also removes what older versions of `yocto.sh` left behind: the layer copies in `~/rpi5-os/yocto/meta-mylab*` and a fully generated `local.conf`.

**3.3 Write `build/conf/bblayers.conf`**: the list of layers bitbake reads:

```
openembedded-core/meta     core recipes and classes
meta-yocto/meta-poky       the poky distro
meta-raspberrypi           the Pi 5 machine
meta-openembedded/meta-oe, meta-python, meta-networking   libraries ROS needs
meta-ros/meta-ros-common, meta-ros2                       ROS build classes
meta-ros/meta-ros2-jazzy   ROS 2 Jazzy recipes
meta-mylab                 ours
meta-mylab-ros             ours: ROS 2 in the image
```

**3.4 Write `build/conf/auto.conf`**: the settings that come from `config.env`, rewritten on every `configure`. Mode 600, because it contains the password hash. Bitbake reads `auto.conf` on its own, just before `local.conf`, so anything you set in `local.conf` wins.

| Setting | Meaning |
|---|---|
| `DL_DIR`, `SSTATE_DIR` | Downloads and sstate cache go outside `build/`, so `clean` keeps them. |
| `BB_NUMBER_THREADS`, `PARALLEL_MAKE` | How many bitbake tasks run at once, and `make -j` inside each. Both use `JOBS` (default: all CPUs). Lower `JOBS` if WSL runs out of memory. |
| `hostname:pn-base-files` | Sets `/etc/hostname`. The `:pn-base-files` suffix means "only for the `base-files` recipe". |
| `MYLAB_ROOT_HASH`, `MYLAB_ALLOW_ROOT_PASSWORD_SSH` | Our own variables, read by `mylab-image.bb`. Every `$` in the hash is escaped as `\$`, otherwise bitbake would try to expand it. |

**3.5 `local.conf`, from the template.** The first time the build environment is entered, `oe-init-build-env` copies [`meta-mylab/conf/templates/mylab/local.conf.sample`](meta-mylab/conf/templates/mylab/local.conf.sample) to `build/conf/local.conf` (`yocto.sh` exports `TEMPLATECONF` pointing there). It is never rewritten: edit it freely.

| Setting | Meaning |
|---|---|
| `MACHINE ?= "raspberrypi5"` | Build for the Pi 5. |
| `DISTRO ?= "mylab"` | Our distro, [`meta-mylab/conf/distro/mylab.conf`](meta-mylab/conf/distro/mylab.conf): see below. |
| `PACKAGE_CLASSES ?= "package_ipk"` | Packages are built in the small `.ipk` format (opkg). They're used to assemble the image; there's no package manager on the Pi. |
| `INHERIT += "rm_work"` | Deletes each recipe's work directory once it's finished. Saves tens of GB. |
| `ENABLE_UART = "1"` | meta-raspberrypi writes `enable_uart=1` into `config.txt`, so the serial console works. |
| `USER_CLASSES ?= "buildstats"` | Records task timings in `tmp/buildstats/`. |
| `PATCHRESOLVE = "noop"` | If a patch fails, stop instead of opening an interactive shell. |

The fixed policy is in the **distro**, [`mylab.conf`](meta-mylab/conf/distro/mylab.conf), which `require`s `poky.conf` and adds:

| Setting | Meaning |
|---|---|
| `DISTRO = "mylab"`, `DISTROOVERRIDES = "poky:mylab"` | Our name (it shows in `/etc/os-release`); `:poky` overrides in other layers still apply. |
| `POKY_INIT_MANAGER = "systemd"` | systemd as init (poky's default is sysvinit). poky's hook for derived distros, so `INIT_MANAGER` in `local.conf` still wins. |
| `DISTRO_FEATURES:append = " wifi"` | `wifi-config` requires it. |
| `LICENSE_FLAGS_ACCEPTED:append = " synaptics-killswitch"` | Accepts the licence of the Raspberry Pi Wi-Fi/Bluetooth firmware. Without it those firmware packages can't be built. |
| `ERROR_QA:remove` / `WARN_QA:append = "license-exists"` | meta-ros recipes name licences (e.g. `BSD`) that oe-core has no licence text for. That check becomes a warning instead of failing the build, as in meta-ros' own CI configuration. |

And the image recipe sets `IMAGE_FSTYPES = "wic.xz wic.bmap"`: a compressed whole-disk image plus a block map (`.bmap`) for fast, verified flashing.

**3.6 Check.** Runs `bitbake-layers show-layers` inside the build environment. If a layer path is wrong or the layers don't support this release (`LAYERSERIES_COMPAT`), this fails here instead of an hour into the build.

### `build`: run bitbake

`with_env bitbake mylab-image`. `with_env` runs a command inside the Yocto environment: it `cd`s into `openembedded-core` and `source`s `oe-init-build-env build/`, which puts `bitbake` on `PATH`. It does this in a subshell, so your shell isn't changed. First build: 2–6 hours. What happens:

1. **Parse.** Bitbake reads every recipe in every layer (several thousand), applies `local.conf`, the distro and machine settings and any `.bbappend`, and builds the **task graph** for `mylab-image`.
2. **Check sstate.** For every task, bitbake hashes its inputs and looks in `yocto-sstate/`. Matching tasks are restored instead of run. On a first build nothing matches.
3. **Run tasks, many in parallel.** Each recipe gets its own work directory in `tmp/work/<arch>/<recipe>/<version>/` and goes through:
   - `do_fetch`: download to `yocto-downloads/`, checking the checksums
   - `do_unpack`, `do_patch`
   - `do_configure`, `do_compile`: with the cross-compiler Yocto built earlier from the gcc recipes
   - `do_install`: into a private `image/` folder, never directly into the root filesystem
   - `do_package`: splits the files into packages, strips binaries, works out run-time dependencies
   - `do_package_write_ipk`: writes the `.ipk` files to `tmp/deploy/ipk/`
4. **Our recipes:**
   - `ssh-root-key`: copies `authorized_keys` into `${ROOT_HOME}/.ssh/` (mode 600 on the file, 700 on the folder).
   - `wifi-config`:
     - installs `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf` (mode 600) and `/etc/systemd/network/30-wlan.network`
     - creates the symlink `/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.wants/wpa_supplicant-nl80211@wlan0.service`. That is the same thing `systemctl enable wpa_supplicant-nl80211@wlan0` does: the supplicant starts as soon as `wlan0` exists.
     - depends on `wpa-supplicant`, which ships the `wpa_supplicant-nl80211@.service` template.
   - `rootfs-expand`: installs the script and the unit. The `systemd` class enables the unit (`SYSTEMD_SERVICE`) and adds `util-linux-sfdisk`, `util-linux-partx` and `e2fsprogs-resize2fs` as dependencies.
5. **Kernel and boot files** (from meta-raspberrypi): the Raspberry Pi kernel (`Image`), the Pi 5 device trees, `config.txt` (with `enable_uart=1`) and `cmdline.txt` (root partition, serial console).
6. **`do_rootfs` for `mylab-image`.** Creates an empty root filesystem and installs into it:
   - **from `core-image-minimal`**: `packagegroup-core-boot` (systemd, base files, BusyBox shell and tools, udev) and the machine's recommended packages, which include the Wi-Fi/BT firmware
   - **from `IMAGE_FEATURES += "ssh-server-openssh"`**: `openssh-sshd` and related packages
   - **from `IMAGE_INSTALL`**, everything we listed: `ssh-root-key`, `kernel-modules` (every driver, including `brcmfmac`), `iproute2`, `linux-firmware-rpidistro-bcm43455`, `wireless-regdb-static`, `wpa-supplicant`, `wpa-supplicant-cli`, `wpa-supplicant-passphrase`, `iw`, `wifi-config`, `rootfs-expand`, `avahi-daemon`

   Then it runs the image-level steps:
   - packages' post-install scripts, where possible
   - **`extrausers`**: `usermod -p '<hash>' root` sets the root password in `/etc/shadow`
   - if `MYLAB_ALLOW_ROOT_PASSWORD_SSH = "yes"`, the **`allow-root-login`** image feature, which lets root log in over SSH with the password; without it root may log in with the key only
   - writes the **manifest**: a list of every installed package
7. **`do_image_wic`.** The `wic` tool builds the disk image from a layout file (`.wks`) supplied by meta-raspberrypi: partition 1 = FAT boot partition (kernel, device trees, `config.txt`, `cmdline.txt`), partition 2 = ext4 root (the rootfs plus `IMAGE_ROOTFS_EXTRA_SPACE`, 128 MB free). Then compresses it to `.wic.xz` and writes the `.wic.bmap` block map.

What makes sure nothing was silently left out:
1. Every package named in `IMAGE_INSTALL` (`ssh-root-key`, `wifi-config`, the Wi-Fi firmware, `rootfs-expand`, `avahi-daemon`, `ros-core`, `counter-demo`, ...) must exist, or bitbake stops with an error.
2. Packages that arrive indirectly are listed in `MYLAB_REQUIRED_PACKAGES`: `openssh-sshd` (from the `ssh-server-openssh` image feature) and, from meta-mylab-ros, `ros2cli` (from `ros-core`). `mylab_check_packages`, a `ROOTFS_POSTPROCESS_COMMAND` in `mylab-image.bb`, fails the build if one isn't installed.
3. `yocto.sh` checks that `tmp/deploy/images/raspberrypi5/mylab-image-raspberrypi5*.wic.xz` exists.

NTP needs no extra package: `systemd-timesyncd` comes with systemd.

### `shell`: explore the build interactively

Opens a bash shell inside the Yocto environment. Useful commands there:

```bash
bitbake -e mylab-image | less            # every variable's final value, and where it was set
bitbake -e mylab-image | grep ^IMAGE_INSTALL=
bitbake-layers show-recipes '*wpa*'      # which layer provides a recipe
bitbake -c menuconfig virtual/kernel     # kernel options (text UI)
bitbake wifi-config -c cleansstate && bitbake wifi-config   # rebuild one recipe from scratch
oe-pkgdata-util list-pkg-files wpa-supplicant-cli           # which files a package contains
```

`exit` to leave.

### `export`: hand the image to Windows

1. Copies the `.wic.xz` (following the symlink in the deploy folder) to `~/rpi5-os/mylab-rpi5-yocto-wrynose.wic.xz`.
2. Copies it to `C:\Users\<you>\Downloads\rpi5-images\`. Raspberry Pi Imager can open `.wic.xz` directly (*Use custom*).
3. Prints the next steps. `./tools/flash.sh yocto` uses the original file in the deploy folder **and** its `.bmap`, so it writes only the blocks that contain data and checks each one's SHA-256.

### `clean`: start the build over

Deletes `build/tmp/`. Downloads and sstate are kept, so the next `build` restores most tasks from sstate and finishes in minutes, not hours. You rarely need `clean`: bitbake rebuilds exactly what changed. Use it to free disk space or to rule out a corrupted `tmp/`.

---

## 4. What happens when the Pi boots

1. **Bootloader (in the Pi 5's EEPROM)** reads partition 1: `config.txt`, the device tree, the kernel. It starts the kernel with `cmdline.txt` (root on partition 2, kernel console on the serial port).
2. **Kernel** mounts the root filesystem and starts `/sbin/init` = **systemd**.
3. **systemd** starts units in parallel, ordered by their dependencies. The ones that matter here:

| Unit | From | What it does |
|---|---|---|
| `systemd-udevd` | systemd | Handles device events. It loads `brcmfmac` for the SDIO Wi-Fi chip; the driver loads its firmware from `/lib/firmware`, and `wlan0` appears. |
| `systemd-remount-fs` | systemd | Applies the `/etc/fstab` mount options to `/`, making sure it is read-write. |
| **`rootfs-expand.service`** | `rootfs-expand` recipe | **First boot only** (`ConditionPathExists=!/etc/rootfs-expanded`). Runs after `/` is writable. Finds the device mounted on `/`, extends the partition with `sfdisk`, tells the kernel with `partx -u` and grows ext4 with `resize2fs`, all while mounted. Then writes the marker. Log: `journalctl -u rootfs-expand`. |
| `sshdgenkeys` | openssh | First boot: creates the SSH host keys (why the first boot takes a bit longer). |
| `systemd-networkd` | systemd | DHCP on Ethernet (oe-core's `80-wired.network`) and on `wlan0` (our `30-wlan.network`). |
| **`wpa_supplicant-nl80211@wlan0`** | wpa-supplicant + `wifi-config` | Starts as soon as the `wlan0` device appears and joins the network from `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf`. networkd then gets an IP address over DHCP. |
| `systemd-timesyncd` | systemd | NTP: sets the clock once the network is up, and saves it to disk on shutdown so the clock doesn't go backwards. |
| `avahi-daemon` | avahi | Announces `mylab-rpi5.local` and the SSH service. |
| `sshd` | openssh | SSH on port 22. |
| **`counter-demo`** | `counter-demo` recipe | `ros2 launch counter_demo counter.launch.py`: `counter_publisher` and `counter_subscriber`. Log: `journalctl -u counter-demo -f`. |
| `serial-getty@ttyAMA10` | systemd | Login prompt on the serial console. |

Useful commands on the Pi: `systemctl status`, `systemctl --failed`, `journalctl -b`, `networkctl`, `timedatectl`.

---

## 5. How to change things

| I want to... | Change | Then run |
|---|---|---|
| Change hostname, password policy, Wi-Fi network | `config.env` / `config.local.env` | `configure` + `build` |
| Add a package that exists in our layers (for example `htop`) | Add it to `IMAGE_INSTALL:append` in [`mylab-image.bb`](meta-mylab/recipes-core/images/mylab-image.bb). Check it exists first: `bitbake-layers show-recipes htop` in `shell`. Many packages live in **meta-openembedded**; we use `meta-oe`, `meta-python` and `meta-networking` from it, others (e.g. `meta-multimedia`) can be added to `bblayers.conf` in `yocto.sh` (then `configure` first). | `build` |
| Change the ROS 2 nodes | Edit [`../ros2_ws/src/counter_demo`](../ros2_ws/src/counter_demo); test on the PC with `./tools/ros2.sh build check`. New dependencies go in `package.xml` **and** in `ROS_BUILD_DEPENDS` / `ROS_EXEC_DEPENDS` of `counter-demo_1.0.0.bb`. | `build` |
| Add another ROS 2 package from meta-ros (e.g. `demo-nodes-py`) | `IMAGE_INSTALL:append` in [`mylab-image.bbappend`](meta-mylab-ros/recipes-core/images/mylab-image.bbappend) | `build` |
| Install my own file or script | Write a small recipe in `meta-mylab/recipes-mylab/<name>/` (copy [`rootfs-expand.bb`](meta-mylab/recipes-mylab/rootfs-expand/rootfs-expand.bb) as a template) and add it to `IMAGE_INSTALL` | `build` |
| Change a file installed by someone else's recipe | Create `meta-mylab/recipes-.../<recipe>/<recipe>.bbappend`. Never edit the upstream layer. | `build` |
| Change a build setting (e.g. `INHERIT`, `SYSTEMD_AUTO_ENABLE:pn-...`) | `~/rpi5-os/yocto/build/conf/local.conf` for you only; [`mylab.conf`](meta-mylab/conf/distro/mylab.conf) or the [template](meta-mylab/conf/templates/mylab/local.conf.sample) for everyone (the template only reaches a new build dir: copy the change into your `local.conf`) | `build` |
| Change a kernel option | Quick test: `bitbake -c menuconfig virtual/kernel` in `shell`. To keep it: a `linux-raspberrypi_%.bbappend` with a `.cfg` fragment in `SRC_URI`. | `build` |
| Move to newer upstream layers | `./yocto/yocto.sh update`, rebuild, test, `git add yocto/layers` and commit | `build` |
| Change Wi-Fi without rebuilding | On the Pi: `wpa_cli -i wlan0 ...` then `save_config` (see the main [README](../README.md#the-mental-model)) | — |

Our layers are used in place, so recipe and source edits need only `build`. `configure` is for changes in `config.env` / `config.local.env`, the SSH key, or the layer list.

---

## 6. Where everything ends up on disk

```
<repo>/yocto/layers/                (fetch: git submodules, at the recorded commits)
├── bitbake/                        build tool
├── openembedded-core/              core layer
├── meta-yocto/                     poky distro layer
├── meta-raspberrypi/               Pi BSP layer
├── meta-openembedded/              meta-oe, meta-python...
└── meta-ros/                       ROS layers

~/rpi5-os/
├── yocto/
│   └── build/
│       ├── conf/
│       │   ├── bblayers.conf       which layers            (configure)
│       │   ├── auto.conf           settings from config.env (configure, mode 600)
│       │   ├── local.conf          build settings, yours   (first configure, from the template)
│       │   └── mylab/              your key + Wi-Fi config (configure, mode 700)
│       └── tmp/                    everything `clean` deletes
│           ├── work/               per-recipe work dirs (mostly emptied by rm_work)
│           ├── deploy/ipk/         every built package
│           ├── deploy/images/raspberrypi5/
│           │   ├── mylab-image-raspberrypi5.rootfs.wic.xz    ← flash this
│           │   ├── mylab-image-raspberrypi5.rootfs.wic.bmap  (used by flash.sh)
│           │   ├── mylab-image-raspberrypi5.rootfs.manifest  installed packages
│           │   ├── Image, *.dtb                              kernel, device trees
│           │   └── bootfiles/                                config.txt, cmdline.txt
│           └── buildstats/         task timings
├── yocto-downloads/                source archives (kept by clean)
├── yocto-sstate/                   build cache     (kept by clean)
└── mylab-rpi5-yocto-wrynose.wic.xz copy made by export
```

The **manifest** shows what actually went into the image. Read it after a build to check that a package you expect is really there.
