cmake_minimum_required(VERSION 3.14)
project(counter_demo)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)
find_package(std_srvs REQUIRED)

# One executable per node. `ros2 run counter_demo <name>` looks in lib/<package>.
foreach(node counter_publisher counter_subscriber counter_control)
  add_executable(${node} src/${node}.cpp)
  target_link_libraries(${node} rclcpp::rclcpp ${std_msgs_TARGETS} ${std_srvs_TARGETS})
  install(TARGETS ${node} DESTINATION lib/${PROJECT_NAME})
endforeach()

# Self-test: `ros2 run counter_demo counter_check.sh` (works on the PC and the Pi).
install(PROGRAMS scripts/counter_check.sh DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})

ament_package()
