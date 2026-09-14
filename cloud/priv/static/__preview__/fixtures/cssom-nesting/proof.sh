#!/usr/bin/env bash
# proof.sh — the PERMANENT mutation proof for cssom-parity.mjs's FATAL COUNT SKEW.
#
# THE EXPOSURE THIS CLOSES (gr-blk-cssom-parity-harden). COUNT SKEW used to be
# print-only. The gate exited on misses, multiset deficits and the baseline ratchet,
# and skew — the signal that says THE PARSER IS READING A DIFFERENT POPULATION THAN
# THE BROWSER — only printed. A sheet could therefore skew while every other signal
# stayed silent, and the run announced the problem and then exited 0 anyway. Once
# `Console gate` is a required context that is an unproven 0 wearing a required
# check's name: a stylesheet nobody measured, certified.
#
# Skew was advisory for a real reason, and the reason had to be removed before the
# promotion was honest: authoredHeads() could not descend into style-rule bodies, so
# the FIRST commit to adopt CSS nesting would have reddened the gate over a parser
# gap rather than a CSS defect — and a gate that reds on the wrong thing is disabled
# within a wave. The parser now models nesting (clean.css proves it), so a skew is
# once again evidence rather than noise, and the arm can refuse.
#
#   GREEN: clean.css              — 17 authored heads, 17 CSSOM rules   -> exit 0
#   RED:   unmodelled-at-rule.css — 17 authored heads, 18 CSSOM rules   -> exit 1
#
# Both against the SAME baseline (17), which is what makes this proof about skew and
# nothing else: the ratchet is held constant and MATCHES in both runs, so it cannot
# be the thing that reds the second one.
#
# THE RED FIXTURE REPRODUCES PARSER DRIFT RATHER THAN SIMULATING IT. Its only
# difference from clean.css is an `@starting-style` block — a real grouping at-rule
# Chrome parses, deliberately absent from GROUPING_AT. The authored side skips it as
# opaque; the CSSOM walk descends into it. MISSES stays 0 because the extra rule is
# on the BROWSER side and misses are authored-minus-CSSOM, so no other signal in the
# file can see it.
#
# Measured on origin/main @ c42fde07c under Chrome 153.0.8010.36: the RED fixture
# exited 0 with `PARITY PASS`. That is the false green this proof exists to keep closed.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/../../cssom-parity.mjs"
BASELINE="$DIR/heads.baseline"

echo "=== GREEN: nesting fixture must PASS (authored heads == CSSOM rules) ==="
CSS="$DIR/clean.css" HEADS_BASELINE="$BASELINE" node "$GATE"
green=$?
echo "green exit: $green"
echo

echo "=== RED: an at-rule the parser does not model must FAIL (skew, MISSES 0, baseline matches) ==="
CSS="$DIR/unmodelled-at-rule.css" HEADS_BASELINE="$BASELINE" node "$GATE"
red=$?
echo "red exit: $red"
echo

if [ "$green" -eq 0 ] && [ "$red" -eq 1 ]; then
  echo "PROOF OK — clean=0 skewed=1: a parser that no longer models the sheet now reds instead of certifying it."
  exit 0
fi
echo "PROOF FAILED — expected green=0 red=1, got green=$green red=$red" >&2
exit 1
