#!/usr/bin/env bash
# Runs on the target under a transient systemd service.
set -euo pipefail

VARS_FILE="${WELCOME_DECRYPTED_VARS_FILE:-}"
HOSTNAME_FILE="${WELCOME_HOSTNAME_FILE:-}"
GREASEWOOD_TOKEN_FILE="${WELCOME_GREASEWOOD_TOKEN_FILE:-}"
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
