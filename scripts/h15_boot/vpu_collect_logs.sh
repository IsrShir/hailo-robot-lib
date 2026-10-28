#!/bin/bash
# Collect the logs of an h15-vpu-setup run into a run directory on the host the
# skill runs on: the shuttle in local mode, the laptop in remote mode. Board files
# under /tmp are lost on the next reboot or CI reflash, so collect before that.
#
# Usage:
#   scripts/h15_boot/vpu_collect_logs.sh --run-dir DIR [--target T] [--shuttle hailo@<ip>]
#     --run-dir   where to save (created if missing); the skill makes one per run:
#                 $H15_RUNS/<release>_<machine>_<shuttle>_<YYYYmmdd-HHMMSS>
#     --target    board ssh target: root@10.0.0.1 on the shuttle, or a ProxyJump
#                 alias (e.g. h15-167) from a laptop. Default $TARGET or root@10.0.0.1
#     --shuttle   remote mode: fetch the shuttle-side logs (flash, console) from this
#                 host. Omit in local mode (they're read from this host's $HOME).
#
# Saves (missing files are skipped and listed in MISSING.txt):
#   board/   df_live.log, df_smoke.log (app), hailo_analytics.log, medialib.log,
#            dmesg.txt, build-info, os-release, bundle-manifest.txt, check_board.txt
#   shuttle/ h15_flash.out (flash summary), h15_console.log (full serial console)
# Step outputs the skill tee'd into the run dir (e.g. 2_stage.log) stay as they are.

set -uo pipefail
RUN_DIR=""; SHUTTLE=""; T=""
while [ $# -gt 0 ]; do
    case "$1" in
        --run-dir) RUN_DIR="$2"; shift 2 ;;
        --target)  T="$2"; shift 2 ;;
        --shuttle) SHUTTLE="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$RUN_DIR" ] || { echo "ERROR: --run-dir is required" >&2; exit 1; }
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${T:-${TARGET:-root@10.0.0.1}}"

mkdir -p "$RUN_DIR/board" "$RUN_DIR/shuttle"
: > "$RUN_DIR/MISSING.txt"
echo "===== Collecting logs into $RUN_DIR ====="

# --- board -------------------------------------------------------------------------
if target_ssh true 2>/dev/null; then
    for f in /tmp/df_live.log /tmp/df_smoke.log /home/root/hailo_analytics.log /home/root/medialib.log \
             /etc/build-info /etc/os-release /usr/share/drone-follow/bundle-manifest.txt; do
        if target_ssh "cat $f" > "$RUN_DIR/board/$(basename "$f")" 2>/dev/null; then
            echo "  ok   board:$f"
        else
            rm -f "$RUN_DIR/board/$(basename "$f")"; echo "board:$f" >> "$RUN_DIR/MISSING.txt"
        fi
    done
    target_ssh dmesg > "$RUN_DIR/board/dmesg.txt" 2>/dev/null && echo "  ok   board:dmesg"
    "$(dirname "$0")/check_board.sh" "$TARGET" > "$RUN_DIR/board/check_board.txt" 2>&1
    echo "  ok   check_board.sh (exit $?)"
else
    echo "  WARN board $TARGET not reachable; board logs skipped"
    echo "board: unreachable" >> "$RUN_DIR/MISSING.txt"
fi

# --- shuttle -----------------------------------------------------------------------
for f in h15_flash.out h15_console.log; do
    if [ -n "$SHUTTLE" ]; then
        ssh -n -o BatchMode=yes "$SHUTTLE" "cat ~/$f" > "$RUN_DIR/shuttle/$f" 2>/dev/null
    else
        cat ~/"$f" > "$RUN_DIR/shuttle/$f" 2>/dev/null
    fi
    if [ -s "$RUN_DIR/shuttle/$f" ]; then
        echo "  ok   shuttle:~/$f"
    else
        rm -f "$RUN_DIR/shuttle/$f"; echo "shuttle:~/$f" >> "$RUN_DIR/MISSING.txt"
    fi
done

[ -s "$RUN_DIR/MISSING.txt" ] && echo "  missing (not produced by this run, or already gone): $(tr '\n' ' ' < "$RUN_DIR/MISSING.txt")"
[ -s "$RUN_DIR/MISSING.txt" ] || rm -f "$RUN_DIR/MISSING.txt"
echo "  saved on $(hostname -s): $RUN_DIR ($(du -sh "$RUN_DIR" | cut -f1))"
