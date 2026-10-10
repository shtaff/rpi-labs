#!/usr/bin/env bash
# Yocto (wrynose / 6.0) flow for Raspberry Pi 5 with OpenSSH and Wi-Fi.
#
#   ./yocto/yocto.sh all          # fetch -> configure -> build -> export
#   ./yocto/yocto.sh <step>       # deps | fetch | lock | update | configure | build | shell | export | clean
#
# fetch checks out the exact layer commits in yocto/layers.lock (reproducible);
# update moves to the branch tips and rewrites the lock file.
#
# Analogy vs Buildroot: Buildroot is one recipe card cooked in one pot.
# Yocto is a restaurant kitchen: many layers of recipes (oe-core, poky,
# meta-raspberrypi, ours), a scheduler (bitbake) running every task as a job,
# and a pantry of pre-cooked results (sstate-cache) so rebuilds are fast.
# More setup, far more control — and far more RAM and disk.

source "$(dirname "$0")/../common/lib.sh"

Y="$WORK_DIR/yocto"
BUILD="$Y/build"
LAYER_SRC="$REPO_ROOT/yocto/meta-mylab"
MACHINE="raspberrypi5"
IMAGE="mylab-image"

step_deps() {
    log "Installing Yocto host packages (sudo)"
    sudo apt-get update
    sudo apt-get install -y \
        build-essential chrpath cpio debianutils diffstat file gawk gcc git \
        iputils-ping libacl1 lz4 locales python3 python3-git python3-jinja2 \
        python3-pexpect python3-pip python3-subunit socat texinfo unzip wget \
        xz-utils zstd openssl openssh-client bmap-tools parted
    sudo locale-gen en_US.UTF-8
    ok "Host dependencies installed"
}

yocto_preflight() {
    preflight 120 16
    [[ $EUID -ne 0 ]] || die "Do not build Yocto as root (bitbake refuses)."
    # Ubuntu 24.04+ blocks unprivileged user namespaces, which bitbake uses to
    # cut tasks off from the network. Usually off in WSL, but check anyway.
    if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == 1 ]]; then
        warn "apparmor_restrict_unprivileged_userns=1 — bitbake tasks may fail. Fix:"
        warn "  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
    fi
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
}

# Every layer we build from:  name  url  mirror  branch
# bitbake must sit next to openembedded-core: oe-init-build-env finds it there.
LAYERS=(
    "bitbake           https://git.openembedded.org/bitbake           https://github.com/openembedded/bitbake           $BITBAKE_BRANCH"
    "openembedded-core https://git.openembedded.org/openembedded-core https://github.com/openembedded/openembedded-core $YOCTO_RELEASE"
    "meta-yocto        https://git.yoctoproject.org/meta-yocto        https://github.com/yoctoproject/meta-yocto        $YOCTO_RELEASE"
    "meta-raspberrypi  https://git.yoctoproject.org/meta-raspberrypi  https://github.com/agherzan/meta-raspberrypi      $YOCTO_RELEASE"
)

# Exact commit per layer, like package-lock.json: same lock file = same sources
# = same image, today or in a year. `update` moves to the branch tips and
# rewrites it; commit the file to make that the new baseline.
LOCK_FILE="$REPO_ROOT/yocto/layers.lock"
locked_rev() {  # locked_rev <name>  -> commit hash, or nothing
    [[ "${YOCTO_UNLOCKED:-0}" == 1 || ! -f "$LOCK_FILE" ]] && return 0
    awk -v n="$1" '$1 == n { print $2 }' "$LOCK_FILE"
}

clone() {  # clone <name> <url> <mirror-url> <branch>
    local name="$1" url="$2" mirror="$3" br="$4"
    local dir="$Y/$name" rev src deepen=()
    rev="$(locked_rev "$name")"
    if [[ -n "$rev" && "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" == "$rev" ]]; then
        ok "$name at ${rev:0:12} (locked)"
        return 0
    fi
    [[ -d "$dir/.git" ]] || git init -q "$dir"
    if [[ "$(git -C "$dir" rev-parse --is-shallow-repository)" == true ]]; then
        deepen=(--unshallow)
    fi

    for src in "$url" "$mirror"; do
        if [[ -z "$rev" ]]; then
            if git -C "$dir" fetch -q --depth 1 "$src" "$br"; then
                git -C "$dir" checkout -q --detach FETCH_HEAD
                ok "$name at ${br} tip $(git -C "$dir" rev-parse --short=12 HEAD) (unlocked)"
                return 0
            fi
        # One commit by hash (most servers allow it), else the whole branch.
        elif git -C "$dir" fetch -q --depth 1 "$src" "$rev" 2>/dev/null \
             || git -C "$dir" fetch -q "${deepen[@]}" "$src" "$br"; then
            if git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
                git -C "$dir" checkout -q --detach "$rev"
                ok "$name at ${rev:0:12} (locked)"
                return 0
            fi
            warn "$name: commit $rev is not on $br at $src"
        fi
        warn "$name: fetch from $src failed, trying the next source"
    done
    die "Could not fetch $name ${rev:-$br}"
}

