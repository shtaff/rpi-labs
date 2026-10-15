#!/usr/bin/env bash
# Flash the built image to an SD card from WSL (via usbipd-win) or native Linux.
#
#   ./tools/flash.sh                      # the Yocto .wic.xz (uses bmaptool + .bmap if available)
#   ./tools/flash.sh yocto                # same
#   ./tools/flash.sh path/to/image.img    # any .img / .wic / .img.xz / .wic.xz
#   ./tools/flash.sh --inspect            # write nothing: show how far the Pi got booting this card
#
# Options:
#   --busid 2-3        USB bus id of the card reader (skip the picker)
#   --device /dev/sdX  target block device (skip auto-detection)
#   --keep-attached    leave the reader attached to WSL afterwards
#   --no-verify        skip read-back / partition checks
#   --dry-run          show what would happen, write nothing
#   --yes              don't ask for confirmation (careful!)
#
# Analogy: on Windows the card reader is plugged into the landlord's (Windows)
# wall socket. usbipd-win runs an extension cord into the tenant's (WSL) room:
# Windows lets go of the device and the Linux kernel sees a real /dev/sdX,
# exactly as if it were plugged into a Linux PC.

source "$(dirname "$0")/../common/lib.sh"

USBIPD="${USBIPD:-/mnt/c/Program Files/usbipd-win/usbipd.exe}"
POWERSHELL="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
MAX_SIZE_GB=256          # refuse bigger disks: an SD card is never a 2 TB drive

IMAGE_ARG="" BUSID="" DEVICE="" KEEP=0 VERIFY=1 DRY=0 YES=0 INSPECT=0
while (( $# )); do
    case "$1" in
        --inspect) INSPECT=1 ;;
        --busid)  BUSID="$2"; shift ;;
        --device) DEVICE="$2"; shift ;;
        --keep-attached) KEEP=1 ;;
        --no-verify) VERIFY=0 ;;
        --dry-run) DRY=1 ;;
        --yes) YES=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        -*) die "Unknown option $1" ;;
        *) IMAGE_ARG="$1" ;;
    esac
    shift
done

count_lines() { if [[ -z "$1" ]]; then echo 0; else wc -l <<<"$1"; fi; }

run() {  # run a command, or just print it in --dry-run
    if (( DRY )); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

# ---------------------------------------------------------------- image ----
newest() { ls -1t "$@" 2>/dev/null | head -1 || true; }

pick_image() {
    local yo; yo="$(newest "$WORK_DIR"/yocto/build/tmp/deploy/images/raspberrypi5/mylab-image-raspberrypi5*.wic.xz)"
    case "$IMAGE_ARG" in
        ""|yocto) IMAGE="$yo" ;;
        *)        IMAGE="$IMAGE_ARG" ;;
    esac
    [[ -n "$IMAGE" && -f "$IMAGE" ]] || die "No image found (${IMAGE_ARG:-auto}). Build first."
    IMAGE="$(readlink -f "$IMAGE")"         # Yocto deploy dir is full of symlinks

    # Size of the raw image = how many bytes land on the card.
    case "$IMAGE" in
        *.xz) RAW_SIZE="$(xz --robot --list "$IMAGE" | awk '$1=="totals"{print $5}')"
              CAT=(xz -dc "$IMAGE") ;;
        *)    RAW_SIZE="$(stat -c %s "$IMAGE")"
              CAT=(cat "$IMAGE") ;;
    esac

    # A .bmap lists which blocks actually contain data (plus their sha256).
    # bmaptool writes only those and verifies them: a 4 GB image with 400 MB
    # of data flashes ~10x faster than dd.
    BMAP=""
    local base="${IMAGE%.xz}"; base="${base%.img}"; base="${base%.wic}"
    for cand in "$base.wic.bmap" "$base.img.bmap" "${IMAGE%.xz}.bmap"; do
        [[ -f "$cand" ]] && { BMAP="$cand"; break; }
    done
    ok "Image: $IMAGE ($(numfmt --to=iec "$RAW_SIZE") raw${BMAP:+, bmap: $(basename "$BMAP")})"
}

