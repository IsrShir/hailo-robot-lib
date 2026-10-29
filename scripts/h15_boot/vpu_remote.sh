#!/bin/bash
# Remote mode: drive the shuttle-side steps of h15-vpu-setup from a laptop.
#
# Usage (on the laptop, from this repo):
#   scripts/h15_boot/vpu_remote.sh setup <shuttle>                 # copy scripts, add board alias
#   scripts/h15_boot/vpu_remote.sh run   <shuttle> <command...>    # run a step, wait for it
#   scripts/h15_boot/vpu_remote.sh start <shuttle> <name> <command...>   # long step, detached
#   scripts/h15_boot/vpu_remote.sh log   <shuttle> <name>          # its output so far
#   scripts/h15_boot/vpu_remote.sh wait  <shuttle> <name>          # until it ends; its exit code
# <shuttle> is hailo@<ip>. Commands run in the shuttle's copy of the scripts
# (~/.cache/h15_vpu_setup) with shuttle.env sourced, so they look like local mode:
#   vpu_remote.sh run hailo@10.41.74.167 scripts/h15_boot/vpu_detect.sh
#   vpu_remote.sh start hailo@10.41.74.167 flash python3 scripts/h15_boot/vpu_console.py flash --machine hailo15l-sbc
#
# setup also writes a ~/.ssh/config alias h15-<last octet> (root@10.0.0.1 via
# ProxyJump through the shuttle); the laptop-side steps use it as their target.
# run passes this laptop's public keys as EXTRA_PUBKEYS, so vpu_detect.sh
# also lets the laptop log in to the board.

set -euo pipefail
CMD=${1:?usage: $0 setup|run|start|log|wait <shuttle> ...}
S=${2:?shuttle (hailo@<ip>) required}
shift 2
R=.cache/h15_vpu_setup
HERE="$(cd "$(dirname "$0")" && pwd)"
SHUTTLE_FILES=(common.sh shuttle.env vpu_stage.sh vpu_console.py vpu_detect.sh vpu_ci_board_init.sh)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

# One remote command line: cd to the script copy, load shuttle.env, then the args (quoted).
remote() {
    local q=""
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    printf 'cd %s && source scripts/h15_boot/shuttle.env && export EXTRA_PUBKEYS=%q &&%s' \
        "$R" "$(cat ~/.ssh/id_*.pub 2>/dev/null)" "$q"
}

case "$CMD" in
setup)
    "${SSH[@]}" "$S" "mkdir -p $R/scripts/h15_boot"
    (cd "$HERE" && rsync -a "${SHUTTLE_FILES[@]}" "$S:$R/scripts/h15_boot/")
    alias="h15-${S##*.}"
    if ! grep -q "^Host $alias\$" ~/.ssh/config 2>/dev/null; then
        printf '\nHost %s\n    HostName 10.0.0.1\n    User root\n    ProxyJump %s\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' \
            "$alias" "$S" >> ~/.ssh/config
        chmod 600 ~/.ssh/config
    fi
    echo "scripts copied to $S:~/$R; board alias: $alias (use it as TARGET for the laptop-side steps)"
    ;;
run)
    "${SSH[@]}" -n "$S" "$(remote "$@")"
    ;;
start)
    NAME=${1:?name required}; shift
    O="h15_$NAME"
    # Detached (stdin from /dev/null, own subshell), or ssh would stay open until it ends.
    # The exit code goes to ~/h15_<name>.rc for `wait`.
    "${SSH[@]}" -n "$S" "rm -f ~/$O.rc; (nohup bash -c $(printf '%q' "$(remote "$@"); echo \$? > ~/$O.rc") \
        > ~/$O.out 2>&1 < /dev/null & echo \$! > ~/$O.pid)"
    echo "started $NAME on $S (pid $("${SSH[@]}" -n "$S" "cat ~/$O.pid")); output: ~/$O.out there"
    ;;
log)
    "${SSH[@]}" -n "$S" "cat ~/h15_${1:?name required}.out"
    ;;
wait)
    O="h15_${1:?name required}"
    while "${SSH[@]}" -n "$S" "kill -0 \$(cat ~/$O.pid) 2>/dev/null"; do sleep 20; done
    "${SSH[@]}" -n "$S" "tail -15 ~/$O.out"
    rc=$("${SSH[@]}" -n "$S" "cat ~/$O.rc 2>/dev/null || echo 255")
    echo "== $1 exited with $rc"
    exit "$rc"
    ;;
*) echo "unknown command $CMD (setup|run|start|log|wait)" >&2; exit 1 ;;
esac
