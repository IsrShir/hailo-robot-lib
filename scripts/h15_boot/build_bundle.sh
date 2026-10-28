#!/bin/bash
# Build the runtime bundle that lets a formal VPU release image run drone-follow.
#
# A formal release image (e.g. vpu-stability-v1.13.0) is built without the
# phys-ai packagegroup, so it lacks numpy, pyhailort, mavsdk (+ mavsdk_server),
# grpcio, protobuf and pyzmq. Its HailoRT / media library versions also differ
# from the ones df_native_pipeline was last built against. This script builds
# all of that on the build host, from the release's own SDK, into one tarball
# that install_bundle.sh unpacks on the board. Nothing here touches a board.
#
# Usage:
#   ./build_bundle.sh --release vpu-stability-v1.13.0 --machine hailo15l-sbc
#
# Options:
#   --release NAME     VPU release folder on ystor (required)
#   --machine NAME     hailo15l-sbc | hailo15-sbc | hailo15-sbc-rev3-1 (required)
#   --work DIR         Work dir for SDK, sources, wheels (default $H15_WORK, else ~/h15_bundle_work)
#   --sdk-dir DIR      Use an already-installed SDK instead of fetching one
#   --native-ref REF   Git ref holding robot_follow/native_pipeline (default HEAD,
#                      so the binary matches the app code install_app.sh syncs)
#   --ystor HOST       Release store (default hailo@192.168.12.21)
#
# Output:
#   <work>/<release>/<machine>/drone-follow-bundle-<release>-<machine>.tar.gz
#   Layout is relative to / on the board:
#     usr/lib/python3.X/site-packages/...           Python packages
#     home/root/native_pipeline/df_native_pipeline  native pipeline binary
#     usr/share/drone-follow/bundle-manifest.txt    what was built, from what

set -eEuo pipefail

RELEASE=""
MACHINE=""
WORK="${H15_WORK:-${HOME}/h15_bundle_work}"
SDK_DIR=""
NATIVE_REF="HEAD"
YSTOR="${YSTOR:-hailo@192.168.12.21}"
YSTOR_BKC="/mnt/ystor/bkc"

while [ $# -gt 0 ]; do
    case "$1" in
        --release)    RELEASE="$2"; shift 2 ;;
        --machine)    MACHINE="$2"; shift 2 ;;
        --work)       WORK="$2"; shift 2 ;;
        --sdk-dir)    SDK_DIR="$2"; shift 2 ;;
        --native-ref) NATIVE_REF="$2"; shift 2 ;;
        --ystor)      YSTOR="$2"; shift 2 ;;
        -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$MACHINE" ] || { echo "ERROR: --release and --machine are required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${WORK}/${RELEASE}/${MACHINE}"
mkdir -p "$OUT"

# PyPI packages, pinned to the versions the reference phys-ai image ran where a
# matching aarch64 wheel exists. mavsdk 2.8.4 bundles a static mavsdk_server
# v2.12.10 at mavsdk/bin/, which is where the app looks for it. pymavlink and
# pyserial are left out: the app doesn't import them.
PYPI_PKGS=(
    "numpy==1.22.3"
    "grpcio==1.75.0"
    "protobuf==3.20.3"
    "mavsdk==2.8.4"
    "aiogrpc==1.8"
    "pyzmq==27.2.0"
    "six==1.16.0"
    "typing-extensions==4.16.0"
)

# ystor's login shell is tcsh, so every remote command goes through bash -s.
ystor() { ssh -o BatchMode=yes "$YSTOR" "bash -s"; }

echo "===== Building drone-follow bundle: $RELEASE / $MACHINE ====="

