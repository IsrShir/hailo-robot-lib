#!/bin/bash
# Copy the native detection pipeline binary (df_native_pipeline) to a Hailo15 target.
# Needed for --native-pipeline. Build it first with robot_follow/native_pipeline/build.sh
# (cross-compiles with the Hailo Yocto SDK, /opt/poky/<ver>).
#
# Usage:
#   ./install_native.sh [root@<ip>]

set -e
source "$(dirname "$0")/common.sh"

BIN="$REPO_ROOT/robot_follow/native_pipeline/build/df_native_pipeline"

echo "=== Installing native pipeline binary on $TARGET ==="
if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN not found."
    echo "  Build it first (needs the Hailo Yocto SDK):"
    echo "    cd robot_follow/native_pipeline && ./build.sh"
    exit 1
fi

# The binary must keep this exact name; see robot_follow/native_pipeline/README.md.
target_ssh "mkdir -p /home/root/native_pipeline"
target_scp "$BIN" "$TARGET:/home/root/native_pipeline/df_native_pipeline"
target_ssh "chmod +x /home/root/native_pipeline/df_native_pipeline && md5sum /home/root/native_pipeline/df_native_pipeline"
echo "Done."
