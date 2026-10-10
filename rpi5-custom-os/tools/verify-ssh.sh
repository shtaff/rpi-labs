#!/usr/bin/env bash
# Prove the custom image works: find the Pi, log in over SSH with the baked-in
# key, and check that it's really our OS on a Pi 5.
#
#   ./tools/verify-ssh.sh                   # try <hostname>.local (mDNS), then scan the LAN
#   ./tools/verify-ssh.sh 192.168.1.50      # known IP (or a name)
#   ./tools/verify-ssh.sh --mdns            # only mDNS: <hostname>.local
#   ./tools/verify-ssh.sh --scan            # only scan the Windows host's LAN (/24)
#   ./tools/verify-ssh.sh --scan 10.0.0.0/24

source "$(dirname "$0")/../common/lib.sh"

KEY="${SSH_PUBKEY%.pub}"
KNOWN="$WORK_DIR/known_hosts"     # separate file: every rebuild = new host key
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN")

# Find the LAN prefix (first 3 octets). In WSL2's default NAT mode our own
# eth0 is a virtual 172.x network, so ask Windows for its real address.
lan_prefix() {
    local ip=""
    if is_wsl; then
        ip="$(powershell.exe -NoProfile -Command \
            "(Get-NetIPConfiguration | Where-Object {\$_.IPv4DefaultGateway -ne \$null} | Select-Object -First 1).IPv4Address.IPAddress" \
            2>/dev/null | tr -d '\r' || true)"
    fi
    [[ -n "$ip" ]] || ip="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
    echo "${ip%.*}"
}

# <hostname>.local -> IPv4 via mDNS (avahi on the Pi answers it). Prints nothing
# if unresolved. In WSL2's default NAT mode Linux can't see LAN multicast, so
# fall back to Windows' own resolver, which speaks mDNS.
resolve_mdns() {
    local name="$1" ip=""
    ip="$(timeout 5 getent ahostsv4 "$name" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    if [[ -z "$ip" ]] && is_wsl; then
        ip="$(timeout 10 powershell.exe -NoProfile -Command \
            "try { ([System.Net.Dns]::GetHostAddresses('$name') | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1).IPAddressToString } catch {}" \
            2>/dev/null | tr -d '\r' || true)"
    fi
    echo "$ip"
}

mdns_host() {
    local name="$RPI_HOSTNAME.local" ip
    log "Resolving $name (mDNS)…" >&2
    ip="$(resolve_mdns "$name")"
    if [[ -n "$ip" ]]; then
        ok "$name is $ip" >&2
        echo "$ip"
    else
        warn "$name did not resolve (Pi still booting, or a network that blocks multicast)" >&2
    fi
}

scan() {
    local prefix="${1:-}"; prefix="${prefix%/24}"; prefix="${prefix%.0}"
    [[ -n "$prefix" ]] || prefix="$(lan_prefix)"
    log "Scanning $prefix.1-254 for SSH (port 22)…" >&2
    local i
    for i in $(seq 1 254); do
        ( timeout 1 bash -c "exec 3<>/dev/tcp/$prefix.$i/22" 2>/dev/null && echo "$prefix.$i" ) &
    done | sort -t. -k4 -n
    wait
}

