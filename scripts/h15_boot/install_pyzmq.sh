#!/bin/bash
# Install pyzmq on a Hailo15 target (needed for --native-pipeline: the Python app
# receives detections from df_native_pipeline over ZMQ).
#
# The Yocto image has no pyzmq and the target has no pip, so this downloads the
# official manylinux aarch64 wheel on the build host and copies its contents to
# the target's site-packages. The wheel bundles its own libzmq/libsodium
# (pyzmq.libs/). Skipped if the target can already `import zmq`.
#
# Usage:
#   ./install_pyzmq.sh [root@<ip>]
#   PYZMQ_VERSION=26.4.0 ./install_pyzmq.sh      # default version (matches the reference board)

set -e
source "$(dirname "$0")/common.sh"

PYZMQ_VERSION=${PYZMQ_VERSION:-26.4.0}

echo "=== Installing pyzmq on $TARGET ==="
if target_ssh "python3 -c 'import zmq, sys; print(\"pyzmq\", zmq.__version__, \"already installed\")'" 2>/dev/null; then
    exit 0
fi

PYVER=$(target_ssh "python3 -c 'import sys; print(\"%d%d\" % sys.version_info[:2])'")
SITE=$(target_ssh "python3 -c 'import sysconfig; print(sysconfig.get_paths()[\"purelib\"])'")
echo "  target: python ${PYVER:0:1}.${PYVER:1}, site-packages $SITE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 -m pip download --quiet --no-deps --only-binary=:all: \
    --platform manylinux2014_aarch64 --platform manylinux_2_28_aarch64 \
    --implementation cp --python-version "$PYVER" --abi "cp$PYVER" \
    -d "$WORK" "pyzmq==$PYZMQ_VERSION"
WHEEL=$(ls "$WORK"/pyzmq-*.whl)
echo "  wheel: $(basename "$WHEEL")"
python3 -I -m zipfile -e "$WHEEL" "$WORK/unpacked"

target_rsync -a "$WORK/unpacked/zmq" "$WORK/unpacked/pyzmq.libs" "$TARGET:$SITE/"
target_ssh "python3 -c 'import zmq; print(\"pyzmq\", zmq.__version__, \"OK, libzmq\", zmq.zmq_version())'"
echo "Done."
