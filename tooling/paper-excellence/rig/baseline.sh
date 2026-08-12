#!/usr/bin/env bash
# Re-capture the committed baseline panel (rig/baselines/) from the committed
# fixtures. Same hermetic path as the gate — render, then shoot — but it writes
# into the repo instead of a temp dir, so the diff of a baseline refresh is
# reviewable.
#
#   bash tooling/paper-excellence/rig/baseline.sh [slug …]
#
# Re-baseline whenever the renderer, the paper CSS, or a fixture changes — and
# ALWAYS inside the same image the gate will run in (font fallback is
# host-dependent; see README).
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RIG_DIR/../../.." && pwd)"
OUT_DIR="$RIG_DIR/baselines"
WORK="${TMPDIR:-/tmp}/bp-paper-baseline"

SLUGS=("$@")
if [ ${#SLUGS[@]} -eq 0 ]; then
  SLUGS=(heggemsnes-act hobby-hardening-capstone mechanical-spacing-doctrine \
         paper-excellence-wave-2026-08-12 portabledoc-showcase)
fi

mkdir -p "$OUT_DIR" "$WORK"
for slug in "${SLUGS[@]}"; do
  ( cd "$REPO_ROOT/api" && CC=clang MIX_ENV=test mix run --no-start \
      "$RIG_DIR/render.exs" "$RIG_DIR/fixtures/$slug.json" "$WORK/$slug.html" )
  # Committed panel = full-page, 2x, light+dark, 1440 only, JPEG q72.
  # Measured on this panel: PNG 166 MB, JPEG q82 all-widths 54 MB, this set
  # 11 MB. The 768/360 cells still run in the gate — they are just not carried
  # in the repo. See README §Baselines.
  SHOT_FORMAT="${SHOT_FORMAT:-jpeg}" \
  SHOT_QUALITY="${SHOT_QUALITY:-72}" \
  SHOT_WIDTHS="${SHOT_WIDTHS:-1440}" \
    node "$RIG_DIR/shoot.mjs" "$WORK/$slug.html" "$OUT_DIR" "$slug"
done

echo "rig/baseline: $(find "$OUT_DIR" -type f \( -name '*.jpeg' -o -name '*.png' \) | wc -l | tr -d ' ') shots in $OUT_DIR"
