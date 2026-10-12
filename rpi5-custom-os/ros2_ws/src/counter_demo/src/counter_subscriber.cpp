// counter_subscriber: prints every value received on the "counter" topic and
// notices missed values (a gap) and restarts (the count went down).

#include <cinttypes>
#include <cstdint>
#include <memory>

#include "rclcpp/rclcpp.hpp"
#include "std_msgs/msg/u_int64.hpp"

class CounterSubscriber : public rclcpp::Node
{
public:
  CounterSubscriber()
  : Node("counter_subscriber")
  {
    sub_ = create_subscription<std_msgs::msg::UInt64>(
      "counter", 10, [this](const std_msgs::msg::UInt64 & msg) {on_counter(msg.data);});
    RCLCPP_INFO(get_logger(), "Listening on '%s'", sub_->get_topic_name());
  }

private:
  void on_counter(uint64_t value)
  {
    if (last_ != 0 && value > last_ + 1) {
      RCLCPP_WARN(get_logger(), "Missed %" PRIu64 " value(s)", value - last_ - 1);
    } else if (last_ != 0 && value <= last_) {
      RCLCPP_INFO(get_logger(), "Counter restarted");
    }
    RCLCPP_INFO(get_logger(), "I heard: %" PRIu64, value);
    last_ = value;
  }

  uint64_t last_ = 0;
  rclcpp::Subscription<std_msgs::msg::UInt64>::SharedPtr sub_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<CounterSubscriber>());
  rclcpp::shutdown();
  return 0;
}
