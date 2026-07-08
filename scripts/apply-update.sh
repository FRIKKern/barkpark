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
  exit 0
fi

echo "[apply-update] no usable precompiled artifact — on-box rebuild"
exec bash scripts/deploy-rebuild.sh
