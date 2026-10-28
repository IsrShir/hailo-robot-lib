#!/bin/bash
# Run drone_follow_h15 --native-pipeline --dry-run on the board in the background so
# a person can watch the web UI; stop it cleanly later.
#
# Usage:
#   scripts/h15_boot/vpu_live.sh start  [target] [minutes]   # default 30 min, then it stops itself
#   scripts/h15_boot/vpu_live.sh status [target]
#   scripts/h15_boot/vpu_live.sh stop   [target]
# target: root@10.0.0.1 on the shuttle (source shuttle.env), or a ProxyJump alias
# such as h15-167 from a laptop.
#
# Watching the UI from a PC/laptop: tunnel the board's port 5001 through the shuttle,
#   ssh -N -L 15002:10.0.0.1:5001 hailo@<shuttle-ip>
# then open http://localhost:15002 (Ctrl+F5 after an app update).
#
# Stops with ONE SIGINT to the python process (same as Ctrl+C). Never SIGKILL: that
# leaves the ISP stuck until a reboot.

set -uo pipefail
CMD=${1:?usage: $0 start|status|stop [target] [minutes]}
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${2:-${TARGET:-root@10.0.0.1}}"
MINUTES=${3:-30}
LOG=/tmp/df_live.log
APP_CMD="python3 -m robot_follow.drone_follow_h15"
# ^python3 matches the app's own command line only, not timeout's or this ssh's sh -c.
APP_RE="^python3 -m robot_follow.drone_follow_h15"

running() { target_ssh "pgrep -f '$APP_RE' >/dev/null"; }

case "$CMD" in
start)
    if running; then echo "already running"; exit 0; fi
    # Detached: subshell + stdin from /dev/null, or ssh waits for the app to exit.
    target_ssh "cd /home/root && (nohup timeout -s INT $((MINUTES * 60)) $APP_CMD --native-pipeline --dry-run \
        --mission-duration 86400 > $LOG 2>&1 < /dev/null &)"
    for _ in $(seq 1 30); do
        sleep 1
        target_ssh "grep -q 'web_server: Started' $LOG" 2>/dev/null && break
    done
    if target_ssh "grep -q 'web_server: Started' $LOG"; then
        echo "running for up to $MINUTES min; web UI on the board's port 5001; log: $LOG on the board"
    else
        echo "ERROR: web UI did not start; tail of $LOG:"; target_ssh "tail -20 $LOG"; exit 1
    fi
    ;;
status)
    if running; then
        echo "running"; target_ssh "grep '\[dry-run\]' $LOG | tail -3"
    else
        echo "not running"; target_ssh "tail -3 $LOG 2>/dev/null"
    fi
    ;;
stop)
    running || { echo "not running"; exit 0; }
    target_ssh "pkill -INT -f '$APP_RE'"
    for _ in $(seq 1 40); do sleep 1; running || { echo "stopped"; exit 0; }; done
    echo "ERROR: still running 40 s after SIGINT. Not killing it (that wedges the ISP); reboot the board if needed."
    exit 1
    ;;
*) echo "unknown command $CMD" >&2; exit 1 ;;
esac
