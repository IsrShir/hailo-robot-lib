#!/bin/bash
# Make sure the shuttle can ssh to the board with $H15_KEY (no password).
# After a flash the board only accepts root's default password, so this installs
# the key with sshpass. Safe to re-run: does nothing if the key already works.
#
# Usage (on the shuttle):
#   source scripts/h15_boot/shuttle.env
#   scripts/h15_boot/vpu_board_key.sh [root@<ip>]
#
# BOARD_PASSWORD overrides the password (default: root, the dev-image default).

set -euo pipefail
: "${H15_KEY:?source scripts/h15_boot/shuttle.env first}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh" "${1:-${TARGET:-root@10.0.0.1}}"

if [ ! -f "$H15_KEY" ]; then
    echo "Creating board key $H15_KEY"
    ssh-keygen -q -t ed25519 -N "" -C "h15-board@$(hostname -s)" -f "$H15_KEY"
fi

if ! target_ssh true 2>/dev/null; then
    command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed (sudo apt install sshpass)" >&2; exit 1; }
    echo "Installing $H15_KEY.pub on $TARGET (password login)..."
    # ssh keeps the FIRST value of an option, so these overrides go before SSH_OPTS
    # (which sets BatchMode=yes and would disable password login).
    # shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
    sshpass -p "${BOARD_PASSWORD:-root}" ssh -o BatchMode=no -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password $SSH_OPTS "$TARGET" \
        "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys" < "$H15_KEY.pub"
    target_ssh true || { echo "ERROR: key login still fails after installing the key" >&2; exit 1; }
fi
echo "ok   key login to $TARGET works"

# Remote mode: the host driving the skill (e.g. a laptop) reaches the board with
# ProxyJump through this shuttle, so it authenticates to the board with its own key.
# EXTRA_PUBKEYS holds public key lines (one per line) to add if missing.
if [ -n "${EXTRA_PUBKEYS:-}" ]; then
    echo "$EXTRA_PUBKEYS" | target_ssh 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys
        while read -r k; do
            [ -n "$k" ] && ! grep -qxF "$k" ~/.ssh/authorized_keys && echo "$k" >> ~/.ssh/authorized_keys && echo "ok   added ${k##* }"
        done; true'
fi
