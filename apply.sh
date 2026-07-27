#!/usr/bin/env bash
# Apply the checked-out playbook locally. This is the worker used both directly
# on a host and by the detached systemd deployment path.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/ansible"

run_as_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/apply-$(date +%Y%m%d-%H%M%S).log"

EXTRA=()
[ "${IMAGE_BUILD:-0}" = 1 ] && EXTRA+=(-e image_build=true)
PROFILE="${WELCOME_PROFILE:-host}"
[[ "$PROFILE" =~ ^[a-z0-9_-]+$ ]] || {
  echo "apply.sh: invalid WELCOME_PROFILE" >&2
  exit 2
}
if [ "$PROFILE" != host ]; then
  [ -f "profiles/$PROFILE.yml" ] || {
    echo "apply.sh: unknown profile: $PROFILE" >&2
    exit 2
  }
  EXTRA+=(-e "@profiles/$PROFILE.yml")
fi
[ -f local.yml ] && EXTRA+=(-e @local.yml)
[ ! -f /etc/welcome/local.yml ] || EXTRA+=(-e @/etc/welcome/local.yml)
[ -z "${WELCOME_SYSTEM_HOSTNAME:-}" ] ||
  EXTRA+=(-e "system_hostname=$WELCOME_SYSTEM_HOSTNAME")

# A detached remote launch passes already-decrypted variables through a
# short-lived file in /run. In ordinary local use, decrypt the committed vault
# with a machine-local password file or an interactive prompt.
if [ -n "${WELCOME_DECRYPTED_VARS_FILE:-}" ]; then
  [ -r "$WELCOME_DECRYPTED_VARS_FILE" ] || {
    echo "apply.sh: cannot read WELCOME_DECRYPTED_VARS_FILE" >&2
    exit 1
  }
  EXTRA+=(-e @"$WELCOME_DECRYPTED_VARS_FILE")
elif [ -f vault.yml ]; then
  EXTRA+=(-e @vault.yml)
  if [ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]; then
    WELCOME_VAULT_PASSWORD_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/welcome/vault-password"
    if [ -r "$WELCOME_VAULT_PASSWORD_FILE" ]; then
      export ANSIBLE_VAULT_PASSWORD_FILE="$WELCOME_VAULT_PASSWORD_FILE"
    else
      EXTRA+=(--ask-vault-pass)
    fi
  fi
fi

run_as_root apt-get update
run_as_root apt-get install -y ansible
ansible-galaxy collection install -r requirements.yml

echo "==> logging this run to $LOG"
ANSIBLE_LOG_PATH="$LOG" \
  ansible-playbook -i 'localhost,' -c local site.yml "${EXTRA[@]}" "$@"

run_as_root install -d -m 0755 /var/log/ansible-apply
run_as_root ln -sfn "$LOG" /var/log/ansible-apply/latest.log

if [ -e /var/run/reboot-required ]; then
  echo "==> REBOOT REQUIRED"
  run_as_root cat /var/run/reboot-required
  [ ! -r /var/run/reboot-required.pkgs ] ||
    run_as_root cat /var/run/reboot-required.pkgs
fi
