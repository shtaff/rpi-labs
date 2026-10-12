#!/usr/bin/env bash
# ROS 2 on the PC (Ubuntu 24.04 / WSL2) and on the Pi: install, test, build, check.
#
#   ./tools/ros2.sh install     # apt: ROS 2 (ros-base + demo nodes) + colcon, once (sudo)
#   ./tools/ros2.sh demo        # official demo_nodes_cpp talker -> listener, checked
#   ./tools/ros2.sh build       # colcon build ros2_ws (our counter_demo package)
#   ./tools/ros2.sh run         # ros2 launch counter_demo counter.launch.py (Ctrl+C stops)
#   ./tools/ros2.sh check       # counter_check.sh: nodes, topic, start/stop service
#   ./tools/ros2.sh all         # install -> demo -> build -> check
#   ./tools/ros2.sh pi [host]   # the same check on the Pi, over SSH (default <hostname>.local)
#
# By hand, in any new terminal:
#   source /opt/ros/jazzy/setup.bash && source ros2_ws/install/setup.bash
#   ros2 run counter_demo counter_publisher       # terminal 1
#   ros2 run counter_demo counter_subscriber      # terminal 2
#   ros2 run counter_demo counter_control stop    # terminal 3 (or: start, cycle 5)

source "$(dirname "$0")/../common/lib.sh"

WS="$REPO_ROOT/ros2_ws"

# Source ROS 2 (and our workspace, once built) into this shell. The setup
# scripts aren't written for `set -eu` or an ERR trap, so lift them meanwhile.
ros_env() {
    local f="/opt/ros/$ROS2_DISTRO/setup.bash"
    [[ -f "$f" ]] || die "ROS 2 $ROS2_DISTRO is not installed. Run: $0 install"
    trap - ERR; set +eu
    # shellcheck disable=SC1090
    source "$f"
    # shellcheck disable=SC1091
    [[ -f "$WS/install/setup.bash" ]] && source "$WS/install/setup.bash"
    set -eu; trap 'die "command failed (line $LINENO): $BASH_COMMAND"' ERR
}

# Official install for Ubuntu (docs.ros.org, "Ubuntu (deb packages)"):
# the ros2-apt-source package adds the repository and its signing key.
step_install() {
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "$ID" == ubuntu ]] || die "Needs Ubuntu (got $ID)"
    [[ "$ROS2_DISTRO" != jazzy || "$VERSION_CODENAME" == noble ]] \
        || warn "ROS 2 jazzy packages are built for Ubuntu 24.04 (noble), this is $VERSION_CODENAME"

    log "Adding the ROS 2 apt repository (sudo)"
    sudo apt-get update
    sudo apt-get install -y software-properties-common curl locales
    sudo add-apt-repository -y universe
    sudo locale-gen en_US.UTF-8
    if ! dpkg -s ros2-apt-source >/dev/null 2>&1; then
        local ver deb
        ver="$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
               | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
        [[ -n "$ver" ]] || die "Could not look up the latest ros-apt-source release"
        deb="$(mktemp --suffix=.deb)"
        curl -fsSL -o "$deb" \
            "https://github.com/ros-infrastructure/ros-apt-source/releases/download/$ver/ros2-apt-source_$ver.${VERSION_CODENAME}_all.deb"
        sudo dpkg -i "$deb"
        rm -f "$deb"
    fi

    log "Installing ROS 2 $ROS2_DISTRO (ros-base, demo nodes, std_srvs) and colcon"
    sudo apt-get update
    sudo apt-get install -y \
        "ros-$ROS2_DISTRO-ros-base" \
        "ros-$ROS2_DISTRO-demo-nodes-cpp" \
        "ros-$ROS2_DISTRO-demo-nodes-py" \
        "ros-$ROS2_DISTRO-std-srvs" \
        ros-dev-tools
    ok "ROS 2 $ROS2_DISTRO installed in /opt/ros/$ROS2_DISTRO"
    echo "      For new terminals: echo 'source /opt/ros/$ROS2_DISTRO/setup.bash' >> ~/.bashrc"
}

