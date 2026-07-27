#!/usr/bin/env bash
# Runs on the target under a transient systemd service.
set -euo pipefail

VARS_FILE="${WELCOME_DECRYPTED_VARS_FILE:-}"
HOSTNAME_FILE="${WELCOME_HOSTNAME_FILE:-}"
GREASEWOOD_TOKEN_FILE="${WELCOME_GREASEWOOD_TOKEN_FILE:-}"
MESH_ONLY_SSH="${WELCOME_MESH_ONLY_SSH:-0}"
PROFILE="${WELCOME_PROFILE:-host}"
[ "$MESH_ONLY_SSH" = 0 ] || [ "$MESH_ONLY_SSH" = 1 ] || {
  echo "detached-apply.sh: invalid mesh-only SSH setting" >&2
  exit 2
}
[[ "$PROFILE" =~ ^[a-z0-9_-]+$ ]] || {
  echo "detached-apply.sh: invalid profile" >&2
  exit 2
}
case "$VARS_FILE" in
  /run/welcome/*.yml) ;;
  *)
    echo "detached-apply.sh: invalid decrypted vars path" >&2
    exit 2
    ;;
esac
case "$HOSTNAME_FILE" in
  "") ;;
  /run/welcome/hostname-*) ;;
  *)
    echo "detached-apply.sh: invalid hostname path" >&2
    exit 2
    ;;
esac
case "$GREASEWOOD_TOKEN_FILE" in
  "") ;;
  /run/welcome/*.token) ;;
  *)
    echo "detached-apply.sh: invalid Greasewood token path" >&2
    exit 2
    ;;
esac

cleanup() {
  rm -f -- "$VARS_FILE"
  [ -z "$HOSTNAME_FILE" ] || rm -f -- "$HOSTNAME_FILE"
  [ -z "$GREASEWOOD_TOKEN_FILE" ] || rm -f -- "$GREASEWOOD_TOKEN_FILE"
}
trap cleanup EXIT HUP INT TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_HOSTNAME=""
if [ -n "$HOSTNAME_FILE" ]; then
  SYSTEM_HOSTNAME="$(<"$HOSTNAME_FILE")"
  rm -f -- "$HOSTNAME_FILE"
fi
WELCOME_SYSTEM_HOSTNAME="$SYSTEM_HOSTNAME" \
  WELCOME_DECRYPTED_VARS_FILE="$VARS_FILE" \
  "$ROOT/apply.sh" "$@"

if [ -n "$GREASEWOOD_TOKEN_FILE" ]; then
  GREASEWOOD_TOKEN="$(<"$GREASEWOOD_TOKEN_FILE")"
  rm -f -- "$GREASEWOOD_TOKEN_FILE"
  if [ -n "$GREASEWOOD_TOKEN" ]; then
    gw join "$GREASEWOOD_TOKEN"
  fi
  unset GREASEWOOD_TOKEN
fi

if [ "$MESH_ONLY_SSH" = 1 ]; then
  echo "==> Verifying the Greasewood interface before restricting SSH"
  GREASEWOOD_READY=0
  for _ in $(seq 1 30); do
    if ip link show dev gw-home >/dev/null 2>&1 &&
      ip -6 address show dev gw-home scope global |
        grep -q 'inet6'; then
      GREASEWOOD_READY=1
      break
    fi
    sleep 1
  done
  [ "$GREASEWOOD_READY" = 1 ] || {
    echo "Greasewood is not ready; physical-interface SSH remains enabled." >&2
    exit 1
  }

  install -d -m 0755 /etc/welcome
  SETTINGS_TEMP="$(mktemp /etc/welcome/local.yml.XXXXXX)"
  chmod 0600 "$SETTINGS_TEMP"
  printf '%s\n' \
    '---' \
    'nftables_ssh_interfaces:' \
    '  - gw-home' > "$SETTINGS_TEMP"
  install -o root -g root -m 0644 "$SETTINGS_TEMP" /etc/welcome/local.yml
  rm -f -- "$SETTINGS_TEMP"

  echo "==> Restricting SSH to gw-home"
  WELCOME_DECRYPTED_VARS_FILE="$VARS_FILE" \
    WELCOME_SYSTEM_HOSTNAME="$SYSTEM_HOSTNAME" \
    "$ROOT/apply.sh" --tags nftables
fi
