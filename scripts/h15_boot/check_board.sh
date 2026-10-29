#!/bin/bash
# Check that a Hailo15 target has everything drone_follow_h15 needs.
# Read-only: changes nothing on the target. Exit code 1 if anything FAILs.
#
# Usage:
#   ./check_board.sh [root@<ip>]
#   ./check_board.sh --runtime [root@<ip>]   # only what the bundle provides (no app / service);
#                                            # install_bundle.sh runs this as its verify step

set -e
RUNTIME_ONLY=0
if [ "${1:-}" = --runtime ]; then RUNTIME_ONLY=1; shift; fi
source "$(dirname "$0")/common.sh" "$@"

echo "=== Checking $TARGET$([ "$RUNTIME_ONLY" = 1 ] && echo " (runtime only)") ==="
target_ssh "RUNTIME_ONLY=$RUNTIME_ONLY sh -s" <<'REMOTE'
fails=0
ok()   { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails + 1)); }
pyimp() { python3 -c "import $1" 2>/dev/null; }

echo "[image]"
if [ -f /etc/build-info ]; then
    ok "build: $(grep -E '^(BUILD_TIME|DISTRO_VERSION)' /etc/build-info | tr '\n' ' ')"
fi
if [ -f /usr/share/drone-follow/bundle-manifest.txt ]; then
    ok "formal image + drone-follow bundle: $(sed -n 's/^release=//p' /usr/share/drone-follow/bundle-manifest.txt), built $(sed -n 's/^built=//p' /usr/share/drone-follow/bundle-manifest.txt)"
fi
# mavsdk_server: on PATH in the phys-ai image, inside the mavsdk package with the bundle.
SRV=$(command -v mavsdk_server || python3 -c 'import mavsdk, os; print(os.path.join(os.path.dirname(mavsdk.__file__), "bin", "mavsdk_server"))' 2>/dev/null)
[ -n "$SRV" ] && [ -x "$SRV" ] && ok "mavsdk_server: $SRV" \
    || bad "mavsdk_server missing (phys-ai image, or install_bundle.sh on a formal image)"
# The image's python3-protobuf (3.x) lacks runtime_version, which python3-mavsdk's
# generated code imports; drone_follow_h15.py stubs it at startup. Check the same way.
python3 -c "
import types, google.protobuf as pb
rv = types.ModuleType('runtime_version'); rv.ValidateProtobufRuntimeVersion = lambda *a, **k: None
rv.Domain = type('Domain', (), {'PUBLIC': 1})(); pb.runtime_version = rv
import mavsdk" 2>/dev/null && ok "python: mavsdk" || bad "python: mavsdk missing (phys-ai image, or install_bundle.sh on a formal image)"
for m in hailo_platform gi numpy google.protobuf; do
    pyimp "$m" && ok "python: $m" || bad "python: $m missing (phys-ai image, or install_bundle.sh on a formal image)"
done
# The app doesn't import pymavlink; only some tools do.
pyimp pymavlink && ok "python: pymavlink" || warn "python: pymavlink missing (not needed by the app)"
pyimp zmq && ok "python: zmq $(python3 -c 'import zmq; print(zmq.__version__)')" \
    || bad "python: zmq missing (needed for --native-pipeline; run install_bundle.sh)"

echo "[hailo]"
hailortcli fw-control identify >/dev/null 2>&1 && ok "hailortcli fw-control identify" \
    || bad "hailortcli fw-control identify failed"
HEF=/home/root/apps/shared/resources/hailo_yolov8s_384_640.hef
if [ ! -f "$HEF" ]; then
    bad "model missing: $HEF"
elif pgrep -f '^python3 -m robot_follow' >/dev/null; then
    ok "model: $HEF (load not tried: the app is running and holds the device)"
elif python3 - "$HEF" >/dev/null 2>&1 <<'PY'
import sys
from hailo_platform import HEF, VDevice
HEF(sys.argv[1])
with VDevice() as vd:
    vd.create_infer_model(sys.argv[1])
PY
then ok "model loads on the device: $HEF (HEF + VDevice)"
else bad "model doesn't load on the device: $HEF (pyhailort vs HailoRT mismatch?)"
fi
[ -x /home/root/native_pipeline/df_native_pipeline ] && /home/root/native_pipeline/df_native_pipeline --help >/dev/null 2>&1 \
    && ok "native pipeline binary loads" || bad "native pipeline binary missing or doesn't load (run install_bundle.sh)"

echo "[camera]"
if [ -e /etc/imaging/cfg/medialib_configs ]; then
    ok "sensor config: $(readlink -f /etc/imaging/cfg/medialib_configs)"
else
    bad "no /etc/imaging/cfg/medialib_configs (run setup_hailo_sensor.sh)"
fi

echo "[flight controller]"
{ [ -d /sys/bus/usb/drivers/cdc_acm ] || modinfo -n cdc_acm >/dev/null 2>&1; } && ok "USB serial driver cdc_acm" \
    || bad "no cdc_acm driver: a USB FC gets no /dev/ttyACM0 (v1.12.1: install a current bundle)"
[ -e /dev/ttyACM0 ] && ok "/dev/ttyACM0 present" || warn "no /dev/ttyACM0 (FC not connected; fine for --dry-run / SITL)"

if [ "$RUNTIME_ONLY" != 1 ]; then
echo "[app]"
[ -f /home/root/robot_follow/drone_follow_h15.py ] && ok "app: /home/root/robot_follow" \
    || bad "app missing (run install_app.sh)"
[ -f /home/root/robot_follow/ui/build/index.html ] && ok "web UI build" \
    || bad "web UI build missing (run build_ui.sh + install_app.sh)"

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
fi

echo
if [ "$fails" -eq 0 ]; then echo "All required checks passed."; else echo "$fails check(s) FAILED."; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
REMOTE
