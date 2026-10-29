#!/bin/bash
# Make sure the shuttle can ssh to the board, then report what the board is and runs.
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_detect.sh [root@<ip>]
#
# Key: after a flash the board only accepts root's default password, so the
# dedicated $H15_KEY is installed with sshpass (BOARD_PASSWORD, default root).
# EXTRA_PUBKEYS (one public key per line; vpu_remote.sh passes the laptop's) are
# added too, so a laptop can reach the board through the shuttle. Re-runs are no-ops.
#
# Prints KEY=VALUE lines on stdout (key messages go to stderr):
#   BOARD_STATE   linux | no-ssh (answers ping, no login) | down (no ping)
#   MACHINE       yocto machine, e.g. hailo15l-sbc, hailo15-sbc, hailo15-sbc-rev3-1
#   RELEASE       VERSION from /etc/os-release, e.g. vpu-stability-v1.13.0 (develop on dev builds)
#   IMAGE_NAME    from /etc/build-info; compare with the image's canonical build
#   HAILORT       hailortcli version
#   SENSOR_CFG    where /etc/imaging/cfg/medialib_configs points
#   BUNDLE        release a drone-follow bundle was installed for (empty if none)
#   APP           yes if /home/root/robot_follow is installed
# When the board doesn't boot Linux, read the machine at u-boot: vpu_console.py detect.

set -uo pipefail
: "${H15_KEY:?source scripts/h15_boot/shuttle.env first}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${1:-${TARGET:-root@10.0.0.1}}"
HOST=${TARGET#*@}

[ -f "$H15_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "h15-board@$(hostname -s)" -f "$H15_KEY"
if ! target_ssh true 2>/dev/null && ping -c1 -W2 "$HOST" >/dev/null 2>&1; then
    if command -v sshpass >/dev/null; then
        echo "installing $H15_KEY.pub on $TARGET (password login)" >&2
        # ssh keeps the FIRST value of an option, so these go before SSH_OPTS
        # (which sets BatchMode=yes and would disable password login).
        # shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
        sshpass -p "${BOARD_PASSWORD:-root}" ssh -o BatchMode=no -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password $SSH_OPTS "$TARGET" \
            "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys" < "$H15_KEY.pub" >&2
    else
        echo "WARN sshpass not installed (sudo apt install sshpass): can't install the board key" >&2
    fi
fi

if ! target_ssh true 2>/dev/null; then
    if ping -c1 -W2 "$HOST" >/dev/null 2>&1; then echo "BOARD_STATE=no-ssh"; else echo "BOARD_STATE=down"; fi
    exit 0
fi

if [ -n "${EXTRA_PUBKEYS:-}" ]; then
    echo "$EXTRA_PUBKEYS" | target_ssh 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys
        while read -r k; do
            [ -n "$k" ] && ! grep -qxF "$k" ~/.ssh/authorized_keys && echo "$k" >> ~/.ssh/authorized_keys && echo "added key ${k##* }"
        done; true' >&2
fi

echo "BOARD_STATE=linux"
target_ssh 'sh -s' <<'EOF'
bi() { sed -n "s/^$1 *= *//p" /etc/build-info 2>/dev/null | head -1; }
echo "MACHINE=$(bi MACHINE)"
echo "RELEASE=$(sed -n 's/^VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "IMAGE_NAME=$(bi IMAGE_NAME)"
echo "HAILORT=$(hailortcli --version 2>/dev/null | awk '{print $NF}')"
echo "SENSOR_CFG=$(readlink /etc/imaging/cfg/medialib_configs 2>/dev/null)"
echo "BUNDLE=$(sed -n 's/^release=//p' /usr/share/drone-follow/bundle-manifest.txt 2>/dev/null)"
[ -f /home/root/robot_follow/drone_follow_h15.py ] && echo "APP=yes" || echo "APP=no"
EOF
