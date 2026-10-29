# shellcheck shell=bash
# Shared helpers for the h15_boot scripts. Source, don't run.
#
#   TARGET    ssh target (default root@10.0.0.1, or the script's first argument)
#   SSH_OPTS  extra ssh/scp/rsync options, e.g. on hosts whose ssh config proxies
#             everything through sss_ssh_knownhostsproxy:
#               SSH_OPTS="-o ProxyCommand=none" ./install.sh

TARGET=${1:-${TARGET:-root@10.0.0.1}}
SSH_OPTS=${SSH_OPTS:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the scripts that source this file
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
target_ssh() { ssh $SSH_OPTS "$TARGET" "$@"; }
# shellcheck disable=SC2086
target_scp() { scp $SSH_OPTS "$@"; }
target_rsync() { rsync -e "ssh $SSH_OPTS" "$@"; }
