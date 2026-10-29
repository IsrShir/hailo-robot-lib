#!/bin/bash
# Run drone_follow_h15 --native-pipeline --dry-run on the board (no flight controller).
#
# Usage:
#   scripts/h15_boot/vpu_run.sh smoke  [target] [seconds]   # default 45 s: run, check, stop, report
#   scripts/h15_boot/vpu_run.sh start  [target] [minutes]   # default 30 min, for watching the web UI
#   scripts/h15_boot/vpu_run.sh status [target]
#   scripts/h15_boot/vpu_run.sh stop   [target]
# target: root@10.0.0.1 on the shuttle (source shuttle.env), or a ProxyJump alias
# such as h15-167 from a laptop.
#
# smoke: checks the web UI answers, tracks the lowest free memory outside CMA,
# stops the app and reports dry-run commands (non-zero yaw = a person was followed).
# Exit 0 when the pipeline ran, the UI answered and the app exited cleanly.
#
# Watching the UI from a PC/laptop: tunnel the board's port 5001 through the shuttle,
#   ssh -N -L 15002:10.0.0.1:5001 hailo@<shuttle-ip>      then open http://localhost:15002
#
# The app is stopped with ONE SIGINT (same as Ctrl+C), never SIGKILL: a hard kill
# leaves the ISP stuck until a reboot ("post event failed" in dmesg, black video).
# If it doesn't exit after SIGINT, this says so and leaves it to a person.

set -uo pipefail
CMD=${1:?usage: $0 smoke|start|status|stop [target] [seconds|minutes]}
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${2:-${TARGET:-root@10.0.0.1}}"
UI_PORT=5001
APP_CMD="python3 -m robot_follow.drone_follow_h15"
# ^python3 matches the app's own command line only, not timeout's or this ssh's sh -c.
APP_RE="^python3 -m robot_follow.drone_follow_h15"

running() { target_ssh "pgrep -f '$APP_RE' >/dev/null"; }

# Start the app detached (subshell + stdin from /dev/null, or ssh waits for it to
# exit); timeout sends the single SIGINT when the time is up.
launch() {  # <seconds> <log>
    # isp_media_server always holds /dev/video0 on these images; anything else is a conflict.
    local busy
    busy=$(target_ssh "pgrep -f '$APP_RE' >/dev/null && echo app
        for p in \$(fuser /dev/video0 2>/dev/null); do
            c=\$(cat /proc/\$p/comm 2>/dev/null)  # comm is cut to 15 chars
            case \"\$c\" in isp_media_serv*) ;; *) echo \"\$p(\$c)\" ;; esac
        done" || true)
    if [ -n "$busy" ]; then
        echo "ERROR: the app or another process already uses the camera ($busy)."
        echo "  Stop it first ($0 stop, Ctrl+C in its terminal, or /etc/init.d/drone-follow stop)."
        exit 1
    fi
    target_ssh "cd /home/root && (nohup timeout -s INT $1 $APP_CMD --native-pipeline --dry-run \
        --mission-duration 86400 > $2 2>&1 < /dev/null &)"
}

# Poll the web UI from the board itself (works on the shuttle and through ProxyJump).
ui_check() {  # <seconds>
    target_ssh "python3 - $1 $UI_PORT" <<'EOF'
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
}

case "$CMD" in
smoke)
    SECS=${3:-45}
    LOG=/tmp/df_smoke.log
    echo "===== Smoke run on $TARGET (${SECS}s, --dry-run) ====="
    launch "$SECS" "$LOG"
    ui=$(ui_check "$SECS")
    echo "  web UI on the board's port $UI_PORT: $ui"
    # Wait for the SIGINT and the shutdown, tracking the lowest free memory outside
    # CMA: most RAM is CMA (video buffers) and the app lives in what's left.
    min_free=""
    for _ in $(seq 1 $((SECS + 40))); do
        sleep 1
        free=$(target_ssh "pgrep -f '$APP_RE' >/dev/null && \
            awk '/^MemFree:/{f=\$2} /^CmaFree:/{c=\$2} END{print int((f-c)/1024)}' /proc/meminfo") || break
        if [ -z "$min_free" ] || [ "$free" -lt "$min_free" ]; then min_free=$free; fi
    done
    if running; then
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
    ;;
start)
    MINUTES=${3:-30}
    LOG=/tmp/df_live.log
    if running; then echo "already running"; exit 0; fi
    launch $((MINUTES * 60)) "$LOG"
    if [ "$(ui_check 30)" = ok ]; then
        echo "running for up to $MINUTES min; web UI on the board's port $UI_PORT; log: $LOG on the board"
    else
        echo "ERROR: web UI did not start; tail of $LOG:"; target_ssh "tail -20 $LOG"; exit 1
    fi
    ;;
status)
    if running; then
        echo "running"; target_ssh "grep '\[dry-run\]' /tmp/df_live.log | tail -3"
    else
        echo "not running"
    fi
    ;;
stop)
    running || { echo "not running"; exit 0; }
    target_ssh "pkill -INT -f '$APP_RE'"
    for _ in $(seq 1 40); do sleep 1; running || { echo "stopped"; exit 0; }; done
    echo "ERROR: still running 40 s after SIGINT. Not killing it (that wedges the ISP); reboot the board if needed."
    exit 1
    ;;
*) echo "unknown command $CMD (smoke|start|status|stop)" >&2; exit 1 ;;
esac
