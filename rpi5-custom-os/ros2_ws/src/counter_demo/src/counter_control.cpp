// counter_control: a service client that starts and stops the counter by
// calling "counter/enable" (std_srvs/srv/SetBool) on counter_publisher.
//
//   ros2 run counter_demo counter_control start
//   ros2 run counter_demo counter_control stop
//   ros2 run counter_demo counter_control cycle [seconds]   # stop/start forever, default 5 s

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "rclcpp/rclcpp.hpp"
#include "std_srvs/srv/set_bool.hpp"

using SetBool = std_srvs::srv::SetBool;
using namespace std::chrono_literals;

static bool call_enable(
  const rclcpp::Node::SharedPtr & node, const rclcpp::Client<SetBool>::SharedPtr & client,
  bool enable)
{
  auto req = std::make_shared<SetBool::Request>();
  req->data = enable;
  auto future = client->async_send_request(req);
  if (rclcpp::spin_until_future_complete(node, future, 5s) != rclcpp::FutureReturnCode::SUCCESS) {
    RCLCPP_ERROR(node->get_logger(), "No answer from '%s'", client->get_service_name());
    client->remove_pending_request(future);
    return false;
  }
  const auto res = future.get();
  RCLCPP_INFO(
    node->get_logger(), "%s -> %s", enable ? "start" : "stop", res->message.c_str());
  return res->success;
}

static int usage()
{
  std::fprintf(stderr, "Usage: counter_control start | stop | cycle [seconds]\n");
  return 2;
}

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  // Drop --ros-args ... so only our own arguments are left.
  const std::vector<std::string> args = rclcpp::remove_ros_arguments(argc, argv);
  if (args.size() < 2) {
    rclcpp::shutdown();
    return usage();
  }
  const std::string cmd = args[1];
  if (cmd != "start" && cmd != "stop" && cmd != "cycle") {
    rclcpp::shutdown();
    return usage();
  }

  auto node = rclcpp::Node::make_shared("counter_control");
  auto client = node->create_client<SetBool>("counter/enable");
  if (!client->wait_for_service(5s)) {
    RCLCPP_ERROR(
      node->get_logger(), "Service '%s' not available: is counter_publisher running?",
      client->get_service_name());
    rclcpp::shutdown();
    return 1;
  }

  int rc = 0;
  if (cmd == "cycle") {
    const double seconds = args.size() > 2 ? std::stod(args[2]) : 5.0;
    const auto period = std::chrono::duration<double>(seconds);
    bool enable = false;   // the counter runs from launch, so stop first
    while (rclcpp::ok()) {
      if (!call_enable(node, client, enable)) {
        rc = 1;
        break;
      }
      enable = !enable;
      rclcpp::sleep_for(std::chrono::duration_cast<std::chrono::nanoseconds>(period));
    }
  } else {
    rc = call_enable(node, client, cmd == "start") ? 0 : 1;
  }

  rclcpp::shutdown();
  return rc;
}
