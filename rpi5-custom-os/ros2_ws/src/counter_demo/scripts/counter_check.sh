#!/bin/sh
# End-to-end check of counter_demo with the ROS 2 command line tools.
# Same script on the PC and on the Pi (POSIX sh, BusyBox is enough):
#
#   ros2 run counter_demo counter_check.sh
#
# Uses the running nodes if there are any (the Pi starts them at boot),
# otherwise launches counter.launch.py for the duration of the check.
#
#   1. nodes        ros2 node list / ros2 node info
#   2. topic        ros2 topic list -t / ros2 topic info / ros2 topic echo
#   3. service      ros2 service list -t
#   4. stop         counter_control stop       -> "stopped at N", topic goes quiet
#   5. start        ros2 service call ... true -> first value after it is N+1
set -u

if ! command -v ros2 >/dev/null 2>&1; then
    for f in /opt/ros/*/setup.sh; do
        # shellcheck disable=SC1090
        [ -f "$f" ] && . "$f" && break
    done
fi
command -v ros2 >/dev/null 2>&1 || { echo "ros2 not found: source /opt/ros/<distro>/setup.sh first" >&2; exit 1; }

fails=0
step() { printf '\n==> %s\n' "$*"; }
pass() { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }
show() { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/    /'; }

# retry <tries> <command...>: run the command once a second until it succeeds.
# Discovery is not instant: a node shows up in `ros2 node list` after ~1-2 s.
retry() {
    n="$1"; shift
    while [ "$n" -gt 0 ]; do
        "$@" && return 0
        n=$((n - 1)); sleep 1
    done
    return 1
}

# First value seen on /counter within $1 seconds, or nothing. `ros2 topic echo
# --once` blocks while the counter is stopped, so it runs in the background.
read_counter() {
    out="$(mktemp)"
    ros2 topic echo --once /counter std_msgs/msg/UInt64 >"$out" 2>/dev/null &
    pid=$!
    i=0
    while [ "$i" -lt "$1" ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    sed -n 's/^data: *//p' "$out" | head -n 1
    rm -f "$out"
}

has_node() { ros2 node list 2>/dev/null | grep -qx "$1"; }

launched=""
cleanup() {
    [ -n "$launched" ] || return 0
    # TERM, not INT: a background job of a non-interactive shell ignores SIGINT.
    # ros2 launch handles TERM by shutting its nodes down cleanly.
    kill -TERM "$launched" 2>/dev/null; wait "$launched" 2>/dev/null
    echo "Stopped the nodes this check launched."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step "Nodes"
if has_node /counter_publisher || retry 3 has_node /counter_publisher; then
    echo "counter_publisher already running, using it."
else
    echo "No counter nodes running: ros2 launch counter_demo counter.launch.py"
    ros2 launch counter_demo counter.launch.py >/dev/null 2>&1 &
    launched=$!
fi
if retry 15 has_node /counter_publisher && retry 5 has_node /counter_subscriber; then
    pass "/counter_publisher and /counter_subscriber are up"
else
    fail "nodes did not show up in ros2 node list"
fi
show ros2 node list
show ros2 node info /counter_publisher

step "Topic"
show ros2 topic list -t
if ros2 topic list -t | grep -qx '/counter \[std_msgs/msg/UInt64\]'; then
    pass "/counter carries std_msgs/msg/UInt64"
else
    fail "/counter missing from ros2 topic list"
fi
show ros2 topic info /counter
info="$(ros2 topic info /counter 2>&1)"
echo "$info" | grep -q '^Publisher count: 1$' && pass "1 publisher" || fail "expected 1 publisher on /counter"
echo "$info" | grep -q '^Subscription count: [1-9]' && pass "subscriber connected" || fail "no subscriber on /counter"
a="$(read_counter 10)"
b="$(read_counter 10)"
if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then
    pass "ros2 topic echo /counter: $a, then $b (counting up)"
else
    fail "ros2 topic echo /counter did not see the count going up (got '${a}' then '${b}')"
fi

step "Service"
show ros2 service list -t
if ros2 service list -t | grep -qx '/counter/enable \[std_srvs/srv/SetBool\]'; then
    pass "/counter/enable is a std_srvs/srv/SetBool service"
else
    fail "/counter/enable missing from ros2 service list"
fi

step "Stop through the service (client node counter_control)"
printf '$ ros2 run counter_demo counter_control stop\n'
res="$(ros2 run counter_demo counter_control stop 2>&1)"
echo "$res" | sed 's/^/    /'
stopped_at="$(echo "$res" | sed -n 's/.*stopped at \([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$stopped_at" ]; then
    pass "counter stopped at $stopped_at"
else
    fail "counter_control stop: no 'stopped at N' in the answer"
fi
# One listener for both checks below, started now so that it is subscribed
# (the CLI takes a few seconds to start) before the counter starts again.
echo_out="$(mktemp)"
ros2 topic echo --once /counter std_msgs/msg/UInt64 >"$echo_out" 2>/dev/null &
echo_pid=$!
sleep 6
quiet="$(sed -n 's/^data: *//p' "$echo_out" | head -n 1)"
if [ -z "$quiet" ]; then
    pass "no messages on /counter for 6 s while stopped (ros2 topic echo listening)"
else
    fail "still publishing while stopped (got $quiet)"
fi

step "Start through the service (ros2 service call)"
printf '$ ros2 service call /counter/enable std_srvs/srv/SetBool "{data: true}"\n'
res="$(ros2 service call /counter/enable std_srvs/srv/SetBool '{data: true}' 2>&1)"
echo "$res" | sed 's/^/    /'
echo "$res" | grep -q 'success=True' && pass "service answered success=True" || fail "service call failed"
i=0
while [ "$i" -lt 10 ] && kill -0 "$echo_pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
kill "$echo_pid" 2>/dev/null; wait "$echo_pid" 2>/dev/null
c="$(sed -n 's/^data: *//p' "$echo_out" | head -n 1)"
rm -f "$echo_out"
# Paused, not reset: the first value after the start is the one after the
# value it stopped at. A count that never stopped would be ~8 further by now.
if [ -n "$c" ] && [ -n "$stopped_at" ] && [ "$c" -eq $((stopped_at + 1)) ]; then
    pass "counting again: first value $c, right after $stopped_at"
else
    fail "expected the count to resume at $((${stopped_at:-0} + 1)), got '${c}'"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "PASS  counter_demo: nodes, topic and start/stop service verified"
    exit 0
fi
echo "FAIL  $fails check(s) failed"
exit 1
