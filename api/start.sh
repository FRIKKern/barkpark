#!/bin/bash
# Wrapper script for systemd — sources ASDF and env before starting Phoenix.
# systemd can't use ASDF shims directly because they need a shell env.
set -euo pipefail

export PATH="/root/.asdf/bin:/root/.asdf/shims:/usr/local/go/bin:$PATH"
if [ -f /root/.asdf/asdf.sh ]; then
  . /root/.asdf/asdf.sh
fi

cd "$(dirname "$0")"

if [ -f ../.env ]; then
  set -a
  source ../.env
  set +a
fi

# Blue/green slots (barkpark-slot@.service via deploy/instance-deploy.sh) pin
# their own listen port AFTER .env so two slots can serve side by side; .env
# stays the single source for everything else.
if [ -n "${BARKPARK_PORT_OVERRIDE:-}" ]; then
  export PORT="$BARKPARK_PORT_OVERRIDE"
fi

export MIX_ENV=prod

case "${1:-}" in
  rotate-public-read)
    exec mix barkpark.rotate_public_read
    ;;
  mix)
    shift
    exec mix "$@"
    ;;
  *)
    export PHX_SERVER=true
    exec mix phx.server
    ;;
esac
