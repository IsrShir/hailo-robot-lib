#!/bin/bash
# Flash a staged image through the shuttle's CI tooling: burn SCU firmware, SCU
# bootloader and u-boot over UART recovery, then Board Init (CI's EMMC_BOARD_INIT).
# Needed when the board's SCU firmware is newer than the image: the image's own
# Board Init kernel panics ("arm-scmi: Firmware version mismatch"). See SKILL.md 3a.
#
# Usage (on the shuttle; from a laptop through vpu_remote.sh start):
#   scripts/h15_boot/vpu_ci_board_init.sh --image-dir <staged dir> --machine <machine>          # print the command
#   scripts/h15_boot/vpu_ci_board_init.sh --image-dir <staged dir> --machine <machine> --run    # run it (~10 min)
#
# The board-specific flags are taken from the shuttle's latest CI job
# (/local/workspace/<ws>/results_dir/*/setup_preparation_logs/setup_preparation_cmd.txt),
# so they match the board; the image comes from <staged dir> (vpu_stage.sh), so
# CI's own image_files stay untouched. Output: ~/h15_ci_prep/ (run.out = the log).
# It points /srv/tftp at the staged folder itself; vpu_stage.sh's revert line still applies.

set -euo pipefail
IMAGE_DIR=""; MACHINE=""; RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image-dir) IMAGE_DIR="$2"; shift 2 ;;
        --machine)   MACHINE="$2"; shift 2 ;;
        --run)       RUN=1; shift ;;
        -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -d "$IMAGE_DIR" ] && [ -n "$MACHINE" ] || { echo "ERROR: --image-dir <existing dir> and --machine are required" >&2; exit 1; }

CMDFILE=$(ls -td /local/workspace/*/results_dir/*/setup_preparation_logs 2>/dev/null | head -1)
[ -n "$CMDFILE" ] && CMDFILE="$CMDFILE/setup_preparation_cmd.txt"
[ -f "${CMDFILE:-}" ] || { echo "ERROR: no CI setup_preparation_cmd.txt under /local/workspace: this shuttle has no CI workspace" >&2; exit 1; }
WS=$(echo "$CMDFILE" | cut -d/ -f1-4)   # /local/workspace/<ws>
[ -x "$WS/mercury_venv/bin/python3" ] && [ -f "$WS/setup_preparation.py" ] \
    || { echo "ERROR: $WS has no mercury_venv / setup_preparation.py" >&2; exit 1; }

# Keep the board-specific flags of the CI job; the image source flags are replaced.
FLAGS=()
for f in --platform-type --scu-fw-flavor --uboot-source --recovery-device --emmc-boot-partition --emmc-bit-mode; do
    v=$(grep -oE -- "${f}[= ]+[^ ]+" "$CMDFILE" | head -1 | sed -E "s/^${f}[= ]+//") || true
    [ -n "$v" ] || { echo "ERROR: $f not found in $CMDFILE" >&2; exit 1; }
    FLAGS+=("$f" "$v")
done

OUT=$HOME/h15_ci_prep
CMD=("$WS/mercury_venv/bin/python3" setup_preparation.py --results-dir "$OUT" EMMC_BOARD_INIT
     --image-files-path "$IMAGE_DIR" --yocto-machine-name "$MACHINE" --use-uart-recovery "${FLAGS[@]}")
echo "flags from: $CMDFILE"
echo "command (in $WS): ${CMD[*]}"
[ "$RUN" = 1 ] || { echo "(not run: add --run)"; exit 0; }

mkdir -p "$OUT"
cd "$WS"
set -o pipefail
"${CMD[@]}" 2>&1 | tee "$OUT/run.out"
