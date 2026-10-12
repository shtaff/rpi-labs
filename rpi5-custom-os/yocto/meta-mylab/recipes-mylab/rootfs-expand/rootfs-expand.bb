SUMMARY = "First boot: grow the root partition and filesystem to fill the SD card"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"

# files/rootfs-expand is copied in by yocto.sh from common/target/
SRC_URI = " \
    file://rootfs-expand \
    file://rootfs-expand.service \
"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/rootfs-expand ${D}${sbindir}/rootfs-expand
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/rootfs-expand.service ${D}${systemd_system_unitdir}/
}

SYSTEMD_SERVICE:${PN} = "rootfs-expand.service"
RDEPENDS:${PN} = "util-linux-sfdisk util-linux-partx e2fsprogs-resize2fs"