# --------------------------------------------------------------- usbipd ----
usbipd_list() {  # prints: BUSID|VID:PID|DEVICE|STATE for connected devices
    "$USBIPD" list 2>/dev/null | tr -d '\r' | awk '
        /^Connected:/ {on=1; next}  /^Persisted:/ {on=0}
        on && $1 ~ /^[0-9]+-[0-9]+$/ {
            line=$0; state="Not shared"
            if (line ~ /Attached[[:space:]]*$/)        state="Attached"
            else if (line ~ /Shared( \(forced\))?[[:space:]]*$/ && line !~ /Not shared[[:space:]]*$/) state="Shared"
            dev=line; sub(/^[^ ]+[ ]+[^ ]+[ ]+/, "", dev)
            sub(/[ ]+(Not shared|Shared \(forced\)|Shared|Attached)[ ]*$/, "", dev)
            printf "%s|%s|%s|%s\n", $1, $2, dev, state
        }'
}

wsl_attach_reader() {
    [[ -x "$USBIPD" ]] || die "usbipd-win not found. In PowerShell: winget install usbipd
  (then reopen WSL). Or flash from Windows with Raspberry Pi Imager."

    local rows; rows="$(usbipd_list)"
    [[ -n "$rows" ]] || die "usbipd sees no USB devices."

    if [[ -z "$BUSID" ]]; then
        local readers
        readers="$(grep -iE 'card|reader|storage|mass|sd|mmc|flash' <<<"$rows" || true)"
        if [[ $(count_lines "$readers") -eq 1 ]]; then
            BUSID="${readers%%|*}"
            ok "Found card reader: $(cut -d'|' -f3 <<<"$readers") (busid $BUSID)"
        else
            echo "USB devices visible to Windows:"
            awk -F'|' '{printf "    %-6s %-10s %-45s %s\n", $1, $2, $3, $4}' <<<"$rows"
            echo "  (Built-in laptop SD slots are often PCIe, not USB — those can't be forwarded.)"
            read -rp "BUSID of the SD card reader: " BUSID
        fi
    fi
    local row; row="$(grep "^$BUSID|" <<<"$rows" || true)"
    [[ -n "$row" ]] || die "No USB device with busid $BUSID"
    local state="${row##*|}"

    if [[ "$state" == "Not shared" ]]; then
        log "Sharing $BUSID with WSL (one-time, needs admin — accept the UAC prompt)"
        run "$POWERSHELL" -NoProfile -Command \
            "Start-Process -FilePath '$(wslpath -w "$USBIPD")' -ArgumentList 'bind','--busid','$BUSID' -Verb RunAs -Wait"
        (( DRY )) || usbipd_list | grep -q "^$BUSID|.*|Shared$" || die "bind failed (UAC declined?)"
    fi

    if [[ "$state" != "Attached" ]]; then
        BEFORE="$(lsblk -dnro NAME)"
        log "Attaching $BUSID to WSL — Windows releases the reader now"
        run "$USBIPD" attach --wsl --busid "$BUSID"
        ATTACHED_BY_US=1
    else
        ok "Reader already attached to WSL"
    fi
}

wsl_detach_reader() {
    [[ "${ATTACHED_BY_US:-0}" == 1 && $KEEP == 0 ]] || return 0
    log "Detaching $BUSID — the reader goes back to Windows"
    run "$USBIPD" detach --busid "$BUSID" || warn "detach failed; run: usbipd detach --busid $BUSID"
}

# ---------------------------------------------------------- block device --
# Candidate = whole disk on USB (or removable), at most MAX_SIZE_GB.
candidates() {
    lsblk -dnbPo NAME,TYPE,TRAN,RM,SIZE,MODEL | while read -r line; do
        local NAME TYPE TRAN RM SIZE MODEL
        eval "$line"
        [[ "$TYPE" == disk ]] || continue
        [[ "$TRAN" == usb || "$RM" == 1 ]] || continue
        (( SIZE <= MAX_SIZE_GB * 1024**3 )) || continue
        echo "/dev/$NAME|$SIZE|${MODEL:-?}"
    done
}

