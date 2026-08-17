#!/usr/bin/env bash
# Paper-excellence render gate — hermetic: no server, no database, no network.
#
#   bash tooling/paper-excellence/rig/gate.sh [fixture.json] [out-dir]
#
# Renders a COMMITTED fixture through the real PortableDoc renderer + the real
# bulldocs layout, photographs it at 6 (scheme x width) cells, and exits
# NONZERO the moment a content assertion fails. Every assertion is on DOM
# content, never on an HTTP status.
#
# Red-before proof (2026-08-12, worktree wf_b6bfe6c9-2b7-34): mutating the
# LiveView wrapper class list in api/lib/barkpark_web/live/bulldocs_live.ex
# from "bp-paper-shell" to "bp-paper-shellX" made this gate exit 1 with
# `rig/render: FAIL — wrapper drift: … now renders ["bp-paper-shellX", …]`;
# reverting the mutation made it exit 0 again.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RIG_DIR/../../.." && pwd)"

FIXTURE="${1:-$RIG_DIR/fixtures/heggemsnes-act.json}"
OUT_DIR="${2:-${TMPDIR:-/tmp}/bp-paper-rig}"
LABEL="$(basename "$FIXTURE" .json)"
RENDERED="$OUT_DIR/$LABEL.html"

mkdir -p "$OUT_DIR"

echo "rig/gate: fixture $FIXTURE"

# 1. Hermetic render. MIX_ENV=test + --no-start: the Repo never starts and the
#    Endpoint never opens a socket (config/test.exs sets server: false).
#    CC=clang because a `cc` shell alias can shadow the C compiler here.
( cd "$REPO_ROOT/api" && CC=clang MIX_ENV=test mix run --no-start \
    "$RIG_DIR/render.exs" "$FIXTURE" "$RENDERED" )

# 2. Screenshot + DOM-content assertions.
node "$RIG_DIR/shoot.mjs" "$RENDERED" "$OUT_DIR/shots" "$LABEL"

SHOT_COUNT="$(find "$OUT_DIR/shots" -type f \( -name '*.png' -o -name '*.jpeg' \) | wc -l | tr -d ' ')"
echo "rig/gate: PASS — $RENDERED + $SHOT_COUNT shots in $OUT_DIR/shots"
