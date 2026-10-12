// counter_publisher: publishes 1, 2, 3... on the "counter" topic.
//
// The "counter/enable" service (std_srvs/srv/SetBool) starts (data: true) and
// stops (data: false) the count. Stopping pauses: the next start continues
// from where it stopped, unless the reset_on_start parameter is true.
//
// Parameters:
//   period_ms       (int,  1000)  time between two messages
//   start_running   (bool, true)  count from launch, or wait for a start
//   reset_on_start  (bool, false) restart at 1 after every start

#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <memory>
#include <string>

#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/u_int64.hpp"
#include "std_srvs/srv/set_bool.hpp"

using SetBool = std_srvs::srv::SetBool;

class CounterPublisher : public rclcpp::Node
{
public:
  CounterPublisher()
  : Node("counter_publisher")
  {
    const auto period_ms = declare_parameter<int64_t>("period_ms", 1000);
    const bool start_running = declare_parameter<bool>("start_running", true);
    reset_on_start_ = declare_parameter<bool>("reset_on_start", false);

    // Depth 10: a slow subscriber may lag up to 10 values before losing any.
    pub_ = create_publisher<std_msgs::msg::UInt64>("counter", 10);

    timer_ = create_wall_timer(
      std::chrono::milliseconds(period_ms), [this] {publish_next();});
    if (!start_running) {
      timer_->cancel();
    }

    srv_ = create_service<SetBool>(
      "counter/enable",
      [this](const std::shared_ptr<SetBool::Request> req, std::shared_ptr<SetBool::Response> res) {
        on_enable(*req, *res);
      });

    RCLCPP_INFO(
      get_logger(), "Counting every %" PRId64 " ms on '%s' (%s). Start/stop: '%s'",
      period_ms, pub_->get_topic_name(), start_running ? "running" : "stopped",
      srv_->get_service_name());
  }

private:
  void publish_next()
  {
    std_msgs::msg::UInt64 msg;
    msg.data = ++count_;
    RCLCPP_INFO(get_logger(), "Publishing: %" PRIu64, msg.data);
    pub_->publish(msg);
  }

  void on_enable(const SetBool::Request & req, SetBool::Response & res)
  {
    const bool running = !timer_->is_canceled();
    res.success = true;
    if (req.data == running) {
      res.message = running ? "already running" : "already stopped";
    } else if (req.data) {
      if (reset_on_start_) {
        count_ = 0;
      }
      timer_->reset();   // re-arms the timer: next message after one period
      res.message = "started, next value " + std::to_string(count_ + 1);
    } else {
      timer_->cancel();
      res.message = "stopped at " + std::to_string(count_);
    }
    RCLCPP_INFO(get_logger(), "Service call enable=%s: %s",
      req.data ? "true" : "false", res.message.c_str());
  }

  uint64_t count_ = 0;
  bool reset_on_start_ = false;
  rclcpp::Publisher<std_msgs::msg::UInt64>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  rclcpp::Service<SetBool>::SharedPtr srv_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<CounterPublisher>());
  rclcpp::shutdown();
  return 0;
}