find_device() {
    pick_device
    [[ -z "$DEVICE" || "$DEVICE" == /dev/* ]] || DEVICE="/dev/$DEVICE"   # accept "sdf" as well as "/dev/sdf"
}

pick_device() {
    if [[ -n "$DEVICE" ]]; then return; fi
    local list=""
    for _ in $(seq 1 20); do                   # the kernel needs a moment to enumerate
        list="$(candidates)"
        if [[ -n "${BEFORE:-}" ]]; then        # prefer the disk that just appeared
            local fresh; fresh="$(grep -vxFf <(sed 's#^#/dev/#' <<<"$BEFORE") <(cut -d'|' -f1 <<<"$list") || true)"
            [[ -n "$fresh" ]] && { list="$(grep "^$fresh|" <<<"$list")"; break; }
        fi
        [[ -n "$list" ]] && break
        (( DRY )) && break
        sleep 1
    done
    [[ -n "$list" ]] || die "No USB/removable disk appeared. Is a card in the reader? Check: lsblk; dmesg | tail"
    if [[ $(count_lines "$list") -eq 1 ]]; then
        DEVICE="${list%%|*}"
    else
        echo "Candidate disks:"
        local dev size model
        while IFS='|' read -r dev size model; do
            printf '    %-10s %8s  %s\n' "$dev" "$(numfmt --to=iec "$size")" "$model"
        done <<<"$list"
        read -rp "Target device (e.g. /dev/sdd): " DEVICE
    fi
}

check_device() {
    [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
    local type tran rm size model
    type="$(lsblk -dno TYPE "$DEVICE")"; tran="$(lsblk -dno TRAN "$DEVICE")"
    rm="$(lsblk -dno RM "$DEVICE" | tr -d ' ')"; size="$(lsblk -dbno SIZE "$DEVICE")"
    model="$(lsblk -dno MODEL "$DEVICE" | xargs)"
    [[ "$type" == disk ]] || die "$DEVICE is a '$type', not a disk — pass the whole card (e.g. /dev/sdd, not /dev/sdd1)"
    [[ "$tran" == usb || "$rm" == 1 ]] || die "$DEVICE is not USB/removable — refusing (could be a system disk)"
    (( size > 0 )) || die "$DEVICE reports 0 bytes: no card inserted?"
    (( size <= MAX_SIZE_GB * 1024**3 )) || die "$DEVICE is $(numfmt --to=iec "$size") — too big for an SD card, refusing"
    (( size >= RAW_SIZE )) || die "Card ($(numfmt --to=iec "$size")) smaller than image ($(numfmt --to=iec "$RAW_SIZE"))"
    if lsblk -nro MOUNTPOINT "$DEVICE" | grep -qxE '/|/boot|/home|\[SWAP\]'; then
        die "$DEVICE holds a system mount point — refusing"
    fi

    echo
    lsblk -o NAME,SIZE,TRAN,RM,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
    echo
    warn "EVERYTHING on $DEVICE ($model, $(numfmt --to=iec "$size")) will be erased."
    if (( ! YES && ! DRY )); then
        local answer
        read -rp "Type the device name ($(basename "$DEVICE")) to continue: " answer
        [[ "$answer" == "$(basename "$DEVICE")" ]] || die "Aborted"
    fi
}

# ----------------------------------------------------------------- write --
write_image() {
    log "Unmounting any partitions of $DEVICE"
    local mp
    while read -r mp; do
        [[ -n "$mp" ]] && run sudo umount "$mp"
    done < <(lsblk -nro MOUNTPOINT "$DEVICE" | grep -v '^$' || true)

    local t0=$SECONDS
    if [[ -n "$BMAP" ]] && command -v bmaptool >/dev/null; then
        log "Writing with bmaptool (only mapped blocks, checksums verified)"
        run sudo bmaptool copy --bmap "$BMAP" "$IMAGE" "$DEVICE"
        BMAP_VERIFIED=1
    else
        [[ -n "$BMAP" ]] && warn "Install bmap-tools for faster, verified writes: sudo apt install bmap-tools"
        log "Writing with dd (every byte, $(numfmt --to=iec "$RAW_SIZE"))"
        # oflag=direct: bypass the page cache so the progress is honest
        # conv=fsync:   don't return until the card has the data
        if (( DRY )); then
            printf '    [dry-run] %s | sudo dd of=%s bs=4M iflag=fullblock oflag=direct conv=fsync status=progress\n' "${CAT[*]}" "$DEVICE"
        else
            "${CAT[@]}" | sudo dd of="$DEVICE" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
        fi
    fi
    run sync
    (( DRY )) || ok "Written in $(( SECONDS - t0 )) s"
}

verify_card() {
    (( VERIFY && ! DRY )) || return 0

    if [[ "${BMAP_VERIFIED:-0}" != 1 ]]; then
        log "Reading back $(numfmt --to=iec "$RAW_SIZE") to compare with the image"
        # Drop cached pages so we read the card, not RAM.
        sudo blockdev --flushbufs "$DEVICE"
        if "${CAT[@]}" | sudo cmp -n "$RAW_SIZE" - "$DEVICE"; then
            ok "Card contents match the image byte for byte"
        else
            die "Read-back mismatch — bad card or reader. Try another card."
        fi
    fi

    # Re-read the partition table and peek inside, like the Pi will.
    sudo partprobe "$DEVICE" 2>/dev/null || sudo blockdev --rereadpt "$DEVICE" || true
    sleep 1
    echo; lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEVICE"; echo

    local p1 p2 mnt
    p1="$(lsblk -nro PATH "$DEVICE" | sed -n 2p)"; p2="$(lsblk -nro PATH "$DEVICE" | sed -n 3p)"
    mnt="$(mktemp -d)"
    if [[ -n "$p1" ]] && sudo mount -o ro "$p1" "$mnt" 2>/dev/null; then
        [[ -f "$mnt/config.txt" ]] && ok "boot: config.txt present" || warn "boot: no config.txt"
        compgen -G "$mnt/*2712*" >/dev/null && ok "boot: Pi 5 (bcm2712) kernel/DTB present" || warn "boot: no bcm2712 files"
        [[ -f "$mnt/overlays/bcm2712d0.dtbo" ]] && ok "boot: D0 overlay present (Rev 1.1 boards)" || warn "boot: no overlays/bcm2712d0.dtbo, newer Pi 5 boards (Rev 1.1, D0) will panic at boot"
        sudo umount "$mnt"
    else
        warn "Could not mount boot partition ($p1) for inspection"
    fi
    if [[ -n "$p2" ]] && sudo mount -o ro "$p2" "$mnt" 2>/dev/null; then
        local keyfile
        keyfile="$(sudo find "$mnt/root/.ssh" "$mnt/home/root/.ssh" -name authorized_keys 2>/dev/null | head -1 || true)"
        if [[ -n "$keyfile" ]] && sudo grep -qF "$(awk '{print $2}' "$SSH_PUBKEY")" "$keyfile"; then
            ok "rootfs: your SSH key is in ${keyfile#"$mnt"}"
        else
            warn "rootfs: your current key ($SSH_PUBKEY) is NOT in the image"
        fi
        [[ -n "$(sudo find "$mnt/usr/sbin" -name sshd -print -quit 2>/dev/null)" ]] && ok "rootfs: sshd present"
        if [[ -d "$mnt/opt/ros/$ROS2_DISTRO/lib/counter_demo" ]]; then
            ok "rootfs: ROS 2 $ROS2_DISTRO with counter_demo in /opt/ros/$ROS2_DISTRO"
        else
            warn "rootfs: no /opt/ros/$ROS2_DISTRO/lib/counter_demo (image built without meta-mylab-ros?)"
        fi
        local host
        host="$(sudo cat "$mnt/etc/hostname" 2>/dev/null || echo '?')"
        if [[ "$host" == "$RPI_HOSTNAME" ]]; then
            ok "rootfs: hostname $host"
        else
            warn "rootfs: hostname is '$host' but config says '$RPI_HOSTNAME' — image built with different settings (config.local.env missing on the build machine?)"
        fi
        # The file wpa_supplicant-nl80211@wlan0.service reads (installed by
        # wifi-config.bb). Not /etc/wpa_supplicant.conf: that's the package's
        # unused sample, with no network in it.
        local wpa="$mnt/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf" ssid
        if sudo test -f "$wpa"; then   # mode 600, root-owned
            # yocto.sh writes "# ssid: <name>" (+ hex ssid=), quick-build.sh writes ssid="<name>".
            ssid="$(sudo sed -n -e 's/^ *# ssid: //p' -e 's/^ *ssid="\(.*\)"$/\1/p' "$wpa" | head -1 || true)"
            if [[ -z "$ssid" ]]; then
                warn "rootfs: Wi-Fi config ${wpa#"$mnt"} has NO network${WIFI_SSID:+ (config says '$WIFI_SSID')}"
            elif [[ -n "$WIFI_SSID" && "$ssid" != "$WIFI_SSID" ]]; then
                warn "rootfs: Wi-Fi network is '$ssid' but config says '$WIFI_SSID'"
            else
                ok "rootfs: Wi-Fi config ${wpa#"$mnt"} (network: $ssid)"
            fi
        else
            warn "rootfs: no ${wpa#"$mnt"} (image built without wifi-config?)"
        fi
        sudo umount "$mnt"
    else
        warn "Could not mount rootfs partition ($p2) for inspection"
    fi
    rmdir "$mnt"
}

# --------------------------------------------------------------- inspect --
# Read-only: after the card has been in the Pi, show how far the Pi got.
# Each boot stage leaves a trace on the card:
#   ext4 mount count > 0     kernel booted, init remounted / read-write
#   partition 2 fills card   first-boot resize (rootfs-expand.service) ran
#   /etc/rootfs-expanded     ...and finished
#   /etc/ssh/ssh_host_*      sshd started (first boot generates the host keys)
inspect_card() {
    [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device (lsblk shows what's attached)"
    [[ "$(lsblk -dno TYPE "$DEVICE")" == disk ]] || die "$DEVICE is a partition — pass the whole card, e.g. /dev/sdf"
    sudo partprobe "$DEVICE" 2>/dev/null || sudo blockdev --rereadpt "$DEVICE" 2>/dev/null || true
    sleep 1
    echo; lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEVICE"; echo

    local p1 p2 mnt disk_b p2_b count state
    p1="$(lsblk -nro PATH "$DEVICE" | sed -n 2p)"; p2="$(lsblk -nro PATH "$DEVICE" | sed -n 3p)"
    [[ -n "$p2" ]] || die "No second partition on $DEVICE: is this a card flashed with our image?"

    count="$(sudo tune2fs -l "$p2" 2>/dev/null | sed -n 's/^Mount count: *//p')"
    state="$(sudo tune2fs -l "$p2" 2>/dev/null | sed -n 's/^Filesystem state: *//p')"
    if [[ "${count:-0}" -gt 0 ]]; then
        ok "Linux booted: root filesystem was mounted read-write $count time(s) (state: $state)"
    else
        warn "Root filesystem was NEVER mounted read-write: the Pi did not boot Linux from this card"
        warn "  -> bootloader / kernel stage. Check the Pi's LEDs and HDMI output (see README troubleshooting)."
    fi

    disk_b="$(lsblk -bdno SIZE "$DEVICE")"; p2_b="$(lsblk -bno SIZE "$p2")"
    if (( p2_b > disk_b * 8 / 10 )); then
        ok "First-boot resize ran: root partition is $(numfmt --to=iec "$p2_b") of $(numfmt --to=iec "$disk_b")"
    else
        warn "Root partition still $(numfmt --to=iec "$p2_b") of $(numfmt --to=iec "$disk_b"): first-boot resize did not run"
    fi

    mnt="$(mktemp -d)"
    # Plain ro mount: if the Pi lost power, the kernel replays the ext4 journal
    # first, exactly as the Pi would on its next boot.
    if sudo mount -o ro "$p2" "$mnt"; then
        [[ -e "$mnt/etc/rootfs-expanded" ]] && ok "/etc/rootfs-expanded exists: resize finished" \
            || warn "/etc/rootfs-expanded missing: resize never finished"
        if compgen -G "$mnt/etc/ssh/ssh_host_*_key" >/dev/null; then
            ok "SSH host keys exist: boot reached sshd (after network setup)"
        else
            warn "No SSH host keys: boot never reached sshd"
        fi
        [[ -f "$mnt/var/lib/systemd/timesync/clock" ]] && ok "timesyncd clock file exists: NTP synced at some point"
        sudo umount "$mnt"
    else
        warn "Could not mount $p2"
    fi

    if [[ -n "$p1" ]] && sudo mount -o ro "$p1" "$mnt"; then
        if [[ "${count:-0}" -eq 0 ]]; then
            # Linux never got going: show what the bootloader had to work with.
            log "Boot partition files:"; ls -la "$mnt" | sed 's/^/    /'
            log "config.txt:"; grep -v '^\s*#' "$mnt/config.txt" | grep . | sed 's/^/    /' || true
            log "cmdline.txt:"; sed 's/^/    /' "$mnt/cmdline.txt" || true
        fi
        sudo umount "$mnt"
    fi
    rmdir "$mnt"
}

# ------------------------------------------------------------------ main --
sanitize_path
if (( INSPECT )); then
    if is_wsl && [[ -z "$DEVICE" ]]; then
        wsl_attach_reader
        trap 'wsl_detach_reader' EXIT
    fi
    find_device
    inspect_card
    exit 0
fi
for t in lsblk sudo dd cmp xz numfmt partprobe; do
    command -v "$t" >/dev/null || warn "Missing '$t' (sudo apt install util-linux coreutils diffutils xz-utils parted)"
done

pick_image
if is_wsl && [[ -z "$DEVICE" ]]; then
    wsl_attach_reader
    trap 'wsl_detach_reader' EXIT
fi
find_device
check_device
write_image
verify_card
run sync

echo
ok "Done. ${ATTACHED_BY_US:+The reader is being handed back to Windows. }Move the card to the Pi 5,"
echo "      connect Ethernet (or rely on Wi-Fi), power on, then:  ./tools/verify-ssh.sh"
