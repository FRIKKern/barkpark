#!/usr/bin/env bash
#
# apply-update.sh — the box's update entrypoint (task precompiled-artifacts).
# Prefer the CI-precompiled artifact for the current HEAD (fast fetch + swap, no
# on-box compile); on ANY reason it isn't usable, fall back to the full on-box
# rebuild — so a deploy is never worse than today, only faster on the happy path.
#
# Called by the freshen rebuild path (internal/cli/cloud/freshen.go) AFTER the
# checkout has fast-forwarded to origin/main, so HEAD is the target sha.
set -uo pipefail

cd "$(dirname "$0")/.."

# Go toolchain PATH, exactly as deploy/instance-deploy.sh:147 exports it. This
# script runs over a bare NON-LOGIN ssh, where /etc/profile.d never sources and
# `command -v go` finds NOTHING on every box (guerrilla included) even though
# /usr/local/go/bin/go is installed on all of them. Without this line every
# `command -v go` guard below silently takes its skip branch.
#
# HOME is defaulted rather than referenced bare: this script runs under
# `set -u`, so an unset HOME (a systemd unit without one, a stripped `env -i`
# invocation) would abort the ENTIRE deploy at this line — before any work —
# and the only thing a fallback loses is the asdf shim dir, which the boxes all
# have at /root/.asdf (deploy-rebuild.sh hardcodes exactly that path).
export PATH="${HOME:-/root}/.asdf/shims:/usr/local/go/bin:$PATH"

# Rebuild + re-exec the on-box monitoring agent from the just-deployed code.
# Lifted from deploy/instance-deploy.sh:806-830, which is the ONLY lane that has
# ever built barkpark-agent — so on every box that self-updates instead of being
# re-provisioned, the agent binary is frozen at warm-pool arm time and any new
# vital it learns to report stays dark forever (measured: `cpu_cores` present in
# 1 of 6 fleet binaries, with `load1` present in 6 of 6 as the non-vacuous
# control). Blessing a fresher release tag cannot fix that: no self-update path
# builds the agent at all.
#
# Only touches boxes the provisioner ARMED with the agent (its token file
# exists); a plain/legacy box is left alone. The control/health URLs live in
# /etc/barkpark/agent.env from provision time, so this needs no knowledge of
# them. NON-FATAL by construction — the whole sequence is an `if` condition, so
# a monitoring hiccup can never fail a deploy.
refresh_agent() {
  [ -f /etc/barkpark/agent.token ] || return 0
  echo "[apply-update] refreshing barkpark-agent (monitoring beat, non-fatal)..."
  # RESTART, never `enable --now`: `--now` is `start`, a NO-OP on an already-
  # active unit, so systemd never re-execs and the running agent keeps serving
  # the DELETED inode of the binary we just replaced (measured 29h stale on
  # guerrilla — the bug #9823 fixed for the slot path).
  # Build to a tmpdir and `install` (not `go build -o` straight onto the live
  # path): install(1) unlinks first, so a RUNNING barkpark-agent never
  # ETXTBSY-blocks its own refresh — the idiom instance-deploy.sh's barkpark-mcp
  # block established (dr-w4-bl-agent-build-in-place-can-etxtbsy).
  AGENT_TMPD="$(mktemp -d)"
  if command -v go > /dev/null 2>&1 &&
    go build -o "$AGENT_TMPD/barkpark-agent" ./cmd/barkpark-agent &&
    install -m 0755 "$AGENT_TMPD/barkpark-agent" /usr/local/bin/barkpark-agent &&
    rm -rf "$AGENT_TMPD" &&
    install -m 0644 deploy/systemd/barkpark-agent.service /etc/systemd/system/barkpark-agent.service &&
    systemctl daemon-reload &&
    systemctl enable barkpark-agent > /dev/null 2>&1 &&
    systemctl restart barkpark-agent; then
    echo "[apply-update] barkpark-agent rebuilt, enabled + restarted."
  else
    echo "[apply-update] WARN: barkpark-agent refresh failed — the old agent keeps beating until the next deploy."
  fi
}

SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"

if [ -n "$SHA" ] && bash scripts/fetch-prebuilt.sh "$SHA"; then
  # The precompiled artifact carries api/_build/prod + deps ONLY — NOT the
  # pdrender→TUI wasm the reader lazy-loads (api/priv/static/assets/
  # bp-pdrender.wasm.gz, a source-tree asset dropped from git in #1361 and
  # served by Plug.Static). The on-box-rebuild fallback below runs
  # deploy-rebuild.sh which builds it; this happy path skips deploy-rebuild, so
  # build it here — else the box serves the reader's TUI fallback. Non-fatal,
  # same discipline as deploy-rebuild; a failed build only degrades that view.
  # (Static asset — no restart needed to pick it up; fetch-prebuilt already
  # restarted.) `make wasm` pins its own Go toolchain via GOTOOLCHAIN.
  echo "[apply-update] building pdrender wasm (non-fatal)..."
  if command -v go >/dev/null 2>&1; then
    if make wasm; then
      echo "[apply-update] pdrender wasm built."
    else
      echo "[apply-update] WARN: pdrender wasm build failed — reader TUI view degrades to its fallback."
    fi
  else
    echo "[apply-update] go not found — skipping pdrender wasm build."
  fi

  refresh_agent
  exit 0
fi

echo "[apply-update] no usable precompiled artifact — on-box rebuild"
exec bash scripts/deploy-rebuild.sh
