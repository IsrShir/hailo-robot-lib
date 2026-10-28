#!/bin/bash
# Install a drone-follow runtime bundle (from build_bundle.sh) onto a Hailo15
# board running a formal VPU release image, then configure the sensor and verify.
#
# Usage:
#   ./install_bundle.sh <bundle.tar.gz>                  # target root@10.0.0.1
#   ./install_bundle.sh <bundle.tar.gz> root@<ip>
#   TARGET=root@<ip> ./install_bundle.sh <bundle.tar.gz>
#   ./install_bundle.sh <bundle.tar.gz> root@<ip> --reboot   # reboot after sensor setup
#
# On the shuttle itself, pass SSH_OPTS (see common.sh). From another host, use an
# ~/.ssh/config alias with ProxyJump (e.g. Host h15-160 / HostName 10.0.0.1 /
# User root / ProxyJump hailo@10.41.74.160) and pass that alias as the target.
#
# What it does:
#   1. Preflight: the board must match the bundle (arch, Python, libhailort md5)
#      and have room for it. Nothing is changed if this fails.
#   2. Stops the drone-follow service if present, removes a previous bundle.
#   3. Unpacks the bundle under / (new paths only; no image file is overwritten).
#   4. Runs setup_hailo_sensor.sh (detects 15L/15H and the IMX sensor).
#   5. Verifies imports, mavsdk_server, the HEF, VDevice and the native binary.
# App code and the boot service are installed separately (install.sh).

set -eEuo pipefail

BUNDLE="${1:?usage: $0 <bundle.tar.gz> [root@<ip>] [--reboot]}"
TARGET=${2:-${TARGET:-root@10.0.0.1}}
REBOOT=0
[ "${3:-}" = "--reboot" ] && REBOOT=1
[ -f "$BUNDLE" ] || { echo "ERROR: bundle not found: $BUNDLE" >&2; exit 1; }
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "$TARGET"

# Read the manifest out of the bundle.
MANIFEST=$(tar xzOf "$BUNDLE" ./usr/share/drone-follow/bundle-manifest.txt)
mf() { echo "$MANIFEST" | sed -n "s/^$1=//p" | head -1; }
PY_VER=$(mf python)
HRT_VER=$(mf hailort)
HRT_MD5=$(mf libhailort_md5)
SITE="/usr/lib/python${PY_VER}/site-packages"
NEED_KB=$(( $(gzip -l "$BUNDLE" | tail -1 | awk '{print $2}') / 1024 * 12 / 10 ))

echo "===== Installing bundle on $TARGET ====="
echo "  bundle: $(basename "$BUNDLE")"
echo "  built for: $(mf release) / $(mf machine), Python $PY_VER, HailoRT $HRT_VER"

# --- 1. Preflight -------------------------------------------------------------
echo "[1/5] Preflight checks..."
trap 'echo "ABORTED: preflight failed, nothing was changed on $TARGET" >&2' ERR
target_ssh "sh -s" <<EOF
fail=0
[ "\$(uname -m)" = aarch64 ] || { echo "  FAIL arch is \$(uname -m)"; fail=1; }
pv=\$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
[ "\$pv" = "$PY_VER" ] && echo "  ok   Python \$pv" || { echo "  FAIL Python is '\$pv', bundle needs $PY_VER"; fail=1; }
lib=/usr/lib/libhailort.so.$HRT_VER
if [ -f \$lib ]; then
    m=\$(md5sum \$lib | cut -d' ' -f1)
    [ "\$m" = "$HRT_MD5" ] && echo "  ok   libhailort $HRT_VER matches the bundle's SDK" \
        || { echo "  FAIL \$lib md5 \$m differs from the bundle's SDK ($HRT_MD5): wrong release?"; fail=1; }
else
    echo "  FAIL \$lib not found: board runs a different HailoRT than the bundle"; fail=1
fi
avail=\$(df -k / | tail -1 | awk '{print \$4}')
[ "\$avail" -ge $NEED_KB ] && echo "  ok   \$((avail/1024)) MB free on /" \
    || { echo "  FAIL only \$((avail/1024)) MB free on /, need $((NEED_KB/1024)) MB"; fail=1; }
echo "  info SoC: \$(cat /sys/devices/soc0/machine 2>/dev/null || echo unknown)"
exit \$fail
EOF

trap 'echo "FAILED at the step above; see output" >&2' ERR

