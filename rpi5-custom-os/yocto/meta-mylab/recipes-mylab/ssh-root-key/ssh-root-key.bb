SUMMARY = "Installs the developer's public key as root's authorized_keys"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# authorized_keys (your SSH_PUBKEY) is written by `yocto.sh configure` into
# MYLAB_GENERATED_DIR (build/conf/mylab/), outside the repo.
FILESEXTRAPATHS:prepend = "${MYLAB_GENERATED_DIR}:"
SRC_URI = "file://authorized_keys"
S = "${UNPACKDIR}"

do_install() {
    install -d -m 0700 ${D}${ROOT_HOME}/.ssh
    install -m 0600 ${UNPACKDIR}/authorized_keys ${D}${ROOT_HOME}/.ssh/authorized_keys
}

FILES:${PN} = "${ROOT_HOME}/.ssh"
