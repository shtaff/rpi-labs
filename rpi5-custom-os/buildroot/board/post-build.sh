#!/bin/sh
# Runs after the rootfs is assembled, before it is packed into rootfs.ext4.
#   $1 = TARGET_DIR,  $2 = ALLOW_ROOT_PASSWORD_SSH (yes|no) from BR2_ROOTFS_POST_BUILD_SCRIPT_ARGS
set -eu
TARGET_DIR="$1"
ALLOW_PW="${2:-no}"

# sshd refuses keys if these permissions are too open.
chmod 0700 "$TARGET_DIR/root/.ssh"
chmod 0600 "$TARGET_DIR/root/.ssh/authorized_keys"

# Wi-Fi: the overlay may come from a Windows checkout that lost the exec bit,
# and the supplicant config holds the network's PSK.
chmod 0755 "$TARGET_DIR/etc/init.d/S45wifi"
chmod 0600 "$TARGET_DIR/etc/wpa_supplicant.conf"

# First-boot resize: same exec-bit caveat. The marker must not be in the image.
chmod 0755 "$TARGET_DIR/etc/init.d/S05rootfs-expand" "$TARGET_DIR/usr/sbin/rootfs-expand"
chmod 0755 "$TARGET_DIR/etc/init.d/S99boot-report"
rm -f "$TARGET_DIR/etc/rootfs-expanded"

# chronyd writes its drift file here but doesn't create the directory.
mkdir -p "$TARGET_DIR/var/lib/chrony"

CFG="$TARGET_DIR/etc/ssh/sshd_config"
set_opt() {  # set_opt Key Value  -> replaces "#Key ..." or "Key ..." or appends
    if grep -qE "^[#[:space:]]*$1[[:space:]]" "$CFG"; then
        sed -i -E "s|^[#[:space:]]*$1[[:space:]].*|$1 $2|" "$CFG"
    else
        echo "$1 $2" >> "$CFG"
    fi
}

set_opt PubkeyAuthentication yes
if [ "$ALLOW_PW" = "yes" ]; then
    set_opt PermitRootLogin yes
    set_opt PasswordAuthentication yes
else
    set_opt PermitRootLogin prohibit-password
    set_opt PasswordAuthentication no
fi
echo "post-build: sshd_config -> PermitRootLogin=$(sed -n 's/^PermitRootLogin //p' "$CFG")"
