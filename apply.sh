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
# Profile selection. An explicit WELCOME_PROFILE always wins and never prompts —
# the detached path depends on that (launch-detached.sh passes it to systemd as
# an environment variable). Otherwise ask, as long as there is a terminal to ask
# at: applying the headless profile to a desktop strips its session, and a
# prompt you cannot skip beats a flag you have to remember. With no TTY —
# systemd, CI, a piped run — fall back silently to host, as before.
PROFILE="${WELCOME_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  if [ -t 0 ]; then
    PROFILE_NAMES=(host)
    PROFILE_DESCS=("headless server - the default hardening")
    for profile_file in profiles/*.yml; do
      [ -e "$profile_file" ] || continue
      PROFILE_NAMES+=("$(basename "$profile_file" .yml)")
      # First comment line of the profile, trimmed to keep the menu tidy. These
      # comments wrap, so mark the cut rather than ending mid-sentence.
      profile_desc="$(sed -n '2{s/^#[[:space:]]*//;p;q;}' "$profile_file")"
      [ "${#profile_desc}" -le 58 ] || profile_desc="${profile_desc:0:57}…"
      PROFILE_DESCS+=("${profile_desc:-(no description)}")
    done
    echo "Which profile applies to THIS machine?" >&2
    for profile_index in "${!PROFILE_NAMES[@]}"; do
      printf '  %d) %-9s %s\n' \
        "$((profile_index + 1))" \
        "${PROFILE_NAMES[$profile_index]}" \
        "${PROFILE_DESCS[$profile_index]}" >&2
    done
    # No default on Enter: the point is that the choice is deliberate.
    while :; do
      if ! read -r -p "Profile [1-${#PROFILE_NAMES[@]}]: " profile_reply; then
        echo >&2
        echo "apply.sh: no profile chosen" >&2
        exit 2
      fi
      if [[ "$profile_reply" =~ ^[0-9]+$ ]] &&
        [ "$profile_reply" -ge 1 ] &&
        [ "$profile_reply" -le "${#PROFILE_NAMES[@]}" ]; then
        PROFILE="${PROFILE_NAMES[$((profile_reply - 1))]}"
        break
      fi
      echo "Enter a number between 1 and ${#PROFILE_NAMES[@]}." >&2
    done
    echo "==> profile: $PROFILE" >&2
  else
    PROFILE=host
  fi
fi
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

# Become password, decided the same way as the vault password above: ask only
# when there is no other way in. The playbook needs root, and whether sudo wants
# a password depends on whether this account already carries the NOPASSWD grant
# the accounts role installs — true on every host past its first run.
#
# This inspects sudo's POLICY (-l) rather than just trying sudo, because a
# credential cached for THIS terminal proves nothing: Ansible runs sudo without
# a controlling tty and so misses the tty-keyed timestamp, which is exactly how
# a run that follows a successful interactive `sudo apt-get` still fails with
# "sudo: a password is required". Only a real NOPASSWD grant settles it.
if [ "$(id -u)" = 0 ]; then
  : # already root; become needs no password
elif printf '%s\n' "$@" | grep -qxE '\-K|--ask-become-pass'; then
  : # the operator asked for the prompt explicitly
elif sudo -n -l 2>/dev/null | grep -qE 'NOPASSWD:[[:space:]]*ALL'; then
  : # passwordless sudo is granted
elif [ -t 0 ]; then
  EXTRA+=(--ask-become-pass)
else
  : # no tty to prompt at; let sudo report the failure itself
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
