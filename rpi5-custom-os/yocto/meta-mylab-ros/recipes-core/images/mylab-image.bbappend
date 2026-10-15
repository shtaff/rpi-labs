# ROS 2 on top of the MyLab image. Appended from this layer, so mylab-image.bb
# itself stays ROS-free.
#
# ros-core:       rclcpp, rclpy, launch, the ros2 CLI (node/topic/service...),
#                 the DDS middleware (Fast DDS, the Jazzy default)
# demo-nodes-cpp: the official talker / listener, to test ROS itself
# counter-demo:   our publisher, subscriber and start/stop service client
# ros2-profile:   sources /opt/ros/<distro>/setup.sh in every login shell
IMAGE_INSTALL:append = " \
    ros-core \
    demo-nodes-cpp \
    counter-demo \
    ros2-profile \
"

# The ros2 CLI comes in through ros-core: checked by mylab_check_packages.
MYLAB_REQUIRED_PACKAGES:append = " ros2cli"