# --- 1. SDK -------------------------------------------------------------------
if [ -z "$SDK_DIR" ]; then
    SDK_DIR="${OUT}/sdk"
    if [ ! -f "${SDK_DIR}/environment-setup-armv8a-poky-linux" ]; then
        SDK_REMOTE_DIR="${YSTOR_BKC}/${RELEASE}/hailo-yocto-validation/build/tmp/deploy/sdk"
        SDK_NAME=$(echo "ls ${SDK_REMOTE_DIR}" | ystor | grep -E "^poky-glibc-x86_64-core-image-hailo-dev-armv8a-${MACHINE}-toolchain-.*\.sh$" | head -1)
        [ -n "$SDK_NAME" ] || { echo "ERROR: no SDK for $MACHINE in $SDK_REMOTE_DIR" >&2; exit 1; }
        echo "[1/6] Fetching SDK $SDK_NAME (~3 GB)..."
        scp -q "${YSTOR}:${SDK_REMOTE_DIR}/${SDK_NAME}" "${OUT}/${SDK_NAME}"
        echo "      Installing SDK into $SDK_DIR..."
        sh "${OUT}/${SDK_NAME}" -y -d "$SDK_DIR" >/dev/null
        rm -f "${OUT}/${SDK_NAME}"
    else
        echo "[1/6] SDK already installed at $SDK_DIR"
    fi
else
    echo "[1/6] Using SDK at $SDK_DIR"
fi

# The SDK env script references unset variables, so relax -u while sourcing.
set +u
# shellcheck disable=SC1091
. "${SDK_DIR}/environment-setup-armv8a-poky-linux" >/dev/null
set -u
SYSROOT="$SDKTARGETSYSROOT"
NATIVE_PY=$(ls "${OECORE_NATIVE_SYSROOT}"/usr/bin/python3.[0-9]* | grep -E 'python3\.[0-9]+$' | head -1)
TOOLCHAIN_CMAKE="${OECORE_NATIVE_SYSROOT}/usr/share/cmake/OEToolchainConfig.cmake"

# Versions come from the SDK sysroot, i.e. from the release itself.
HRT_LIB=$(ls "${SYSROOT}"/usr/lib/libhailort.so.*.*.* | head -1)
HRT_VER="${HRT_LIB##*libhailort.so.}"
PY_VER=$(basename "$(ls -d "${SYSROOT}"/usr/include/python3.[0-9]* | head -1)" | sed 's/^python//')
PY_TAG="cp${PY_VER/./}"
HRT_MD5=$(md5sum "$HRT_LIB" | cut -d' ' -f1)
echo "      HailoRT $HRT_VER (md5 $HRT_MD5), Python $PY_VER"

# --- 2. Host build tools --------------------------------------------------------
HOSTVENV="${WORK}/hostvenv"
if [ ! -x "${HOSTVENV}/bin/pip" ]; then
    echo "[2/6] Creating host venv for pybind11 / scikit-build-core / meson..."
    python3 -m venv "$HOSTVENV"
else
    echo "[2/6] Host venv at $HOSTVENV"
fi
# `pip wheel -C` (--config-settings) needs pip >= 23.1; Ubuntu 22.04's venv ships 23.0.x.
# Upgrade every run, so a venv left by an older version of this script is fixed too.
# setuptools + wheel: hailort <= 5.3 builds its bindings with a legacy setup.py.
"${HOSTVENV}/bin/pip" install -q --disable-pip-version-check --upgrade "pip>=23.1" \
    "pybind11>=2.13.6,<3" scikit-build-core meson setuptools wheel

