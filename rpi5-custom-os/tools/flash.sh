#!/usr/bin/env bash
# Flash the built image to an SD card from WSL (via usbipd-win) or native Linux.
#
#   ./tools/flash.sh                      # newest image (Buildroot or Yocto), pick reader interactively
#   ./tools/flash.sh buildroot            # Buildroot sdcard.img
#   ./tools/flash.sh yocto                # Yocto .wic.xz (uses bmaptool + .bmap if available)
#   ./tools/flash.sh path/to/image.img    # any .img / .wic / .img.xz / .wic.xz
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

IMAGE_ARG="" BUSID="" DEVICE="" KEEP=0 VERIFY=1 DRY=0 YES=0
while (( $# )); do
    case "$1" in
        --busid)  BUSID="$2"; shift ;;
        --device) DEVICE="$2"; shift ;;
        --keep-attached) KEEP=1 ;;
        --no-verify) VERIFY=0 ;;
        --dry-run) DRY=1 ;;
        --yes) YES=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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
    local br="$WORK_DIR/br-output/images/sdcard.img"
    local yo; yo="$(newest "$WORK_DIR"/yocto/build/tmp/deploy/images/raspberrypi5/mylab-image-raspberrypi5*.wic.xz)"
    case "$IMAGE_ARG" in
        buildroot) IMAGE="$br" ;;
        yocto)     IMAGE="$yo" ;;
        "")        IMAGE="$(newest "$br" "$yo")" ;;
        *)         IMAGE="$IMAGE_ARG" ;;
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
        ok "rootfs: hostname $(sudo cat "$mnt/etc/hostname" 2>/dev/null || echo '?')"
        local wpa
        wpa="$(sudo find "$mnt/etc/wpa_supplicant.conf" "$mnt/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf" 2>/dev/null | head -1 || true)"
        if [[ -n "$wpa" ]]; then
            ok "rootfs: Wi-Fi config ${wpa#"$mnt"} (network: $(sudo sed -n 's/^ *# ssid: //p' "$wpa" | head -1 | grep . || echo none))"
        else
            warn "rootfs: no wpa_supplicant config found"
        fi
        sudo umount "$mnt"
    else
        warn "Could not mount rootfs partition ($p2) for inspection"
    fi
    rmdir "$mnt"
}

# ------------------------------------------------------------------ main --
sanitize_path
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
