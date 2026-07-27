#!/usr/bin/env bash
# Stage and launch hardening on a target without keeping the SSH session alive.
# The vault is decrypted on this control machine; its password never leaves.
set -euo pipefail

usage() {
  echo "Usage: $0 <ssh-target> [-- <ansible-playbook args...>]" >&2
  echo "Example: $0 user@203.0.113.10" >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
TARGET="$1"
shift
if [ "${1:-}" = "--" ]; then shift; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$ROOT/ansible/vault.yml"
[ -f "$VAULT" ] || { echo "Missing $VAULT" >&2; exit 1; }

for command_name in ansible-vault ssh tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "bootstrap-remote.sh: $command_name is required" >&2
    exit 1
  }
done

TEMP_DIR="$(mktemp -d /tmp/welcome-bootstrap.XXXXXX)"
SSH_OPTIONS=(
  -o ControlMaster=auto
  -o ControlPersist=60
  -o "ControlPath=$TEMP_DIR/ssh-control"
)
cleanup() {
  ssh "${SSH_OPTIONS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

DECRYPTED_VARS="$TEMP_DIR/vault.yml"
VAULT_ARGS=()
if [ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]; then
  VAULT_ARGS+=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
else
  WELCOME_VAULT_PASSWORD_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/welcome/vault-password"
  if [ -r "$WELCOME_VAULT_PASSWORD_FILE" ]; then
    VAULT_ARGS+=(--vault-password-file "$WELCOME_VAULT_PASSWORD_FILE")
  else
    VAULT_ARGS+=(--ask-vault-pass)
  fi
fi
ansible-vault decrypt "${VAULT_ARGS[@]}" --output "$DECRYPTED_VARS" "$VAULT"
chmod 0600 "$DECRYPTED_VARS"

RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_STAGE="/tmp/welcome-stage-$RELEASE_ID"
REMOTE_VARS="/tmp/welcome-vars-$RELEASE_ID.yml"

ssh "${SSH_OPTIONS[@]}" "$TARGET" "umask 077 && mkdir '$REMOTE_STAGE'"
tar \
  --exclude=.git \
  --exclude=logs \
  -C "$ROOT" -czf - . |
  ssh "${SSH_OPTIONS[@]}" "$TARGET" "tar -xzf - -C '$REMOTE_STAGE'"
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "umask 077 && cat > '$REMOTE_VARS'" < "$DECRYPTED_VARS"

REMOTE_ARGS=()
for arg in "$@"; do
  printf -v quoted_arg '%q' "$arg"
  REMOTE_ARGS+=("$quoted_arg")
done

ssh "${SSH_OPTIONS[@]}" -tt "$TARGET" \
  "bash '$REMOTE_STAGE/launch-detached.sh' '$REMOTE_STAGE' '$REMOTE_VARS' '$RELEASE_ID' ${REMOTE_ARGS[*]:-}"

echo
echo "The SSH session may disconnect while networking changes."
echo "After reconnecting:"
echo "  ssh $TARGET 'sudo journalctl -u welcome-apply.service --no-pager'"