# talker publishes "Hello World: N" on /chatter, listener prints "I heard: [...]".
step_demo() {
    ros_env
    local tmp bin talker listener
    tmp="$(mktemp -d)"
    bin="$(ros2 pkg prefix demo_nodes_cpp)/lib/demo_nodes_cpp"
    ros2 daemon start >/dev/null 2>&1 || true    # the CLI's discovery cache
    log "Official demo: demo_nodes_cpp talker / listener (= ros2 run demo_nodes_cpp talker)"
    # The executables themselves, not `ros2 run`: then the kill below reaches
    # the nodes (a background job ignores Ctrl+C's SIGINT, so it gets SIGTERM).
    "$bin/talker" >"$tmp/talker.log" 2>&1 &
    talker=$!
    "$bin/listener" >"$tmp/listener.log" 2>&1 &
    listener=$!
    sleep 6

    echo "$ ros2 node list";        ros2 node list | sed 's/^/    /'
    echo "$ ros2 topic list -t";    ros2 topic list -t | sed 's/^/    /'
    echo "$ ros2 topic info /chatter"; ros2 topic info /chatter | sed 's/^/    /'

    kill -TERM "$listener" "$talker" 2>/dev/null || true
    wait "$listener" "$talker" 2>/dev/null || true
    echo "talker:";   sed -n '1,3p' "$tmp/talker.log"   | sed 's/^/    /'
    echo "listener:"; sed -n '1,3p' "$tmp/listener.log" | sed 's/^/    /'
    if grep -q 'I heard: \[Hello World' "$tmp/listener.log"; then
        ok "listener received the talker's messages: ROS 2 works on this machine"
        rm -rf "$tmp"
    else
        die "listener received nothing (logs in $tmp)"
    fi
}

step_build() {
    ros_env
    command -v colcon >/dev/null || die "colcon not found. Run: $0 install"
    log "colcon build in $WS"
    (cd "$WS" && colcon build --event-handlers console_direct+)
    ok "Built. In a new terminal: source $WS/install/setup.bash"
}

step_run() {
    [[ -f "$WS/install/setup.bash" ]] || step_build
    ros_env
    exec ros2 launch counter_demo counter.launch.py "$@"
}

step_check() {
    [[ -f "$WS/install/setup.bash" ]] || step_build
    ros_env
    ros2 run counter_demo counter_check.sh
}

# The image starts counter-demo.service at boot; check it, then run the same
# counter_check.sh on the Pi (as installed by the counter-demo recipe).
step_pi() {
    local host="${1:-$RPI_HOSTNAME.local}"
    local key="${SSH_PUBKEY%.pub}"
    local ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=10
                    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK_DIR/known_hosts")
    mkdir -p "$WORK_DIR"
    log "ROS 2 on root@$host"
    # shellcheck disable=SC2016  # expanded on the Pi
    ssh "${ssh_opts[@]}" root@"$host" '
        . /etc/profile
        echo "ROS_DISTRO=$ROS_DISTRO  RMW: ${RMW_IMPLEMENTATION:-default (Fast DDS)}"
        echo "$ systemctl is-active counter-demo"; systemctl is-active counter-demo | sed "s/^/    /"
        echo "$ journalctl -u counter-demo -n 6"; journalctl -u counter-demo -n 6 --no-pager -o cat | sed "s/^/    /"
        ros2 run counter_demo counter_check.sh
    ' || die "ROS 2 check on the Pi failed. If $host doesn't resolve, pass the IP: $0 pi 192.168.x.y"
}

case "${1:-}" in
    install) step_install ;;
    demo)    step_demo ;;
    build)   step_build ;;
    run)     shift; step_run "$@" ;;
    check)   step_check ;;
    pi)      step_pi "${2:-}" ;;
    all)     step_install; step_demo; step_build; step_check ;;
    -h|--help|"") sed -n '2,17p' "$0" ;;
    *) die "Unknown step '$1'. Use: install demo build run check pi all" ;;
esac
