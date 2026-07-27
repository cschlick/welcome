#!/usr/bin/env bash
# Stage and launch hardening on a target without keeping the SSH session alive.
# The vault is decrypted on this control machine; its password never leaves.
set -euo pipefail

usage() {
  echo "Usage: $0 <ssh-target> [--mesh-only-ssh] [-- <ansible-playbook args...>]" >&2
  echo "Example: $0 user@203.0.113.10 --mesh-only-ssh" >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
TARGET="$1"
shift
MESH_ONLY_SSH=0
PLAYBOOK_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mesh-only-ssh)
      MESH_ONLY_SSH=1
      shift
      ;;
    --)
      shift
      PLAYBOOK_ARGS+=("$@")
      break
      ;;
    *)
      PLAYBOOK_ARGS+=("$1")
      shift
      ;;
  esac
done

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

read -r -p "Hostname (press Enter to keep the current hostname): " SYSTEM_HOSTNAME
if [ -n "$SYSTEM_HOSTNAME" ]; then
  if [ "${#SYSTEM_HOSTNAME}" -gt 253 ] ||
    [[ ! "$SYSTEM_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
    [[ "$SYSTEM_HOSTNAME" == *..* ]]; then
    echo "bootstrap-remote.sh: invalid hostname" >&2
    exit 2
  fi
  IFS=. read -r -a HOSTNAME_LABELS <<< "$SYSTEM_HOSTNAME"
  for hostname_label in "${HOSTNAME_LABELS[@]}"; do
    [ "${#hostname_label}" -le 63 ] || {
      echo "bootstrap-remote.sh: hostname labels must be at most 63 characters" >&2
      exit 2
    }
  done
fi

read -r -s -p "Greasewood invite token (press Enter to skip): " GREASEWOOD_TOKEN
echo

RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_STAGE="/tmp/welcome-stage-$RELEASE_ID"
REMOTE_VARS="/tmp/welcome-vars-$RELEASE_ID.yml"
REMOTE_HOSTNAME="/tmp/welcome-hostname-$RELEASE_ID"
REMOTE_GREASEWOOD_TOKEN="/tmp/welcome-greasewood-$RELEASE_ID.token"

ssh "${SSH_OPTIONS[@]}" "$TARGET" "umask 077 && mkdir '$REMOTE_STAGE'"
RELEASE_ARCHIVE="$TEMP_DIR/release.tar.gz"
tar \
  --exclude=.git \
  --exclude=logs \
  -C "$ROOT" -czf "$RELEASE_ARCHIVE" .
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "tar -xzf - -C '$REMOTE_STAGE'" < "$RELEASE_ARCHIVE"
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "umask 077 && cat > '$REMOTE_VARS'" < "$DECRYPTED_VARS"
HOSTNAME_FILE="$TEMP_DIR/hostname"
GREASEWOOD_TOKEN_FILE="$TEMP_DIR/greasewood-token"
printf '%s' "$SYSTEM_HOSTNAME" > "$HOSTNAME_FILE"
printf '%s' "$GREASEWOOD_TOKEN" > "$GREASEWOOD_TOKEN_FILE"
chmod 0600 "$HOSTNAME_FILE" "$GREASEWOOD_TOKEN_FILE"
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "umask 077 && cat > '$REMOTE_HOSTNAME'" < "$HOSTNAME_FILE"
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "umask 077 && cat > '$REMOTE_GREASEWOOD_TOKEN'" < "$GREASEWOOD_TOKEN_FILE"
unset GREASEWOOD_TOKEN

REMOTE_ARGS=()
for arg in "${PLAYBOOK_ARGS[@]}"; do
  printf -v quoted_arg '%q' "$arg"
  REMOTE_ARGS+=("$quoted_arg")
done

ssh "${SSH_OPTIONS[@]}" -tt "$TARGET" \
  "bash '$REMOTE_STAGE/launch-detached.sh' '$REMOTE_STAGE' '$REMOTE_VARS' '$REMOTE_HOSTNAME' '$REMOTE_GREASEWOOD_TOKEN' '$MESH_ONLY_SSH' '$RELEASE_ID' ${REMOTE_ARGS[*]:-}"

echo
echo "The SSH session may disconnect while networking changes."
if [ "$MESH_ONLY_SSH" = 1 ]; then
  echo "On success, physical-interface SSH will be disabled."
  echo "Reconnect through the host's Greasewood name or address, then run:"
  echo "  sudo journalctl -u welcome-apply.service --no-pager"
else
  echo "After reconnecting:"
  echo "  ssh $TARGET 'sudo journalctl -u welcome-apply.service --no-pager'"
fi