check_host() {
    local ip="$1" fails=0
    echo; log "Checking $ip"

    # 1. Port + banner: is an SSH daemon answering?
    local banner
    banner="$(timeout 3 bash -c "exec 3<>/dev/tcp/$ip/22; head -1 <&3" 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$banner" ]] && ok "Port 22 open, banner: $banner" || { warn "No SSH on $ip"; return 1; }

    # 2. Which auth methods does the server offer?
    local methods
    methods="$(ssh -o PreferredAuthentications=none -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN" root@"$ip" 2>&1 \
        | sed -n 's/.*Permission denied (\(.*\)).*/\1/p' || true)"
    [[ -n "$methods" ]] && ok "Offered auth methods: $methods"

    # 3. Key login + identify the system.
    local out
    if ! out="$(ssh "${SSH_OPTS[@]}" root@"$ip" '
            echo "host=$(hostname)"
            echo "arch=$(uname -m)"
            echo "kernel=$(uname -r)"
            echo "model=$(tr -d "\0" </proc/device-tree/model 2>/dev/null)"
            . /etc/os-release 2>/dev/null; echo "os=$PRETTY_NAME"
            echo "sshd=$(pidof sshd >/dev/null && echo running || echo stopped)"
            echo "ip=$(ip -4 -o addr show 2>/dev/null | awk "!/ lo /{print \$4}" | head -1)"
            echo "uptime=$(cut -d. -f1 /proc/uptime)s"
            echo "wlan=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo absent)"
            echo "wlan_ip=$(ip -4 -o addr show wlan0 2>/dev/null | awk "{print \$4}" | head -1)"
            echo "wlan_ssid=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n "s/^ssid=//p")"
            echo "epoch=$(date +%s)"
            echo "rootfs=$(df -h / | awk "NR == 2 { print \$2 }")"
            echo "disk=$(cat /sys/block/mmcblk0/size 2>/dev/null)"
            echo "mdns=$(pidof avahi-daemon >/dev/null && echo running || echo stopped)"
        ' 2>&1)"; then
        warn "Key login as root failed: $out"; return 1
    fi
    ok "Logged in as root with key $KEY"
    echo "$out" | sed 's/^/        /'

    local host arch model sshd
    host="$(sed -n 's/^host=//p'  <<<"$out")"
    arch="$(sed -n 's/^arch=//p'  <<<"$out")"
    model="$(sed -n 's/^model=//p' <<<"$out")"
    sshd="$(sed -n 's/^sshd=//p'  <<<"$out")"
    [[ "$host" == "$RPI_HOSTNAME" ]] && ok "Hostname is ours ($host)"  || { warn "Hostname '$host' != '$RPI_HOSTNAME'"; ((fails++)) || true; }
    [[ "$arch" == aarch64 ]]          && ok "64-bit ARM kernel"          || { warn "arch=$arch";  ((fails++)) || true; }
    [[ "$model" == *"Raspberry Pi 5"* ]] && ok "Board: $model"           || { warn "model=$model"; ((fails++)) || true; }
    [[ "$sshd" == running ]]          && ok "sshd running"               || { warn "sshd=$sshd";  ((fails++)) || true; }

    local wlan wlan_ip wlan_ssid
    wlan="$(sed -n 's/^wlan=//p' <<<"$out")"
    wlan_ip="$(sed -n 's/^wlan_ip=//p' <<<"$out")"
    wlan_ssid="$(sed -n 's/^wlan_ssid=//p' <<<"$out")"
    if [[ -n "$WIFI_SSID" ]]; then
        if [[ -n "$wlan_ip" ]]; then
            ok "Wi-Fi joined '$wlan_ssid', wlan0 $wlan_ip"
        else
            warn "Wi-Fi not connected (wlan0 $wlan${wlan_ssid:+, ssid $wlan_ssid}). On the Pi: wpa_cli -i wlan0 status; dmesg | grep brcmfmac"
            ((fails++)) || true
        fi
    elif [[ "$wlan" != absent ]]; then
        ok "Wi-Fi interface wlan0 present (no network configured)"
    else
        warn "No wlan0 interface (Wi-Fi driver/firmware not loaded?)"
    fi

    # Clock: NTP (chrony / systemd-timesyncd) should have fixed the battery-less
    # RTC within seconds of the network coming up.
    local epoch skew
    epoch="$(sed -n 's/^epoch=//p' <<<"$out")"
    skew=$(( ${epoch:-0} - $(date +%s) )); skew=${skew#-}
    if (( skew <= 120 )); then
        ok "Clock in sync (off by ${skew}s)"
    else
        warn "Clock is off by ${skew}s: NTP not working? Buildroot: /etc/init.d/S49chronyd restart; chronyc sources. Yocto: timedatectl timesync-status"
        ((fails++)) || true
    fi

    # First-boot resize: / should be close to the card size, not the image size.
    local rootfs disk
    rootfs="$(sed -n 's/^rootfs=//p' <<<"$out")"
    disk="$(sed -n 's/^disk=//p' <<<"$out")"
    if [[ -n "$disk" ]]; then
        ok "Root filesystem: $rootfs on a $(numfmt --to=iec $(( disk * 512 ))) card"
    fi

    [[ "$(sed -n 's/^mdns=//p' <<<"$out")" == running ]] \
        && ok "mDNS: reachable as $RPI_HOSTNAME.local" \
        || { warn "avahi-daemon not running"; ((fails++)) || true; }

    echo
    if (( fails == 0 )); then
        printf '%sPASS%s  Custom OS with SSH verified on %s\n' "$C_GRN" "$C_OFF" "$ip"
        echo "      Connect any time:  ssh -i $KEY root@$ip"
        return 0
    fi
    printf '%sPARTIAL%s  %d check(s) failed on %s\n' "$C_YLW" "$C_OFF" "$fails" "$ip"
    return 1
}

[[ -f "$KEY" ]] || die "Private key $KEY not found (set SSH_PUBKEY in config.env)"
mkdir -p "$WORK_DIR"

scan_and_check() {
    mapfile -t hosts < <(scan "${1:-}")
    (( ${#hosts[@]} )) || die "No SSH hosts found. Is the Pi powered and on Ethernet or Wi-Fi? Try the IP from your router's DHCP list."
    ok "SSH answering on: ${hosts[*]}"
    for h in "${hosts[@]}"; do
        # Cheap filter: only try full checks where our key gets in.
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=3 root@"$h" true 2>/dev/null || continue
        check_host "$h" && exit 0
    done
    die "None of those hosts accepted our key as root."
}

case "${1:-}" in
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    "")
        ip="$(mdns_host)"
        if [[ -n "$ip" ]]; then check_host "$ip" || exit 1; else scan_and_check; fi ;;
    --mdns)
        ip="$(mdns_host)"
        [[ -n "$ip" ]] || die "Could not resolve $RPI_HOSTNAME.local"
        check_host "$ip" || exit 1 ;;
    --scan) scan_and_check "${2:-}" ;;
    *)  check_host "$1" || exit 1 ;;
esac
