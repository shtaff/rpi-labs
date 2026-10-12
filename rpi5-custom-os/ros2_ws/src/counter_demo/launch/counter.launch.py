"""Start the counter publisher and subscriber together.

    ros2 launch counter_demo counter.launch.py
    ros2 launch counter_demo counter.launch.py period_ms:=200 start_running:=false
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    args = {
        'period_ms': '1000',
        'start_running': 'true',
        'reset_on_start': 'false',
    }
    return LaunchDescription([
        *[DeclareLaunchArgument(name, default_value=value) for name, value in args.items()],
        Node(
            package='counter_demo',
            executable='counter_publisher',
            output='screen',
            parameters=[{name: LaunchConfiguration(name) for name in args}],
        ),
        Node(
            package='counter_demo',
            executable='counter_subscriber',
            output='screen',
        ),
    ])
