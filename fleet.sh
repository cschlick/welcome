#!/usr/bin/env bash
# fleet.sh — run the hardening playbook (and ad-hoc checks) across your Vultr
# fleet, with generic encrypted variables and the dynamic inventory's optional
# vaulted API key wired in so you don't repeat the flags every time.
#
# It always uses:  -i inventory/vultr.yml   (discovers running Vultr instances)
# It loads ansible/vault.yml for generic encrypted variables. For Vultr API
# auth, inventory/vault.yml is optional; otherwise VULTR_API_KEY is used.
# Vault passwords come from ANSIBLE_VAULT_PASSWORD_FILE,
# ~/.config/welcome/vault-password, legacy ./.vault_pass, or an interactive
# prompt (in that order).
# (See the README "Managing a running fleet" section for the one-time vault setup.)
#
# Commands (extra args after the command pass straight through to ansible):
#   list                 list discovered hosts + groups
#   ping                 connectivity check (are they reachable as user?)
#   check                DRY RUN of site.yml (--check --diff) — start here
#   apply                apply site.yml to the fleet
#   rotate-keys          apply only the ssh role (--tags ssh)
#   help                 this message
#
# Examples:
#   ./fleet.sh list
#   ./fleet.sh check --limit tag_canary           # dry-run one group
#   ./fleet.sh apply --limit tag_canary           # apply to one group first
#   ./fleet.sh apply                              # ...then the whole fleet
#   # SSH key rotation (after editing encrypted vault.yml):
#   ./fleet.sh rotate-keys --limit tag_canary                         # 1. add new key, test
#   ./fleet.sh rotate-keys -e ssh_authorized_keys_exclusive=true      # 2. drop the old key
#
# Safety: prefer `check` and `--limit` before a fleet-wide `apply`. The disruptive
# roles (ssh/nftables/networkd) can drop connections; roll out in batches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$ROOT/$(basename "${BASH_SOURCE[0]}")"   # absolute path (we cd away below)
cd "$ROOT/ansible"

INV="inventory/vultr.yml"

# Print the header comment block (everything between the shebang and the code).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$SELF"; }

# Resolve the command FIRST so `help` / typos don't require any auth set-up.
cmd="${1:-help}"; shift || true
case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  list|ping|check|apply|rotate-keys) ;;   # known commands — fall through to auth
  *) echo "fleet.sh: unknown command '$cmd'" >&2; echo >&2; usage; exit 2 ;;
esac

# --- encrypted variables + Vultr auth wiring -------------------------------
ARGS=()
VAULT_NEEDED=0
if [ -f vault.yml ]; then
  ARGS+=(-e @vault.yml)
  VAULT_NEEDED=1
fi
if [ -f inventory/vault.yml ]; then
  ARGS+=(-e @inventory/vault.yml)
  VAULT_NEEDED=1
elif [ -z "${VULTR_API_KEY:-}" ]; then
  echo "fleet.sh: no inventory/vault.yml and VULTR_API_KEY is unset." >&2
  echo "          Set up the vaulted key (see README) or 'export VULTR_API_KEY=...'." >&2
  exit 1
fi

if [ "$VAULT_NEEDED" = 1 ] && [ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]; then
  WELCOME_VAULT_PASSWORD_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/welcome/vault-password"
  if [ -r "$WELCOME_VAULT_PASSWORD_FILE" ]; then
    export ANSIBLE_VAULT_PASSWORD_FILE="$WELCOME_VAULT_PASSWORD_FILE"
  elif [ -r "$ROOT/.vault_pass" ]; then
    export ANSIBLE_VAULT_PASSWORD_FILE="$ROOT/.vault_pass"
  else
    ARGS+=(--ask-vault-pass)
  fi
fi

case "$cmd" in
  list)        exec ansible-inventory -i "$INV" "${ARGS[@]}" --graph "$@" ;;
  ping)        exec ansible          -i "$INV" "${ARGS[@]}" all -m ansible.builtin.ping "$@" ;;
  check)       exec ansible-playbook -i "$INV" "${ARGS[@]}" site.yml --check --diff "$@" ;;
  apply)       exec ansible-playbook -i "$INV" "${ARGS[@]}" site.yml "$@" ;;
  rotate-keys) exec ansible-playbook -i "$INV" "${ARGS[@]}" site.yml --tags ssh "$@" ;;
esac
