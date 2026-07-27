#!/usr/bin/env bash
# Runs on the target under a transient systemd service.
set -euo pipefail

VARS_FILE="${WELCOME_DECRYPTED_VARS_FILE:-}"
case "$VARS_FILE" in
  /run/welcome/*.yml) ;;
  *)
    echo "detached-apply.sh: invalid decrypted vars path" >&2
    exit 2
    ;;
esac

cleanup() {
  rm -f -- "$VARS_FILE"
}
trap cleanup EXIT HUP INT TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WELCOME_DECRYPTED_VARS_FILE="$VARS_FILE" "$ROOT/apply.sh" "$@"
