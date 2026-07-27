#!/usr/bin/env bash
# Target-side staging helper invoked over an interactive SSH session.
set -euo pipefail

STAGE="${1:-}"
UPLOADED_VARS="${2:-}"
UPLOADED_HOSTNAME="${3:-}"
UPLOADED_GREASEWOOD_TOKEN="${4:-}"
RELEASE_ID="${5:-}"
shift 5 || true
PLAYBOOK_ARGS=("$@")

[[ "$RELEASE_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || {
  echo "launch-detached.sh: invalid release id" >&2
  exit 2
}
[ "$STAGE" = "/tmp/welcome-stage-$RELEASE_ID" ] || exit 2
[ "$UPLOADED_VARS" = "/tmp/welcome-vars-$RELEASE_ID.yml" ] || exit 2
[ "$UPLOADED_HOSTNAME" = "/tmp/welcome-hostname-$RELEASE_ID" ] || exit 2
[ "$UPLOADED_GREASEWOOD_TOKEN" = "/tmp/welcome-greasewood-$RELEASE_ID.token" ] || exit 2

RELEASE="/opt/welcome/releases/$RELEASE_ID"
RUNTIME_VARS="/run/welcome/vars-$RELEASE_ID.yml"
RUNTIME_HOSTNAME="/run/welcome/hostname-$RELEASE_ID"
RUNTIME_GREASEWOOD_TOKEN="/run/welcome/greasewood-$RELEASE_ID.token"
LAUNCHED=0

cleanup() {
  rm -f -- "$UPLOADED_VARS" "$UPLOADED_HOSTNAME" "$UPLOADED_GREASEWOOD_TOKEN"
  if [ "$LAUNCHED" = 0 ]; then
    sudo rm -f -- "$RUNTIME_VARS" "$RUNTIME_HOSTNAME" "$RUNTIME_GREASEWOOD_TOKEN"
    [ ! -d "$STAGE" ] || rm -rf -- "$STAGE"
  fi
}
trap cleanup EXIT HUP INT TERM

if sudo systemctl is-active --quiet welcome-apply.service; then
  echo "A welcome-apply service is already running." >&2
  exit 1
fi

sudo install -d -m 0755 /opt/welcome/releases
sudo install -d -m 0700 /run/welcome
sudo mv -- "$STAGE" "$RELEASE"
sudo chown -R root:root "$RELEASE"
sudo install -m 0600 "$UPLOADED_VARS" "$RUNTIME_VARS"
rm -f -- "$UPLOADED_VARS"
if [ -s "$UPLOADED_HOSTNAME" ]; then
  sudo install -m 0600 "$UPLOADED_HOSTNAME" "$RUNTIME_HOSTNAME"
fi
rm -f -- "$UPLOADED_HOSTNAME"
if [ -s "$UPLOADED_GREASEWOOD_TOKEN" ]; then
  sudo install -m 0600 "$UPLOADED_GREASEWOOD_TOKEN" "$RUNTIME_GREASEWOOD_TOKEN"
fi
rm -f -- "$UPLOADED_GREASEWOOD_TOKEN"
sudo ln -sfn "$RELEASE" /opt/welcome/current

SYSTEMD_ENV=("--setenv=WELCOME_DECRYPTED_VARS_FILE=$RUNTIME_VARS")
if sudo test -s "$RUNTIME_HOSTNAME"; then
  SYSTEMD_ENV+=("--setenv=WELCOME_HOSTNAME_FILE=$RUNTIME_HOSTNAME")
fi
if sudo test -s "$RUNTIME_GREASEWOOD_TOKEN"; then
  SYSTEMD_ENV+=("--setenv=WELCOME_GREASEWOOD_TOKEN_FILE=$RUNTIME_GREASEWOOD_TOKEN")
fi

sudo systemd-run \
  --unit=welcome-apply \
  --description="Welcome Debian hardening" \
  --collect \
  --no-block \
  --property=Type=exec \
  "${SYSTEMD_ENV[@]}" \
  -- \
  "$RELEASE/detached-apply.sh" "${PLAYBOOK_ARGS[@]}"
LAUNCHED=1

echo "Detached hardening started as welcome-apply.service."
