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
  # eight-minute-erasure joined the panel with the air scale (pe-w1-air-beat): it
  # is the ONE committed fixture carrying all six evidence kinds at once — table,
  # stats, figure, code, callout, asciicast — so an evidence-spacing regression
  # shows up here in a single shot instead of across five papers.
  #
  # design-probe joined with pe-w1-section-lever and is the ONE authored fixture
  # (BPML, no published paper behind it — see its `_source`). It carries the three
  # shapes the six real papers do not: `section` CONTAINERS with eyebrow+h2 heads,
  # consecutive containers stacking a doubled boundary rule, and a content-narrow
  # table whose ink pins to the band's left edge while its box stays centred. All
  # three are measured and none asserted, so it is the fixture an open finding
  # gets closed against.
  #
  # stat-partial-row joined with the slab remedy (task-0098ba55d2642545, charter
  # D36) and is the SECOND authored fixture: two eleven-stat strips (a prime
  # count, so the last row is partial at every band width — 8+3 @1280, 9+2
  # @1920) and the `statRemainder` probe has an empty track to stand on. No
  # published paper leaves a partial row, which is why the slab shipped unseen.
  SLUGS=(design-probe eight-minute-erasure heggemsnes-act hobby-hardening-capstone \
         mechanical-spacing-doctrine paper-excellence-wave-2026-08-12 \
         portabledoc-showcase stat-partial-row)
fi

mkdir -p "$OUT_DIR" "$WORK"
for slug in "${SLUGS[@]}"; do
  ( cd "$REPO_ROOT/api" && CC=clang MIX_ENV=test mix run --no-start \
      "$RIG_DIR/render.exs" "$RIG_DIR/fixtures/$slug.json" "$WORK/$slug.html" )
  # Committed panel = full-page, 2x, light+dark, 1280 + 1920, JPEG q72.
  # Measured on this panel: PNG 166 MB, JPEG q82 all-widths 54 MB, this set
  # 11 MB per width. The 768/360 cells still run in the gate — they are just not
  # carried in the repo. See README §Baselines.
  #
  # 1440 was replaced by the PAIR 1280 + 1920 with pe-w1-evidence-breakout. The
  # evidence band sits at its 1040px base anywhere from ~1120px to 1600px and
  # only grows above that, so a single 1440 cell could never show the band
  # moving — it is the same picture as 1280. The pair is the smallest panel that
  # carries BOTH ends of the band's range, and each `<slug>.report.json` now
  # records the measured band width and prose CPL per cell, so a re-baseline
  # diffs as NUMBERS and not only as JPEGs.
  SHOT_FORMAT="${SHOT_FORMAT:-jpeg}" \
  SHOT_QUALITY="${SHOT_QUALITY:-72}" \
  SHOT_WIDTHS="${SHOT_WIDTHS:-1280,1920}" \
    node "$RIG_DIR/shoot.mjs" "$WORK/$slug.html" "$OUT_DIR" "$slug"
done

echo "rig/baseline: $(find "$OUT_DIR" -type f \( -name '*.jpeg' -o -name '*.png' \) | wc -l | tr -d ' ') shots in $OUT_DIR"
