# shellcheck shell=bash
# Shared helpers. Sourced by yocto/yocto.sh and the tools.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_ROOT/config.env"
# Personal overrides and secrets (Wi-Fi name/passphrase...). Git-ignored.
if [[ -f "$REPO_ROOT/config.local.env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/config.local.env"
fi

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_OFF=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

trap 'die "command failed (line $LINENO): $BASH_COMMAND"' ERR

is_wsl() { grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; }

# WSL appends the Windows PATH ("/mnt/c/Program Files/...") which contains
# spaces and Windows binaries. The build can pick up the wrong tools from
# there, so drop every /mnt/* entry.
sanitize_path() {
    local IFS=':' p out=()
    for p in $PATH; do
        [[ -z "$p" || "$p" == /mnt/* || "$p" == *" "* ]] && continue
        out+=("$p")
    done
    PATH="$(IFS=':'; echo "${out[*]}")"
    export PATH
}

# Fail early on the classic WSL mistakes.
preflight() {
    local need_gb="$1"   # free disk needed, GB
    local need_ram_gb="$2"

    if is_wsl; then
        ok "Running inside WSL"
        grep -q 'WSL2\|microsoft-standard' /proc/sys/kernel/osrelease \
            || warn "This looks like WSL1. Use WSL2: 'wsl --set-version <distro> 2'"
    else
        warn "Not WSL — fine, the scripts work on any Ubuntu/Debian host."
    fi

    mkdir -p "$WORK_DIR"
    local real; real="$(readlink -f "$WORK_DIR")"
    [[ "$real" == /mnt/* ]] && die "WORK_DIR=$real is on the Windows drive. \
Builds there are 10x slower and break on case-insensitive paths. Use something under \$HOME."

    local free_gb; free_gb=$(df -BG --output=avail "$real" | tail -1 | tr -dc '0-9')
    (( free_gb >= need_gb )) || die "Only ${free_gb} GB free in $real, need ~${need_gb} GB."
    ok "Disk: ${free_gb} GB free (need ~${need_gb} GB)"

    local ram_gb; ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    local swap_gb; swap_gb=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    if (( ram_gb + swap_gb < need_ram_gb )); then
        warn "RAM ${ram_gb} GB + swap ${swap_gb} GB is below the ~${need_ram_gb} GB recommended."
        warn "Raise it in %UserProfile%\\.wslconfig (see README), then 'wsl --shutdown'."
    else
        ok "Memory: ${ram_gb} GB RAM + ${swap_gb} GB swap"
    fi
    sanitize_path
}

# Make sure there is an SSH key to bake into the image.
ensure_ssh_key() {
    if [[ ! -f "$SSH_PUBKEY" ]]; then
        local priv="${SSH_PUBKEY%.pub}"
        log "No key at $SSH_PUBKEY — generating an ed25519 key pair"
        mkdir -p "$(dirname "$priv")"; chmod 700 "$(dirname "$priv")"
        ssh-keygen -t ed25519 -N "" -C "rpi5-lab@$(hostname)" -f "$priv"
    fi
    ok "SSH public key: $SSH_PUBKEY"
}

# Ask for the root password once and turn it into a SHA-512 crypt hash.
# Result in the global ROOT_HASH.
make_root_hash() {
    if [[ -z "$ROOT_PASSWORD" ]]; then
        local p1 p2
        read -rsp "Root password for the Pi: " p1; echo
        read -rsp "Repeat: " p2; echo
        [[ "$p1" == "$p2" ]] || die "Passwords do not match"
        [[ -n "$p1" ]] || die "Empty password not allowed"
        ROOT_PASSWORD="$p1"
    fi
    # shellcheck disable=SC2034  # used by yocto.sh
    ROOT_HASH="$(openssl passwd -6 -stdin <<<"$ROOT_PASSWORD")"
}

# Write a wpa_supplicant config for wlan0 to $1 (mode 600).
# Yocto installs it as /etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf.
#
# The SSID is written hex-encoded, so quotes, spaces and non-ASCII characters
# need no escaping. The passphrase is turned into the 256-bit WPA PSK
# (PBKDF2-SHA1(passphrase, ssid, 4096), what `wpa_passphrase` computes), so the
# plain text never lands in the image. Note the PSK still grants access to that
# network, so treat the image like a secret.
make_wifi_conf() {
    local conf="$1" ssid_hex psk_hex=""
    if [[ -n "$WIFI_SSID" ]]; then
        if [[ -z "$WIFI_PSK" && -t 0 ]]; then
            read -rsp "Wi-Fi passphrase for '$WIFI_SSID' (empty = open network): " WIFI_PSK; echo
        fi
        if [[ -n "$WIFI_PSK" ]]; then
            (( ${#WIFI_PSK} >= 8 && ${#WIFI_PSK} <= 63 )) \
                || die "WIFI_PSK must be 8-63 characters (got ${#WIFI_PSK})"
            # Passed via the environment, not argv, so it doesn't show up in `ps`.
            psk_hex="$(WIFI_SSID="$WIFI_SSID" WIFI_PSK="$WIFI_PSK" python3 -c '
import hashlib, os
e = lambda k: os.fsencode(os.environ[k])
print(hashlib.pbkdf2_hmac("sha1", e("WIFI_PSK"), e("WIFI_SSID"), 4096, 32).hex())')"
        fi
        ssid_hex="$(printf '%s' "$WIFI_SSID" | od -An -tx1 -v | tr -d ' \n')"
    fi
    [[ -n "$WIFI_COUNTRY" ]] \
        || warn "WIFI_COUNTRY not set: Wi-Fi will use the world regulatory domain (limited 5 GHz)."

    install -d "$(dirname "$conf")"
    (
        umask 077
        {
            echo "# Generated by rpi5-custom-os from config.env."
            echo "# Change networks on the Pi with wpa_cli (saved back here thanks to update_config)."
            echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=0"
            echo "update_config=1"
            [[ -z "$WIFI_COUNTRY" ]] || echo "country=${WIFI_COUNTRY^^}"
            if [[ -n "$WIFI_SSID" ]]; then
                echo
                echo "network={"
                echo "    # ssid: $WIFI_SSID"
                echo "    ssid=$ssid_hex"
                echo "    scan_ssid=1"          # also finds hidden networks
                if [[ -n "$psk_hex" ]]; then
                    echo "    key_mgmt=WPA-PSK WPA-PSK-SHA256"
                    echo "    psk=$psk_hex"
                else
                    echo "    key_mgmt=NONE"
                fi
                echo "}"
            fi
        } > "$conf"
    )
    chmod 600 "$conf"
    if [[ -n "$WIFI_SSID" ]]; then
        local sec="open"; [[ -z "$psk_hex" ]] || sec="WPA2-PSK"
        ok "Wi-Fi: will join '$WIFI_SSID' ($sec${WIFI_COUNTRY:+, country ${WIFI_COUNTRY^^}})"
    else
        warn "WIFI_SSID empty: Wi-Fi drivers installed but no network configured (Ethernet only)."
    fi
}

# Copy a finished image to the Windows side so Raspberry Pi Imager / Etcher
# can flash it. Prints the Windows path.
export_to_windows() {
    local img="$1"
    is_wsl || { log "Image: $img"; return 0; }
    local dest="$WIN_EXPORT_DIR"
    if [[ -z "$dest" ]]; then
        local winuser
        winuser="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' || true)"
        [[ -n "$winuser" && -d "/mnt/c/Users/$winuser" ]] \
            || { warn "Could not detect Windows user; set WIN_EXPORT_DIR"; return 0; }
        dest="/mnt/c/Users/$winuser/Downloads/rpi5-images"
    fi
    mkdir -p "$dest"
    cp -f "$img" "$dest/"
    ok "Copied to Windows: $(wslpath -w "$dest/$(basename "$img")" 2>/dev/null || echo "$dest")"
}
