SUMMARY = "MyLab Raspberry Pi 5 image: minimal Linux + OpenSSH server + Wi-Fi"
LICENSE = "MIT"

# Start from the stock minimal image and add to it.
require recipes-core/images/core-image-minimal.bb

# ssh-server-openssh pulls in openssh-sshd (+ host key generation on first boot).
IMAGE_FEATURES += "ssh-server-openssh"

# allow-root-login flips "PermitRootLogin" to "yes" so the password works over
# SSH too. Without it, root may log in with the key only (prohibit-password).
IMAGE_FEATURES += "${@'allow-root-login' if d.getVar('MYLAB_ALLOW_ROOT_PASSWORD_SSH') == 'yes' else ''}"

IMAGE_INSTALL:append = " \
    ssh-root-key \
    kernel-modules \
    iproute2 \
"

# Wi-Fi: CYW43455 firmware (also a machine RRECOMMENDS; listed so it can't be
# dropped silently), regulatory database, supplicant + CLI, and our config
# that joins the network from config.env.
IMAGE_INSTALL:append = " \
    linux-firmware-rpidistro-bcm43455 \
    wireless-regdb-static \
    wpa-supplicant \
    wpa-supplicant-cli \
    wpa-supplicant-passphrase \
    iw \
    wifi-config \
"

# First boot: grow / to fill the card. mDNS: reachable as <hostname>.local.
# (NTP needs nothing extra: systemd-timesyncd ships with systemd.)
IMAGE_INSTALL:append = " \
    rootfs-expand \
    avahi-daemon \
"

# Root password, as a SHA-512 crypt hash (set in local.conf by yocto.sh).
inherit extrausers
EXTRA_USERS_PARAMS = "usermod -p '${MYLAB_ROOT_HASH}' root;"

# A bit of headroom on the rootfs partition (in KiB).
IMAGE_ROOTFS_EXTRA_SPACE = "131072"

# .wic.xz opens directly in Raspberry Pi Imager; .bmap is for bmaptool (flash.sh).
IMAGE_FSTYPES = "wic.xz wic.bmap"

# Sanity check while the rootfs is assembled: packages we rely on that arrive
# indirectly (an IMAGE_FEATURES entry, a dependency). Missing IMAGE_INSTALL
# entries already fail the build on their own, so they need no check here.
MYLAB_REQUIRED_PACKAGES = "openssh-sshd"

python mylab_check_packages() {
    from oe.rootfs import image_list_installed_packages
    installed = image_list_installed_packages(d)
    missing = [p for p in d.getVar('MYLAB_REQUIRED_PACKAGES').split() if p not in installed]
    if missing:
        bb.fatal("Missing from %s: %s" % (d.getVar('PN'), " ".join(missing)))
    bb.note("Required packages present: %s" % d.getVar('MYLAB_REQUIRED_PACKAGES'))
}
ROOTFS_POSTPROCESS_COMMAND += "mylab_check_packages"
