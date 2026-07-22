#!/usr/bin/env bash
# proof.sh — the PERMANENT mutation proof for cssom-parity.mjs's exact-match ratchet.
#
# Unlike D20's one-time "insert a /*, run, revert" proof, this runs against COMMITTED
# fixtures and is reproducible forever. It shows the ratchet reds a swallow that sits
# ABOVE app.css's live baseline (1203) — the exact decay case a static floor misses.
#
#   GREEN: heads.css (1300 heads) vs heads.baseline (1300)            -> exit 0
#   RED:   heads.swallowed.css (1240 heads) vs the SAME baseline 1300 -> exit 1
#
# The swallow drops 1300 -> 1240; 1240 is still 37 above app.css's baseline, so a
# `>=` floor of 1201/1203 would have PASSED it. The exact-match ratchet reds it.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/../../cssom-parity.mjs"
BASELINE="$DIR/heads.baseline"

echo "=== GREEN: clean fixture must PASS (count == baseline) ==="
CSS="$DIR/heads.css" HEADS_BASELINE="$BASELINE" node "$GATE"
green=$?
echo "green exit: $green"
echo

echo "=== RED: swallowed fixture must FAIL (count < baseline, MISSES still 0) ==="
CSS="$DIR/heads.swallowed.css" HEADS_BASELINE="$BASELINE" node "$GATE"
red=$?
echo "red exit: $red"
echo

if [ "$green" -eq 0 ] && [ "$red" -eq 1 ]; then
  echo "PROOF OK — clean=0 swallowed=1: the exact-match ratchet reds a swallow above the app.css floor."
  exit 0
fi
echo "PROOF FAILED — expected green=0 red=1, got green=$green red=$red" >&2
exit 1
