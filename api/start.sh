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

# --- name-encoding pin (start) ---
# Pin the VM's filename encoding mode instead of inheriting it from the host
# image; the slot unit (deploy/systemd/barkpark-slot@.service) pins the same
# value for the service, this arm covers a MANUAL `api/start.sh mix …` too.
# MEASURED on the live box: file:native_name_encoding() is utf8 only BY
# ACCIDENT — the slot unit carried no Environment= at all and LANG=en_US.UTF-8
# arrived from /etc/default/locale through systemd's MANAGER environment (read
# /proc/<MainPID>/environ; `systemctl show -p Environment` prints an empty
# Environment= that answers nothing, and neither .env nor .slots/<slot>.env
# mentions LANG). Replaying that environ under `env -i` returns utf8; stripping
# LANG returns latin1 from the same erl, with Elixir printing "the VM is running
# with native name encoding of latin1 which may cause Elixir to malfunction"
# (LANG=C is latin1 too). A fresh Hetzner image without /etc/default/locale
# therefore boots this code in latin1.
#
# WHAT THIS IS *NOT* FOR: it is not a staging fix. Site staging already works in
# BOTH name modes — the deployed stage/4 beams staged accented NFC (636166c3a9)
# and NFD (63616 5cc81) filenames byte-exactly on ext4 with LANG unset, because
# the extractor passes BINARY paths straight through and never reads a staged
# name back. This pins the MODE to protect the REST of the VM, which was never
# audited for latin1 sensitivity. Do not "revert the unnecessary locale line".
#
# MEASUREMENT TRAP: an Elixir readback of a staged filename measures the
# DECODER, not the disk — in utf8 mode :file.list_dir_all/1 returns decoded
# codepoint lists, U+0301 makes iolist_to_binary/1 RAISE, and Erlang's Darwin
# read path reports NFC for bytes that are genuinely NFD on disk. Read staged
# names with shell find/od, never from the VM.
#
# C.UTF-8 ships on Ubuntu 24.04 without a locale package. An operator value
# (unit, environment, or .env sourced above) WINS — this only fills a hole.
if [ -z "${LC_ALL:-}" ] && [ -z "${LANG:-}" ]; then
  export LANG=C.UTF-8
fi
# --- name-encoding pin (end) ---

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
