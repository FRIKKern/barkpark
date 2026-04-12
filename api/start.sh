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

export MIX_ENV=prod
export PHX_SERVER=true

exec mix phx.server
