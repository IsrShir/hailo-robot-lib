#!/bin/bash
# Install the drone-follow SysV init service on a Hailo15 target.
#
# Usage:
#   ./install_service.sh                       # uses default target root@10.0.0.1
#   ./install_service.sh root@<ip>             # custom target
#   TARGET=root@<ip> ./install_service.sh      # via env var
#   RESET_ARGS=1 ./install_service.sh          # also overwrite /etc/default/drone-follow
#
# An existing /etc/default/drone-follow (the service's CLI args) is kept unless
# RESET_ARGS=1, so re-installing doesn't silently change how the drone flies.

set -e
source "$(dirname "$0")/common.sh"

echo "=== Installing drone-follow init service on $TARGET ==="

echo "[1/4] Copying init script and defaults config..."
target_scp "$SCRIPT_DIR/drone-follow" "$TARGET:/etc/init.d/drone-follow"
if [ "${RESET_ARGS:-0}" = "1" ] || ! target_ssh "[ -f /etc/default/drone-follow ]"; then
    target_scp "$SCRIPT_DIR/drone-follow.default" "$TARGET:/etc/default/drone-follow"
else
    echo "  Keeping existing /etc/default/drone-follow (RESET_ARGS=1 to overwrite):"
    target_ssh "grep '^DRONE_FOLLOW_ARGS' /etc/default/drone-follow"
fi

echo "[2/4] Setting permissions..."
target_ssh "chmod +x /etc/init.d/drone-follow"

echo "[3/4] Enabling auto-start on boot (rcS.d/S99)..."
target_ssh "ln -sf /etc/init.d/drone-follow /etc/rcS.d/S99drone-follow"

echo "[4/4] Starting service now..."
target_ssh "/etc/init.d/drone-follow restart"
sleep 2
target_ssh "/etc/init.d/drone-follow status"

echo ""
echo "Done. Useful commands on the target:"
echo "  /etc/init.d/drone-follow {start|stop|restart|status}"
echo "  tail -f /var/log/drone-follow.log"
echo "  nano /etc/default/drone-follow    # edit args, then restart"
