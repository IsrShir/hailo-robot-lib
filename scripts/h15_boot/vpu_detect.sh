#!/bin/bash
# Report what the board on the shuttle is and what it runs. Read-only.
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_detect.sh [root@<ip>]
#
# Prints KEY=VALUE lines:
#   BOARD_STATE   linux | no-ssh (answers ping, no login) | down (no ping)
#   MACHINE       yocto machine, e.g. hailo15l-sbc, hailo15-sbc, hailo15-sbc-rev3-1
#   RELEASE       VERSION from /etc/os-release, e.g. vpu-stability-v1.13.0 (empty on
#                 images that don't set it, like the phys-ai dev builds)
#   IMAGE_NAME    from /etc/build-info; compare with the release's canonical image
#   HAILORT       hailortcli version
#   SENSOR_CFG    where /etc/imaging/cfg/medialib_configs points
#   BUNDLE        release a drone-follow bundle was installed for (empty if none)
#   APP           yes if /home/root/robot_follow is installed
# When the board doesn't boot Linux, the machine can be read at the u-boot prompt
# instead: vpu_console.py detect.

set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${1:-${TARGET:-root@10.0.0.1}}"
HOST=${TARGET#*@}

if ! target_ssh true 2>/dev/null; then
    if ping -c1 -W2 "$HOST" >/dev/null 2>&1; then
        echo "BOARD_STATE=no-ssh"
    else
        echo "BOARD_STATE=down"
    fi
    exit 0
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
