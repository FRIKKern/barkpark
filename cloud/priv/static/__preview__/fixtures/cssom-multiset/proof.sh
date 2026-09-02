#!/usr/bin/env bash
# proof.sh — the PERMANENT mutation proof for cssom-parity.mjs's MULTISET comparison.
#
# The exposure this closes (gr-backlog-cssom-parity-count-skew): both sides of the
# diff used to be SETS — the authored side a Map with an explicit first-wins, the
# CSSOM side a `new Set()` — so a selector authored twice needed only ONE of its two
# rules to reach the browser for MISSES to stay 0. The head count cannot see it
# either (the source still authors both), and COUNT SKEW is advisory by design.
#
#   RED:   duplicate-hidden.css — `.alpha` authored 2x, in the CSSOM 1x  -> exit 1
#   GREEN: clean.css            — `.alpha` authored 2x, in the CSSOM 2x  -> exit 0
#
# Both against the SAME baseline (3), so the count assertion is held constant and the
# multiset comparison is the only thing that can differ between the two runs.
#
# Measured on origin/main @ fc6ecdfdd6, Chrome 152.0.7977.65: the RED fixture exited
# 0 with `PARITY PASS`. That is the false green this proof exists to keep closed.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/../../cssom-parity.mjs"
BASELINE="$DIR/heads.baseline"

echo "=== GREEN: clean fixture must PASS (both .alpha occurrences reach the CSSOM) ==="
CSS="$DIR/clean.css" HEADS_BASELINE="$BASELINE" node "$GATE"
green=$?
echo "green exit: $green"
echo

echo "=== RED: duplicate-hidden fixture must FAIL (MISSES 0, count matches, deficit 1) ==="
CSS="$DIR/duplicate-hidden.css" HEADS_BASELINE="$BASELINE" node "$GATE"
red=$?
echo "red exit: $red"
echo

if [ "$green" -eq 0 ] && [ "$red" -eq 1 ]; then
  echo "PROOF OK — clean=0 hidden=1: a rule lost behind its own duplicate now reds."
  exit 0
fi
echo "PROOF FAILED — expected green=0 red=1, got green=$green red=$red" >&2
exit 1
