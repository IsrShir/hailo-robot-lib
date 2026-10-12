#!/bin/bash
# Full install on a Hailo15 target flashed with the phys-ai image:
# UI build, app code, native pipeline binary, pyzmq, boot service, then a check.
#
# Usage:
#   ./install.sh                       # uses default target root@10.0.0.1
#   ./install.sh root@<ip>
#   TARGET=root@<ip> ./install.sh
#   SSH_OPTS="-o ProxyCommand=none" ./install.sh   # hosts with an sss ssh proxy
#   SKIP_UI_BUILD=1 ./install.sh       # reuse an existing robot_follow/ui/build (no npm needed)

set -e
source "$(dirname "$0")/common.sh"
export TARGET SSH_OPTS

echo "===== Full install on $TARGET ====="
echo ""

if [ "${SKIP_UI_BUILD:-0}" = "1" ]; then
    echo "Skipping UI build (SKIP_UI_BUILD=1)"
else
    "$SCRIPT_DIR/build_ui.sh"
fi
echo ""
"$SCRIPT_DIR/install_app.sh" "$TARGET"
echo ""
"$SCRIPT_DIR/install_native.sh" "$TARGET"
echo ""
"$SCRIPT_DIR/install_pyzmq.sh" "$TARGET"
echo ""
"$SCRIPT_DIR/install_service.sh" "$TARGET"
echo ""
"$SCRIPT_DIR/check_board.sh" "$TARGET"

echo ""
echo "===== Full install complete ====="
