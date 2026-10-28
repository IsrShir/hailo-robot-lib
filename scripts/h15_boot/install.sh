#!/bin/bash
# Install the drone-follow app on a Hailo15 target: UI build, app code, boot
# service, then a check.
#
# The runtime (pyzmq, df_native_pipeline built for the image's media library,
# and on formal VPU releases also numpy / mavsdk / grpcio / protobuf / pyhailort)
# comes from the bundle: build_bundle.sh + install_bundle.sh, run those first.
# The h15-vpu-setup skill does both.
#
# Usage:
#   ./install.sh                       # uses default target root@10.0.0.1
#   ./install.sh root@<ip>
#   TARGET=root@<ip> ./install.sh
#   SSH_OPTS="-o ProxyCommand=none" ./install.sh   # hosts with an sss ssh proxy
#   SKIP_UI_BUILD=1 ./install.sh       # reuse an existing robot_follow/ui/build (no npm needed)
#   SKIP_SERVICE=1 ./install.sh        # no boot service (bench: it would hold the camera)

set -e
source "$(dirname "$0")/common.sh"
export TARGET SSH_OPTS

echo "===== Installing drone-follow on $TARGET ====="
echo ""

if [ "${SKIP_UI_BUILD:-0}" = "1" ]; then
    echo "Skipping UI build (SKIP_UI_BUILD=1)"
else
    "$SCRIPT_DIR/build_ui.sh"
fi
echo ""
"$SCRIPT_DIR/install_app.sh" "$TARGET"
echo ""
if [ "${SKIP_SERVICE:-0}" = "1" ]; then
    echo "Skipping boot service (SKIP_SERVICE=1)"
else
    "$SCRIPT_DIR/install_service.sh" "$TARGET"
fi
echo ""
"$SCRIPT_DIR/check_board.sh" "$TARGET"

echo ""
echo "===== Install complete ====="