step_fetch() {
    yocto_preflight
    mkdir -p "$Y"
    log "Fetching layers for Yocto $YOCTO_RELEASE"
    [[ -f "$LOCK_FILE" || "${YOCTO_UNLOCKED:-0}" == 1 ]] \
        || warn "No $LOCK_FILE: using branch tips. Run '$0 lock' to pin them."
    local l name url mirror br
    for l in "${LAYERS[@]}"; do
        read -r name url mirror br <<<"$l"
        clone "$name" "$url" "$mirror" "$br"
    done
    [[ -f "$Y/meta-raspberrypi/conf/machine/$MACHINE.conf" ]] || die "No $MACHINE machine in meta-raspberrypi"
}

# Write the commits currently checked out into layers.lock.
step_lock() {
    local l name url mirror br
    {
        echo "# Exact layer commits for yocto.sh fetch. Regenerate with: ./yocto/yocto.sh update"
        echo "# name             commit                                    branch"
        for l in "${LAYERS[@]}"; do
            read -r name url mirror br <<<"$l"
            [[ -d "$Y/$name/.git" ]] || die "$name not fetched yet"
            printf '%-18s %s  %s\n' "$name" "$(git -C "$Y/$name" rev-parse HEAD)" "$br"
        done
    } > "$LOCK_FILE"
    ok "Wrote $LOCK_FILE — commit it so every build uses these exact sources"
    sed -n '3,$p' "$LOCK_FILE"
}

# Move every layer to its branch tip and re-lock (the deliberate "upgrade").
step_update() {
    YOCTO_UNLOCKED=1 step_fetch
    step_lock
    if git -C "$REPO_ROOT" diff --quiet -- "$LOCK_FILE" 2>/dev/null; then
        ok "Already at the branch tips"
    else
        git -C "$REPO_ROOT" --no-pager diff --stat -- "$LOCK_FILE" 2>/dev/null || true
        log "Rebuild and test, then commit yocto/layers.lock"
    fi
}

step_configure() {
    yocto_preflight
    [[ -d "$Y/openembedded-core" ]] || step_fetch
    ensure_ssh_key
    make_root_hash

    log "Installing meta-mylab layer (with your public key)"
    rm -rf "$Y/meta-mylab"
    cp -a "$LAYER_SRC" "$Y/meta-mylab"
    install -d "$Y/meta-mylab/recipes-mylab/ssh-root-key/files"
    install -m 0644 "$SSH_PUBKEY" "$Y/meta-mylab/recipes-mylab/ssh-root-key/files/authorized_keys"
    make_wifi_conf "$Y/meta-mylab/recipes-mylab/wifi-config/files/wpa_supplicant-nl80211-wlan0.conf"
    install -m 0755 "$REPO_ROOT/common/target/rootfs-expand" "$Y/meta-mylab/recipes-mylab/rootfs-expand/files/"

    mkdir -p "$BUILD/conf"
    log "Writing $BUILD/conf/bblayers.conf"
    cat > "$BUILD/conf/bblayers.conf" <<EOF
# Generated by yocto.sh
POKY_BBLAYERS_CONF_VERSION = "2"
LCONF_VERSION = "7"
BBPATH = "\${TOPDIR}"
BBFILES ?= ""
BBLAYERS ?= " \\
  $Y/openembedded-core/meta \\
  $Y/meta-yocto/meta-poky \\
  $Y/meta-raspberrypi \\
  $Y/meta-mylab \\
  "
EOF

    # Bitbake expands \${...}; a bare '\$' in the hash must be escaped as '\\\$'.
    local hash_bb="${ROOT_HASH//\$/\\\$}"
    log "Writing $BUILD/conf/local.conf"
    cat > "$BUILD/conf/local.conf" <<EOF
# Generated by yocto.sh — re-run 'configure' instead of hand-editing.
CONF_VERSION = "2"

MACHINE = "$MACHINE"
DISTRO = "poky"
INIT_MANAGER = "systemd"
# poky already has wifi; stated explicitly because meta-mylab's wifi-config needs it.
DISTRO_FEATURES:append = " wifi"
PACKAGE_CLASSES = "package_ipk"

# Shared caches: survive 'clean', reused by every future build.
DL_DIR = "$WORK_DIR/yocto-downloads"
SSTATE_DIR = "$WORK_DIR/yocto-sstate"

BB_NUMBER_THREADS = "$JOBS"
PARALLEL_MAKE = "-j $JOBS"
# Delete each recipe's work dir once it's done: saves tens of GB on WSL.
INHERIT += "rm_work"

# Raspberry Pi specifics (meta-raspberrypi)
ENABLE_UART = "1"
# Pi 5 recommends Wi-Fi/BT firmware that carries this licence flag.
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"
# .wic.xz opens directly in Raspberry Pi Imager; .bmap is for bmaptool.
IMAGE_FSTYPES = "wic.xz wic.bmap"

# MyLab settings consumed by meta-mylab/recipes-core/images/$IMAGE.bb
hostname:pn-base-files = "$RPI_HOSTNAME"
MYLAB_ROOT_HASH = "$hash_bb"
MYLAB_ALLOW_ROOT_PASSWORD_SSH = "$ALLOW_ROOT_PASSWORD_SSH"

USER_CLASSES ?= "buildstats"
PATCHRESOLVE = "noop"
EOF
    chmod 600 "$BUILD/conf/local.conf"

    log "Checking layer setup"
    with_env bitbake-layers show-layers
    ok "Configured: MACHINE=$MACHINE, image=$IMAGE, hostname=$RPI_HOSTNAME"
}

