#!/bin/bash
# Run drone_follow_h15 --native-pipeline --dry-run on the board for a short time,
# check the web UI answers, then stop the app with ONE SIGINT (same as Ctrl+C)
# and report what happened. No flight controller is used.
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_smoke.sh [root@<ip>] [seconds]     # default 45 s
#
# Never kills the app hard: a SIGKILL leaves the ISP stuck until a reboot
# ("post event failed" in dmesg, black video). If the app doesn't exit after
# SIGINT, this says so and leaves it for a person to decide.
#
# Exit code 0 when the pipeline ran, the UI answered and the app exited cleanly.

set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${1:-${TARGET:-root@10.0.0.1}}"
SECS=${2:-45}
UI_PORT=5001
APP_CMD="python3 -m robot_follow.drone_follow_h15"
# For pgrep -f: the [p] keeps pgrep from matching the ssh "sh -c" line that carries
# this pattern (it would always find itself).
APP_PAT="[p]ython3 -m robot_follow.drone_follow_h15"
LOG=/tmp/df_smoke.log

echo "===== Smoke run on $TARGET (${SECS}s, --dry-run) ====="

# isp_media_server always holds /dev/video0 on these images; anything else is a conflict.
busy=$(target_ssh "pgrep -f '$APP_PAT' >/dev/null && echo app
    for p in \$(fuser /dev/video0 2>/dev/null); do
        c=\$(cat /proc/\$p/comm 2>/dev/null)  # comm is cut to 15 chars
        case \"\$c\" in isp_media_serv*) ;; *) echo \"\$p(\$c)\" ;; esac
    done" || true)
if [ -n "$busy" ]; then
    echo "ERROR: the app or another process already uses the camera ($busy)."
    echo "  Stop it first (a running app: Ctrl+C in its terminal; the service: /etc/init.d/drone-follow stop)."
    exit 1
fi

# Fully detached (subshell + stdin from /dev/null): otherwise ssh keeps the channel
# open and only returns when the app exits, so the UI check below would run too late.
target_ssh "cd /home/root && (nohup timeout -s INT $SECS $APP_CMD --native-pipeline --dry-run --mission-duration 3600 > $LOG 2>&1 < /dev/null &)"

# Ask the board itself, so this works on the shuttle and through a ProxyJump alias.
ui=$(target_ssh "python3 - $SECS $UI_PORT" <<'EOF'
import sys, time, urllib.request
secs, port = int(sys.argv[1]), sys.argv[2]
for _ in range(secs):
    time.sleep(1)
    try:
        if urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2).status == 200:
            print("ok")
            break
    except Exception:
        pass
else:
    print("FAIL")
EOF
)
echo "  web UI on the board's port $UI_PORT: $ui"

# Wait for timeout's SIGINT to land and the app to shut down (pipeline + mavsdk).
# While it runs, track the lowest free memory outside CMA: most of the RAM is CMA
# (video buffers), and the app lives in what's left.
min_free=""
for _ in $(seq 1 $((SECS + 40))); do
    sleep 1
    free=$(target_ssh "pgrep -f '$APP_PAT' >/dev/null && \
        awk '/^MemFree:/{f=\$2} /^CmaFree:/{c=\$2} END{print int((f-c)/1024)}' /proc/meminfo") || break
    if [ -z "$min_free" ] || [ "$free" -lt "$min_free" ]; then min_free=$free; fi
done
if target_ssh "pgrep -f '$APP_PAT' >/dev/null"; then
    echo "ERROR: the app is still running 40 s after SIGINT. Not killing it (that wedges the ISP)."
    echo "  Look at $LOG on the board; send one more Ctrl+C/SIGINT, or reboot the board."
    exit 1
fi

target_ssh "sh -s" <<EOF
log=$LOG
cmds=\$(grep -c '\[dry-run\] cmd' \$log)
moving=\$(grep '\[dry-run\] cmd' \$log | grep -vc 'yaw=0.00 deg/s')
lost=\$(grep -c 'target lost' \$log)
echo "  dry-run commands: \$cmds (\$moving with a non-zero yaw = a person was followed), target-lost: \$lost"
grep -E 'Traceback|exited immediately|Error|ERROR' \$log | grep -v 'dry-run' | head -5 | sed 's/^/  log: /'
awk '/^MemTotal:/{t=\$2} /^CmaTotal:/{c=\$2} END{printf "  RAM: %d MB total, %d MB CMA; lowest free outside CMA while the app ran: ${min_free:-?} MB\n", t/1024, c/1024}' /proc/meminfo
dmesg | grep -q 'post event failed' && echo "  WARN dmesg has 'post event failed' (ISP stuck: reboot the board)"
echo "  full log on the board: \$log"
EOF

fails=0
[ "$ui" = ok ] || fails=1
target_ssh "grep -q '\[dry-run\] cmd\|\[dry-run\] target lost' $LOG" || { echo "ERROR: no control-loop output; the pipeline didn't run"; fails=1; }
target_ssh "grep -q 'Traceback\|exited immediately' $LOG" && { echo "ERROR: the app crashed (see the log)"; fails=1; }
[ "$fails" = 0 ] && echo "===== Smoke run passed =====" || echo "===== Smoke run FAILED ====="
exit "$fails"