# --- 2. Stop service, remove previous bundle --------------------------------------
echo "[2/5] Stopping drone-follow (if installed) and removing a previous bundle..."
target_ssh "sh -s" <<EOF
[ -x /etc/init.d/drone-follow ] && /etc/init.d/drone-follow stop >/dev/null 2>&1 || true
old=/usr/share/drone-follow/bundle-manifest.txt
if [ -f \$old ]; then
    echo "  removing previous bundle: \$(sed -n 's/^release=//p' \$old) built \$(sed -n 's/^built=//p' \$old)"
    sed -n 's/^site=//p' \$old | while read -r e; do [ -n "\$e" ] && rm -rf "$SITE/\$e"; done
fi
EOF

# --- 3. Unpack ----------------------------------------------------------------------
echo "[3/5] Unpacking bundle under / ..."
target_ssh "tar xzf - -C /" < "$BUNDLE"

# --- 4. Sensor ------------------------------------------------------------------------
echo "[4/5] Configuring sensor (setup_hailo_sensor.sh)..."
target_ssh "sh -s" <<'EOF'
setup_hailo_sensor.sh | sed 's/^/  /'
cfg=/etc/imaging/cfg/medialib_configs/face_landmarks_medialib_config.json
[ -f $cfg ] && echo "  ok   $(readlink /etc/imaging/cfg/medialib_configs)" \
    || { echo "  FAIL $cfg missing after sensor setup"; exit 1; }
EOF

# --- 5. Verify ----------------------------------------------------------------------------
echo "[5/5] Verifying..."
target_ssh "sh -s" <<'EOF'
fail=0
python3 - <<'PY' || fail=1
import importlib
for m in ("numpy", "zmq", "grpc", "google.protobuf", "mavsdk", "hailo_platform"):
    try:
        mod = importlib.import_module(m)
        print("  ok   import %-16s %s" % (m, getattr(mod, "__version__", "")))
    except Exception as e:
        print("  FAIL import %-16s %s" % (m, e)); raise SystemExit(1)
PY
srv=$(python3 -c 'import mavsdk, os; print(os.path.join(os.path.dirname(mavsdk.__file__), "bin", "mavsdk_server"))')
[ -x "$srv" ] && echo "  ok   mavsdk_server at $srv" || { echo "  FAIL mavsdk_server not executable at $srv"; fail=1; }
hef=""
for h in /home/root/apps/shared/resources/hailo_yolov8s_384_640.hef /home/root/apps/shared/resources/hailo_yolov8n_384_640.hef; do
    [ -f $h ] && { hef=$h; break; }
done
if [ -n "$hef" ]; then
    python3 - "$hef" <<'PY' || fail=1
import sys
from hailo_platform import HEF, VDevice
hef = HEF(sys.argv[1])
print("  ok   HEF %s: %s" % (sys.argv[1].rsplit("/", 1)[-1], hef.get_network_group_names()))
with VDevice() as vd:
    vd.create_infer_model(sys.argv[1])
    print("  ok   VDevice + create_infer_model")
PY
else
    echo "  FAIL no yolov8 HEF in /home/root/apps/shared/resources"; fail=1
fi
/home/root/native_pipeline/df_native_pipeline --help >/dev/null 2>&1 \
    && echo "  ok   df_native_pipeline loads (--help)" \
    || { echo "  FAIL df_native_pipeline --help failed (missing library?)"; fail=1; }
exit $fail
EOF

echo ""
echo "===== Bundle installed ====="
if [ "$REBOOT" = 1 ]; then
    echo "Rebooting $TARGET so the media server picks up the sensor config..."
    target_ssh "reboot" || true
    # Wait for it to go DOWN first: right after `reboot` ssh still answers for a few
    # seconds, and the next step would run on the old system and then lose its board.
    for _ in $(seq 1 60); do target_ssh -o ConnectTimeout=3 true 2>/dev/null || break; sleep 1; done
    for _ in $(seq 1 60); do sleep 5; target_ssh -o ConnectTimeout=5 true 2>/dev/null && break; done
    if target_ssh true 2>/dev/null; then
        echo "  ok   $TARGET is back ($(target_ssh 'uptime -p'))"
    else
        echo "ERROR: $TARGET did not come back within 5 min after the reboot" >&2; exit 1
    fi
else
    echo "Reboot the board before running the app so the media server picks up the sensor config."
fi
echo "Next: scripts/h15_boot/build_ui.sh && scripts/h15_boot/install_app.sh $TARGET"
echo "      (not install.sh: on a formal image the bundle already provides pyzmq and the native binary)."