# --- 3. pyhailort ---------------------------------------------------------------
# Not in the formal image. Built from the public hailort tag that matches the
# SDK's libhailort, linked against the SDK's libhailort (the same file as in the
# image). PYTHON_EXECUTABLE is the SDK's host python of the same version as the
# target, and the target's Python headers go first on the include path.
echo "[3/6] Building pyhailort $HRT_VER for $PY_TAG..."
HRT_SRC="${WORK}/src/hailort-v${HRT_VER}"
[ -d "$HRT_SRC" ] || git clone -q --depth 1 --branch "v${HRT_VER}" https://github.com/hailo-ai/hailort.git "$HRT_SRC" 2>/dev/null
PYH_DIR="${HRT_SRC}/hailort/libhailort/bindings/python/platform"
rm -rf "${PYH_DIR}"/build "${PYH_DIR}"/build.* "${PYH_DIR}/dist"
if [ -f "${PYH_DIR}/pyproject.toml" ]; then
# hailort >= 5.4: scikit-build-core, cross settings through CMAKE_ARGS.
(
    cd "$PYH_DIR"
    export CXXFLAGS="${CXXFLAGS:-} -isystem ${SYSROOT}/usr/include/python${PY_VER}"
    export CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_CMAKE} \
        -DLIBHAILORT_PATH=${SYSROOT}/usr/lib/libhailort.so \
        -DHAILORT_INCLUDE_DIR=${SYSROOT}/usr/include \
        -DPYBIND11_PYTHON_VERSION=${PY_VER} \
        -Dpybind11_DIR=$("${HOSTVENV}/bin/python" -m pybind11 --cmakedir) \
        -DPYTHON_EXECUTABLE=${NATIVE_PY} \
        -DPYTHON_INCLUDE_DIR=${SYSROOT}/usr/include/python${PY_VER} \
        -DPYTHON_LIBRARY=${SYSROOT}/usr/lib/libpython${PY_VER}.so"
    "${HOSTVENV}/bin/pip" wheel . -w dist/ --no-build-isolation --no-deps \
        -C "wheel.tags=${PY_TAG}-${PY_TAG}-linux_aarch64" > "${OUT}/pyhailort_build.log" 2>&1
) || { echo "ERROR: pyhailort build failed, see ${OUT}/pyhailort_build.log" >&2; exit 1; }
else
# hailort <= 5.3: legacy setup.py. Its build_ext runs CMake itself and takes the
# cross settings from environment variables; --plat-name picks the target arch.
# It also takes the Python version (PYBIND11_PYTHON_VERSION, wheel tag) from the
# interpreter running it, so the host venv must be the target's Python version.
HOST_PY_VER=$("${HOSTVENV}/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[ "$HOST_PY_VER" = "$PY_VER" ] || { echo "ERROR: hailort $HRT_VER builds pyhailort with setup.py, which needs host Python $PY_VER (venv has $HOST_PY_VER). Recreate $HOSTVENV with python$PY_VER." >&2; exit 1; }
(
    cd "$PYH_DIR"
    export CXXFLAGS="${CXXFLAGS:-} -isystem ${SYSROOT}/usr/include/python${PY_VER}"
    export CMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_CMAKE"
    export LIBHAILORT_PATH="${SYSROOT}/usr/lib/libhailort.so"
    export HAILORT_INCLUDE_DIR="${SYSROOT}/usr/include"
    export PYTHON_EXECUTABLE="$NATIVE_PY"
    export PYTHON_INCLUDE_DIRS="${SYSROOT}/usr/include/python${PY_VER}"
    export PYTHON_LIBRARY="${SYSROOT}/usr/lib/libpython${PY_VER}.so"
    "${HOSTVENV}/bin/python" setup.py bdist_wheel --plat-name linux_aarch64 -d dist/ \
        > "${OUT}/pyhailort_build.log" 2>&1
) || { echo "ERROR: pyhailort build failed, see ${OUT}/pyhailort_build.log" >&2; exit 1; }
fi
PYH_WHEEL=$(ls "${PYH_DIR}"/dist/hailort-*.whl)

# Every hailort symbol the extension needs must be exported by the release's libhailort.
PYH_SO_DIR=$(mktemp -d)
unzip -qo "$PYH_WHEEL" 'hailo_platform/pyhailort/_pyhailort*.so' -d "$PYH_SO_DIR"
UNRESOLVED=$(comm -23 \
    <("$NM" -D --undefined-only "$PYH_SO_DIR"/hailo_platform/pyhailort/_pyhailort*.so | awk '{print $2}' | grep -i hailo | sort -u) \
    <("$NM" -D --defined-only "$HRT_LIB" | awk '{print $3}' | sort -u) | wc -l)
rm -rf "$PYH_SO_DIR"
[ "$UNRESOLVED" = 0 ] || { echo "ERROR: $UNRESOLVED hailort symbols in pyhailort are not exported by $HRT_LIB" >&2; exit 1; }
echo "      $(basename "$PYH_WHEEL") (all hailort symbols resolve)"

# --- 4. df_native_pipeline -------------------------------------------------------
echo "[4/6] Building df_native_pipeline from $NATIVE_REF..."
NP_SRC="${OUT}/native_src"
rm -rf "$NP_SRC" && mkdir -p "$NP_SRC"
git -C "$REPO_ROOT" archive "$NATIVE_REF" robot_follow/native_pipeline | tar x -C "$NP_SRC"
NATIVE_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short "$NATIVE_REF")
TOOLCHAIN_DIR="$SDK_DIR" "${NP_SRC}/robot_follow/native_pipeline/build.sh" --clean > "${OUT}/native_build.log" 2>&1 \
    || { echo "ERROR: native build failed, see ${OUT}/native_build.log" >&2; exit 1; }
