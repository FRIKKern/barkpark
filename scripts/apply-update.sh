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
  exit 0
fi

echo "[apply-update] no usable precompiled artifact — on-box rebuild"
exec bash scripts/deploy-rebuild.sh
