#!/bin/bash
# Check that a Hailo15 target has everything drone_follow_h15 needs.
# Read-only: changes nothing on the target. Exit code 1 if anything FAILs.
#
# Usage:
#   ./check_board.sh [root@<ip>]

set -e
source "$(dirname "$0")/common.sh"

echo "=== Checking $TARGET ==="
target_ssh 'sh -s' <<'REMOTE'
fails=0
ok()   { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails + 1)); }
pyimp() { python3 -c "import $1" 2>/dev/null; }

echo "[image]"
if [ -f /etc/build-info ]; then
    ok "build: $(grep -E '^(BUILD_TIME|DISTRO_VERSION)' /etc/build-info | tr '\n' ' ')"
fi
command -v mavsdk_server >/dev/null && ok "mavsdk_server: $(command -v mavsdk_server)" \
    || bad "mavsdk_server missing (image not built with the phys-ai kas config)"
# The image's python3-protobuf (3.x) lacks runtime_version, which python3-mavsdk's
# generated code imports; drone_follow_h15.py stubs it at startup. Check the same way.
python3 -c "
import types, google.protobuf as pb
rv = types.ModuleType('runtime_version'); rv.ValidateProtobufRuntimeVersion = lambda *a, **k: None
rv.Domain = type('Domain', (), {'PUBLIC': 1})(); pb.runtime_version = rv
import mavsdk" 2>/dev/null && ok "python: mavsdk" || bad "python: mavsdk missing (image not built with the phys-ai kas config?)"
for m in pymavlink hailo_platform gi numpy google.protobuf; do
    pyimp "$m" && ok "python: $m" || bad "python: $m missing (image not built with the phys-ai kas config?)"
done
pyimp zmq && ok "python: zmq $(python3 -c 'import zmq; print(zmq.__version__)')" \
    || bad "python: zmq missing (needed for --native-pipeline; run install_pyzmq.sh)"

echo "[hailo]"
hailortcli fw-control identify >/dev/null 2>&1 && ok "hailortcli fw-control identify" \
    || bad "hailortcli fw-control identify failed"
HEF=/home/root/apps/shared/resources/hailo_yolov8s_384_640.hef
[ -f "$HEF" ] && ok "model: $HEF" || bad "model missing: $HEF"

echo "[camera]"
if [ -e /etc/imaging/cfg/medialib_configs ]; then
    ok "sensor config: $(readlink -f /etc/imaging/cfg/medialib_configs)"
else
    bad "no /etc/imaging/cfg/medialib_configs (run setup_hailo_sensor.sh)"
fi

echo "[app]"
[ -f /home/root/robot_follow/drone_follow_h15.py ] && ok "app: /home/root/robot_follow" \
    || bad "app missing (run install_app.sh)"
[ -f /home/root/robot_follow/ui/build/index.html ] && ok "web UI build" \
    || bad "web UI build missing (run build_ui.sh + install_app.sh)"
[ -x /home/root/native_pipeline/df_native_pipeline ] && ok "native pipeline binary" \
    || bad "native pipeline binary missing (run install_native.sh)"

echo "[service]"
if [ -x /etc/init.d/drone-follow ]; then
    ok "init script installed"
    [ -e /etc/rcS.d/S99drone-follow ] && ok "starts at boot" || warn "not enabled at boot (no /etc/rcS.d/S99drone-follow)"
    ARGS=$(sed -n 's/^DRONE_FOLLOW_ARGS=//p' /etc/default/drone-follow 2>/dev/null | tail -1)
    echo "        DRONE_FOLLOW_ARGS=$ARGS"
    case "$ARGS" in
        *--native-pipeline*) ok "service uses the native pipeline" ;;
        *) warn "service args have no --native-pipeline (runs the older Python pipeline)" ;;
    esac
else
    warn "service not installed (run install_service.sh)"
fi

echo "[flight controller]"
[ -e /dev/ttyACM0 ] && ok "/dev/ttyACM0 present" || warn "no /dev/ttyACM0 (FC not connected; fine for --dry-run / SITL)"

echo
if [ "$fails" -eq 0 ]; then echo "All required checks passed."; else echo "$fails check(s) FAILED."; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
REMOTE
