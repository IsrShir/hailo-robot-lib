#!/bin/bash
# Stage a VPU release's flash files on the shuttle and point TFTP at them.
#
# Copies the files u-boot's "Board Init" flow needs (the same set as
# flash_board.py) from ystor, checks each one's md5 against ystor, then points
# /srv/tftp at the staged folder and restarts tftpd-hpa (sudo).
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_stage.sh --release vpu-stability-v1.13.0 --machine hailo15l-sbc
#   ... --no-tftp      stage and verify only; print the TFTP commands instead of running them
#
# Re-running skips files that are already staged with the right md5.
# The full rootfs .ext4 is NOT staged: u-boot can't TFTP it on 2 GB boards
# ("trying to overwrite reserved memory"); Board Init writes the rootfs from the .swu.

set -euo pipefail
: "${YSTOR:?source scripts/h15_boot/shuttle.env first}"

RELEASE=""; MACHINE=""; DO_TFTP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE="$2"; shift 2 ;;
        --machine) MACHINE="$2"; shift 2 ;;
        --no-tftp) DO_TFTP=0; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$MACHINE" ] || { echo "ERROR: --release and --machine are required" >&2; exit 1; }

case "$MACHINE" in
    hailo15l-sbc) SOC=hailo15l ;;
    hailo15-sbc|hailo15-sbc-rev3-1) SOC=hailo15 ;;
    *) echo "ERROR: unsupported machine $MACHINE" >&2; exit 1 ;;
esac

FILES=(
    "${SOC}_scu_bl.bin" scu_bl_cfg_a.bin scu_bl_cfg_b.bin
    u-boot-spl.bin u-boot-initial-env u-boot.dtb.signed u-boot-tfa.itb
    "${SOC}_scu_fw.bin" "${SOC}_uart_recovery_fw.bin" customer_certificate.bin
    fitImage "swupdate-image-${MACHINE}.ext4.gz" "hailo-update-image-${MACHINE}.swu"
)
SRC="${YSTOR_BKC}/${RELEASE}/hailo-yocto-validation/build/tmp/deploy/images/${MACHINE}"
DEST="${H15_IMAGES}/${RELEASE}/${MACHINE}"

# ystor's login shell is tcsh, so every remote command goes through bash -s.
ystor() { ssh -o BatchMode=yes "$YSTOR" "bash -s"; }

echo "===== Staging $RELEASE / $MACHINE ====="
echo "  from: $YSTOR:$SRC"
echo "  to:   $DEST"

echo "[1/3] Checking the release on ystor..."
# "<md5> <name>" per file (symlinks followed); a missing file prints "MISSING <name>".
REMOTE_MD5=$(ystor <<EOF
cd "$SRC" || exit 3
for f in ${FILES[*]}; do
    if [ -e "\$f" ]; then echo "\$(md5sum < "\$f" | cut -d' ' -f1) \$f"; else echo "MISSING \$f"; fi
done
EOF
) || { echo "ERROR: $SRC not found on ystor" >&2; exit 1; }
if echo "$REMOTE_MD5" | grep -q '^MISSING'; then
    echo "ERROR: the release is missing flash files:" >&2
    echo "$REMOTE_MD5" | sed -n 's/^MISSING /  /p' >&2
    exit 1
fi
echo "  all ${#FILES[@]} files present"
SWU_BUILD=$(echo "readlink ${SRC}/hailo-update-image-${MACHINE}.swu" | ystor || true)
[ -n "$SWU_BUILD" ] && echo "  update image: $SWU_BUILD"

echo "[2/3] Copying and verifying..."
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    want=$(echo "$REMOTE_MD5" | awk -v f="$f" '$2 == f {print $1}')
    if [ -f "$DEST/$f" ] && [ "$(md5sum < "$DEST/$f" | cut -d' ' -f1)" = "$want" ]; then
        echo "  ok   $f (already staged)"
        continue
    fi
    scp -q -o BatchMode=yes "$YSTOR:$SRC/$f" "$DEST/$f.part"
    got=$(md5sum < "$DEST/$f.part" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "ERROR: md5 mismatch for $f ($got != $want)" >&2; rm -f "$DEST/$f.part"; exit 1; }
    mv "$DEST/$f.part" "$DEST/$f"
    echo "  ok   $f"
done
echo "$REMOTE_MD5" > "$DEST/MD5SUMS"
chmod -R a+rX "$DEST"
# tftpd runs as user tftp, so every directory above DEST must be traversable.
d="$DEST"
while [ "$d" != "/" ]; do
    [ -x "$d" ] && [ "$(stat -c %A "$d" | cut -c10)" = x ] || echo "  WARN $d is not world-traversable; tftpd (user tftp) can't read the files"
    d=$(dirname "$d")
done

OLD=$(readlink /srv/tftp 2>/dev/null || echo "(not a symlink)")
TFTP_CMDS="sudo ln -sfn $DEST /srv/tftp && sudo systemctl restart tftpd-hpa"
echo "[3/3] TFTP..."
echo "  /srv/tftp now -> $OLD"
if [ "$DO_TFTP" = 1 ]; then
    # tftpd --secure chroots into /srv/tftp when it starts, so it must restart
    # to see a new symlink target.
    sudo -n ln -sfn "$DEST" /srv/tftp && sudo -n systemctl restart tftpd-hpa \
        || { echo "ERROR: sudo failed; run this yourself: $TFTP_CMDS" >&2; exit 1; }
    systemctl is-active --quiet tftpd-hpa && echo "  ok   /srv/tftp -> $DEST, tftpd-hpa restarted" \
        || { echo "ERROR: tftpd-hpa is not active after restart" >&2; exit 1; }
    echo "  revert: sudo ln -sfn $OLD /srv/tftp && sudo systemctl restart tftpd-hpa"
else
    echo "  not changed (--no-tftp). To serve this release:"
    echo "    $TFTP_CMDS"
fi
echo ""
echo "===== Staged ====="