# Run a command inside the bitbake environment.
with_env() {
    (
        trap - ERR; set +eu     # the OE env script isn't written for strict mode
        cd "$Y/openembedded-core" || exit 1
        # shellcheck disable=SC1091
        source ./oe-init-build-env "$BUILD" >/dev/null || exit 1
        set -e
        "$@"
    )
}

step_build() {
    yocto_preflight
    [[ -f "$BUILD/conf/local.conf" ]] || step_configure
    log "Building $IMAGE for $MACHINE ($JOBS threads). First build: 2-6 h, ~100 GB."
    local t0=$SECONDS
    with_env bitbake "$IMAGE"
    local img
    img="$(ls -1 "$BUILD/tmp/deploy/images/$MACHINE/$IMAGE-$MACHINE"*.wic.xz 2>/dev/null | head -1 || true)"
    [[ -n "$img" ]] || die "No .wic.xz found in $BUILD/tmp/deploy/images/$MACHINE"
    ok "Built in $(( (SECONDS - t0) / 60 )) min: $img"

    # Sanity: what landed in the rootfs?
    local manifest
    manifest="$(ls -1 "$BUILD/tmp/deploy/images/$MACHINE/$IMAGE-$MACHINE"*.manifest 2>/dev/null | head -1 || true)"
    [[ -n "$manifest" ]] || die "No image manifest found"
    grep -q '^openssh-sshd ' "$manifest"  && ok "openssh-sshd in image"  || die "openssh-sshd missing"
    grep -q '^ssh-root-key ' "$manifest"  && ok "ssh-root-key in image"  || die "ssh-root-key missing"
    grep -q '^wpa-supplicant ' "$manifest" && ok "wpa-supplicant in image" || die "wpa-supplicant missing"
    grep -q '^wifi-config ' "$manifest"   && ok "wifi-config in image"   || die "wifi-config missing"
    grep -q '^linux-firmware-rpidistro-bcm43455 ' "$manifest" \
        && ok "CYW43455 Wi-Fi firmware in image" || die "linux-firmware-rpidistro-bcm43455 missing"
    local pkg
    for pkg in rootfs-expand avahi-daemon; do
        grep -q "^$pkg " "$manifest" || die "$pkg missing from the image"
    done
    ok "rootfs-expand and avahi-daemon in image (NTP: systemd-timesyncd)"
}

step_shell() {
    log "Opening a shell with bitbake on PATH (exit to leave)"
    with_env bash -i
}

step_export() {
    local img
    img="$(ls -1 "$BUILD/tmp/deploy/images/$MACHINE/$IMAGE-$MACHINE"*.wic.xz 2>/dev/null | head -1 || true)"
    [[ -n "$img" ]] || die "Build first"
    local named="$WORK_DIR/${RPI_HOSTNAME}-yocto-${YOCTO_RELEASE}.wic.xz"
    cp -fL "$img" "$named"     # -L: deploy dir uses symlinks
    export_to_windows "$named"
    cat <<EOF

Next:
  1. Flash from WSL:     ./tools/flash.sh yocto      (bmaptool + .bmap: fast, verified)
     (or from Windows: Raspberry Pi Imager -> "Use custom" -> the .wic.xz)
  2. Ethernet (or Wi-Fi: ${WIFI_SSID:-not configured}) + power on, wait ~30 s (first boot generates SSH host keys).
  3. ./tools/verify-ssh.sh               (finds $RPI_HOSTNAME.local, else scans the LAN)
EOF
}

step_clean() {
    log "Removing $BUILD/tmp (downloads and sstate kept, next build is fast)"
    rm -rf "$BUILD/tmp"
}

case "${1:-all}" in
    deps)      step_deps ;;
    fetch)     step_fetch ;;
    lock)      step_lock ;;
    update)    step_update ;;
    configure) step_configure ;;
    build)     step_build ;;
    shell)     step_shell ;;
    export)    step_export ;;
    clean)     step_clean ;;
    all)       step_fetch; step_configure; step_build; step_export ;;
    *) die "Unknown step '$1'. Use: deps fetch lock update configure build shell export clean all" ;;
esac
