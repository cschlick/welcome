#!/usr/bin/env bash
# Runs on the target under a transient systemd service.
set -euo pipefail

VARS_FILE="${WELCOME_DECRYPTED_VARS_FILE:-}"
GREASEWOOD_TOKEN_FILE="${WELCOME_GREASEWOOD_TOKEN_FILE:-}"
case "$VARS_FILE" in
  /run/welcome/*.yml) ;;
  *)
    echo "detached-apply.sh: invalid decrypted vars path" >&2
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
  [ -z "$GREASEWOOD_TOKEN_FILE" ] || rm -f -- "$GREASEWOOD_TOKEN_FILE"
}
trap cleanup EXIT HUP INT TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WELCOME_DECRYPTED_VARS_FILE="$VARS_FILE" "$ROOT/apply.sh" "$@"

if [ -n "$GREASEWOOD_TOKEN_FILE" ]; then
  GREASEWOOD_TOKEN="$(<"$GREASEWOOD_TOKEN_FILE")"
  rm -f -- "$GREASEWOOD_TOKEN_FILE"
  if [ -n "$GREASEWOOD_TOKEN" ]; then
    gw join "$GREASEWOOD_TOKEN"
  fi
  unset GREASEWOOD_TOKEN
fi
