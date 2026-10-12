SUMMARY = "ROS 2 counter demo: publisher, subscriber and a start/stop service"
DESCRIPTION = "counter_publisher sends 1, 2, 3... on /counter, counter_subscriber \
prints them, and the /counter/enable service (std_srvs/SetBool) starts and stops \
the count; counter_control is a client for it."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=41c11e1d1db1c29b62276e0e9555ed43"

# Written like the recipes meta-ros generates from package.xml (see e.g.
# meta-ros2-jazzy/generated-recipes/demos/demo-nodes-cpp_*.bb).
inherit ros_distro_${ROS_DISTRO}
inherit ros_component

ROS_CN = "counter_demo"
ROS_BPN = "counter_demo"

# package.xml <depend>/<buildtool_depend>/<exec_depend>, in recipe names (_ -> -)
ROS_BUILD_DEPENDS = " \
    rclcpp \
    std-msgs \
    std-srvs \
"
ROS_BUILDTOOL_DEPENDS = " \
    ament-cmake-native \
"
ROS_EXEC_DEPENDS = " \
    rclcpp \
    std-msgs \
    std-srvs \
    launch \
    launch-ros \
    ros2launch \
"
DEPENDS = "${ROS_BUILD_DEPENDS} ${ROS_BUILDTOOL_DEPENDS}"
# counter_check.sh is a POSIX sh script using sed, grep, mktemp (BusyBox).
RDEPENDS:${PN} += "${ROS_EXEC_DEPENDS} ${VIRTUAL-RUNTIME_base-utils}"

# files/counter_demo/ is copied in by yocto.sh from ros2_ws/src/counter_demo,
# the same package you build on the PC with colcon.
SRC_URI = " \
    file://counter_demo/ \
    file://counter-demo.service \
"
S = "${UNPACKDIR}/counter_demo"

ROS_BUILD_TYPE = "ament_cmake"
inherit ros_${ROS_BUILD_TYPE} systemd

# Start the nodes at boot. To boot without them, in local.conf:
#   SYSTEMD_AUTO_ENABLE:pn-counter-demo = "disable"
SYSTEMD_SERVICE:${PN} = "counter-demo.service"
SYSTEMD_AUTO_ENABLE ?= "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    sed -e 's,@ROS_DISTRO@,${ROS_DISTRO},g' ${UNPACKDIR}/counter-demo.service \
        > ${D}${systemd_system_unitdir}/counter-demo.service
    chmod 0644 ${D}${systemd_system_unitdir}/counter-demo.service
}
