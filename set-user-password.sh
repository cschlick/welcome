#!/usr/bin/env bash
# Set user's optional local console/sudo password without committing its hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_YML="$ROOT/ansible/local.yml"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required." >&2
  exit 1
}

read -rsp "New password for user: " PW; echo
read -rsp "Confirm password: " PW2; echo
[ -n "$PW" ] || { echo "Empty password — aborting." >&2; exit 1; }
[ "$PW" = "$PW2" ] || { echo "Passwords did not match — aborting." >&2; exit 1; }

HASH="$(printf '%s' "$PW" | openssl passwd -6 -stdin)"
unset PW PW2

touch "$LOCAL_YML"
chmod 0600 "$LOCAL_YML"
if grep -q '^user_password_hash:' "$LOCAL_YML"; then
  sed -i "s|^user_password_hash:.*|user_password_hash: '$HASH'|" "$LOCAL_YML"
else
  printf "user_password_hash: '%s'\n" "$HASH" >> "$LOCAL_YML"
fi
unset HASH

echo "Updated $LOCAL_YML (gitignored)."
echo "Re-run apply.sh to apply it; sudo will require this password by default."