NP_BIN="${NP_SRC}/robot_follow/native_pipeline/build/df_native_pipeline"
echo "      df_native_pipeline built ($NATIVE_COMMIT), needs: $("$READELF" -d "$NP_BIN" | grep NEEDED | grep -oE '\[[^]]+\]' | tr -d '[]' | tr '\n' ' ')"

# --- 5. PyPI wheels ---------------------------------------------------------------
echo "[5/6] Downloading PyPI wheels for $PY_TAG aarch64..."
WHEELS="${OUT}/wheels"
rm -rf "$WHEELS" && mkdir -p "$WHEELS"
# Host venv pip: after sourcing the SDK env, plain python3 is the SDK's (no pip).
"${HOSTVENV}/bin/pip" download -q --no-deps --only-binary=:all: -d "$WHEELS" \
    --platform manylinux2014_aarch64 --platform manylinux_2_17_aarch64 \
    --platform manylinux_2_28_aarch64 --platform any \
    --python-version "$PY_VER" --implementation cp --abi "$PY_TAG" --abi abi3 --abi none \
    "${PYPI_PKGS[@]}"
cp "$PYH_WHEEL" "$WHEELS/"

# --- 6. Stage and pack -------------------------------------------------------------
echo "[6/6] Packing bundle..."
STAGE="${OUT}/stage"
SITE="${STAGE}/usr/lib/python${PY_VER}/site-packages"
rm -rf "$STAGE" && mkdir -p "$SITE" "${STAGE}/home/root/native_pipeline" "${STAGE}/usr/share/drone-follow"
for w in "$WHEELS"/*.whl; do unzip -qo "$w" -d "$SITE"; done
rm -rf "${SITE}/hailo_tutorials"
chmod 755 "${SITE}/mavsdk/bin/mavsdk_server"
install -m 755 "$NP_BIN" "${STAGE}/home/root/native_pipeline/df_native_pipeline"

MANIFEST="${STAGE}/usr/share/drone-follow/bundle-manifest.txt"
{
    echo "release=$RELEASE"
    echo "machine=$MACHINE"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "python=$PY_VER"
    echo "hailort=$HRT_VER"
    echo "libhailort_md5=$HRT_MD5"
    echo "native_ref=$NATIVE_REF@$NATIVE_COMMIT"
    for w in "$WHEELS"/*.whl; do echo "wheel=$(basename "$w")"; done
} > "$MANIFEST"
# Top-level site-packages entries, so install_bundle.sh can remove a previous bundle cleanly.
ls "$SITE" | sed "s|^|site=|" >> "$MANIFEST"

BUNDLE="${OUT}/drone-follow-bundle-${RELEASE}-${MACHINE}.tar.gz"
tar czf "$BUNDLE" --owner=0 --group=0 -C "$STAGE" .
echo ""
echo "===== Bundle ready ====="
echo "  $BUNDLE ($(du -h "$BUNDLE" | cut -f1), $(du -sh "$STAGE" | cut -f1) unpacked)"
echo "  Install: scripts/h15_boot/install_bundle.sh $BUNDLE [root@<ip>]"
