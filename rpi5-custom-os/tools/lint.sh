#!/usr/bin/env bash
# Static checks that need no build (a few seconds; CI runs this on every push):
#   - syntax check and shellcheck on every shell script, host and target side
#   - LF line endings, and the exec bit recorded in git
#   - known-answer test for the Wi-Fi PSK derivation (IEEE 802.11i test vector)
#   - every upstream layer is a git submodule listed in .gitmodules
#
#   ./tools/lint.sh

source "$(dirname "$0")/../common/lib.sh"
cd "$REPO_ROOT" || exit 1

fails=0
fail() { warn "$*"; fails=$((fails + 1)); }

# Every file with a sh/bash shebang, plus the sourced (shebang-less) lib.
mapfile -t scripts < <(
    git ls-files -co --exclude-standard | while read -r f; do
        [[ -f "$f" ]] && head -1 "$f" | grep -qE '^#!.*[/ ](ba)?sh' && echo "$f"
    done
)
scripts+=(common/lib.sh)

log "Syntax (${#scripts[@]} scripts)"
for f in "${scripts[@]}"; do
    if head -1 "$f" | grep -q bash || [[ "$f" == common/lib.sh ]]; then
        bash -n "$f" || fail "$f: bash syntax error"
    else
        sh -n "$f" || fail "$f: sh syntax error"
    fi
done

log "shellcheck"
if command -v shellcheck >/dev/null; then
    # -x: follow `source` lines into common/lib.sh and config.env.
    shellcheck -x -S warning "${scripts[@]}" || fail "shellcheck found problems"
else
    fail "shellcheck not installed (sudo apt install shellcheck)"
fi

log "Line endings"
while read -r f; do
    [[ -f "$f" ]] && grep -q $'\r' "$f" && fail "$f has CRLF line endings (see .gitattributes)"
done < <(git ls-files -co --exclude-standard)

log "Exec bits recorded in git"
for f in "${scripts[@]}"; do
    [[ "$f" == common/lib.sh ]] && continue            # sourced, not run
    mode="$(git ls-files -s -- "$f" | cut -d' ' -f1)"
    if [[ -z "$mode" ]]; then
        warn "$f is not in git yet (git add --chmod=+x $f)"
    elif [[ "$mode" != 100755 ]]; then
        fail "$f is mode $mode in git, not executable: git update-index --chmod=+x $f"
    fi
done

log "Wi-Fi PSK derivation"
tmp="$(mktemp -d)"
(
    # shellcheck disable=SC2034  # read by make_wifi_conf
    WIFI_SSID=IEEE WIFI_PSK=password WIFI_COUNTRY=us
    make_wifi_conf "$tmp/wpa.conf" >/dev/null
)
grep -qx '    psk=f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e' "$tmp/wpa.conf" \
    || fail "make_wifi_conf: wrong PSK for the IEEE test vector"
grep -qx '    ssid=49454545' "$tmp/wpa.conf" || fail "make_wifi_conf: wrong hex SSID"
grep -qx 'country=US' "$tmp/wpa.conf"       || fail "make_wifi_conf: country not upper-cased"
rm -rf "$tmp"

log "Layer submodules"
gitmodules="$(git rev-parse --show-toplevel)/.gitmodules"
for name in bitbake openembedded-core meta-yocto meta-raspberrypi meta-openembedded meta-ros; do
    path="yocto/layers/$name"
    [[ "$(git ls-files -s -- "$path" | cut -d' ' -f1)" == 160000 ]] \
        || { fail "$path is not a git submodule"; continue; }
    full="$(git ls-files --full-name -- "$path")"
    git config -f "$gitmodules" --get-regexp '^submodule\..*\.path$' | grep -qx "submodule\..*\.path $full" \
        || fail "$path has no entry in .gitmodules"
done

echo
(( fails == 0 )) || die "$fails check(s) failed"
ok "All checks passed"
