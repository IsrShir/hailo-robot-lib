#!/bin/bash
# Stage an H15 image's flash files on the shuttle and point TFTP at them.
#
# Copies the files u-boot's "Board Init" flow needs (the same set as
# flash_board.py) from a VPU release on ystor or from any image folder (e.g. a
# phys-ai dev build or a backup), checks each one's md5 against the source, then
# points /srv/tftp at the staged folder and restarts tftpd-hpa (sudo).
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_stage.sh --release vpu-stability-v1.13.0 --machine hailo15l-sbc
#   scripts/h15_boot/vpu_stage.sh --image-dir hailo@10.41.75.21:/local/users/h15l_reference_backup/image_files \
#       --machine hailo15l-sbc [--name ref-phys-ai-20260601]
#   ... --image-dir DIR  a folder on this host, or [user@]host:path (read-only access is enough)
#   ... --name NAME      staging folder name for --image-dir (default: the folder's name,
#                        or its parent's when the folder is called image_files)
#   ... --no-tftp        stage and verify only; print the TFTP commands instead of running them
#
# Re-running skips files that are already staged with the right md5.
# The full rootfs .ext4 is NOT staged: u-boot can't TFTP it on 2 GB boards
# ("trying to overwrite reserved memory"); Board Init writes the rootfs from the .swu.

set -euo pipefail
: "${H15_IMAGES:?source scripts/h15_boot/shuttle.env first}"

RELEASE=""; IMAGE_DIR=""; NAME=""; MACHINE=""; DO_TFTP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --release)   RELEASE="$2"; shift 2 ;;
        --image-dir) IMAGE_DIR="$2"; shift 2 ;;
        --name)      NAME="$2"; shift 2 ;;
        --machine)   MACHINE="$2"; shift 2 ;;
        --no-tftp)   DO_TFTP=0; shift ;;
        -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$MACHINE" ] || { echo "ERROR: --machine is required" >&2; exit 1; }
if [ -n "$RELEASE" ] && [ -n "$IMAGE_DIR" ] || [ -z "$RELEASE$IMAGE_DIR" ]; then
    echo "ERROR: give exactly one of --release or --image-dir" >&2; exit 1
fi

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
if [ -n "$RELEASE" ]; then
    SRC_HOST="${YSTOR:?source scripts/h15_boot/shuttle.env first}"
    SRC="${YSTOR_BKC}/${RELEASE}/hailo-yocto-validation/build/tmp/deploy/images/${MACHINE}"
    NAME="$RELEASE"
else
    if [ "$IMAGE_DIR" != "${IMAGE_DIR#*:}" ]; then SRC_HOST="${IMAGE_DIR%%:*}"; SRC="${IMAGE_DIR#*:}"; else SRC_HOST=""; SRC="$IMAGE_DIR"; fi
    if [ -z "$NAME" ]; then
        NAME=$(basename "$SRC")
        [ "$NAME" = image_files ] && NAME=$(basename "$(dirname "$SRC")")
    fi
fi
DEST="${H15_IMAGES}/${NAME}/${MACHINE}"

# Run a script where the image is. Remote commands go through bash -s
# (ystor's login shell is tcsh).
src_sh() { if [ -n "$SRC_HOST" ]; then ssh -o BatchMode=yes "$SRC_HOST" "bash -s"; else bash -s; fi; }
src_copy() { if [ -n "$SRC_HOST" ]; then scp -q -o BatchMode=yes "$SRC_HOST:$SRC/$1" "$2"; else cp -L "$SRC/$1" "$2"; fi; }

echo "===== Staging $NAME / $MACHINE ====="
echo "  from: ${SRC_HOST:+$SRC_HOST:}$SRC"
echo "  to:   $DEST"

echo "[1/3] Checking the source..."
# "<md5> <name>" per file (symlinks followed); a missing file prints "MISSING <name>".
REMOTE_MD5=$(src_sh <<EOF
cd "$SRC" || exit 3
for f in ${FILES[*]}; do
    if [ -e "\$f" ]; then echo "\$(md5sum < "\$f" | cut -d' ' -f1) \$f"; else echo "MISSING \$f"; fi
done
EOF
) || { echo "ERROR: ${SRC_HOST:+$SRC_HOST:}$SRC not found" >&2; exit 1; }
if echo "$REMOTE_MD5" | grep -q '^MISSING'; then
    echo "ERROR: the image is missing flash files (built for another machine?):" >&2
    echo "$REMOTE_MD5" | sed -n 's/^MISSING /  /p' >&2
    exit 1
fi
echo "  all ${#FILES[@]} files present"
SWU_BUILD=$(echo "readlink ${SRC}/hailo-update-image-${MACHINE}.swu" | src_sh || true)
[ -n "$SWU_BUILD" ] && echo "  update image: $SWU_BUILD"

echo "[2/3] Copying and verifying..."
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    want=$(echo "$REMOTE_MD5" | awk -v f="$f" '$2 == f {print $1}')
    if [ -f "$DEST/$f" ] && [ "$(md5sum < "$DEST/$f" | cut -d' ' -f1)" = "$want" ]; then
        echo "  ok   $f (already staged)"
        continue
    fi
    src_copy "$f" "$DEST/$f.part"
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
echo "  /srv/tftp was -> $OLD"
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
