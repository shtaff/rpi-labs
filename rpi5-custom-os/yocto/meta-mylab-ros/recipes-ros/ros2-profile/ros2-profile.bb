SUMMARY = "Puts ROS 2 on PATH in every login shell (SSH, console)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

# Without this, every shell on the Pi first needs: . /opt/ros/jazzy/setup.sh
do_install() {
    install -d ${D}${sysconfdir}/profile.d
    cat > ${D}${sysconfdir}/profile.d/ros2.sh <<EOF
# ROS 2 ${ROS_DISTRO} environment (PATH, AMENT_PREFIX_PATH, PYTHONPATH, ...).
# /etc/profile reads this for login shells; for a one-off command over SSH use
#   ssh root@<pi> '. /etc/profile; ros2 node list'
[ -f /opt/ros/${ROS_DISTRO}/setup.sh ] && . /opt/ros/${ROS_DISTRO}/setup.sh
EOF
}

FILES:${PN} = "${sysconfdir}/profile.d/ros2.sh"
