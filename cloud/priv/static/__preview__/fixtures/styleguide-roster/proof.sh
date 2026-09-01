#!/usr/bin/env bash
# proof.sh — the PERMANENT mutation proof for cssom-parity.mjs's ROSTER and its
# HTML-inline-<style> extractor.
#
# Sibling of ../cssom-floor/proof.sh, and built the same way and for the same
# reason: against COMMITTED fixtures, so it is reproducible forever and never
# depends on a one-liner still matching a live file that has since been edited.
#
# WHAT IT GUARDS. Through wave 7 the gate certified app.css alone, while
# cloud/priv/static/styleguide.html shipped an inline <style> sheet and sat in the
# Plug.Static `only:` allowlist — genuinely served, parsed by nothing. The roster
# closed that. These four cases are the ways the roster can go wrong, and each one
# must speak in the gate's own vocabulary: 0 = certified, 1 = a MEASURED defect in
# a stylesheet, 2 = REFUSED TO MEASURE, an environment fact.
#
#   1. GREEN   clean.html      8 heads == baseline 8, MISSES 0            -> exit 0
#   2. RED     swallowed.html  the #4592 defect, one `/*` opener removed  -> exit 1
#   3. REFUSE  a rostered path that is not on disk                        -> exit 2
#   4. REFUSE  nostyle.html    the document survives, its sheet does not  -> exit 2
#
# Case 4 is the one worth naming. A roster entry whose file no longer carries the
# sheet the entry CLAIMS is not a clean sheet — reporting `0 heads · MISSES 0 ·
# PARITY PASS` over an absent population reads as coverage and is the absence of
# it, which is precisely the blindness the roster was added to close. It refuses.
#
# clean.html also carries an HTML comment whose PROSE mentions `<style>`, and that
# is deliberate: a scan that does not blank HTML comments starts its match there
# and swallows the whole comment into the first prelude. Measured before the fix:
# the CLEAN fixture reported 3 MISSES and a COUNT SKEW — the gate accusing a
# stylesheet with nothing wrong with it. Case 1 is that regression test.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/../../cssom-parity.mjs"
BASELINE="$DIR/heads.baseline"

echo "=== 1. GREEN: clean fixture must PASS (8 heads == baseline, MISSES 0) ==="
CSS="$DIR/clean.html" HEADS_BASELINE="$BASELINE" node "$GATE"
green=$?
echo "green exit: $green"
echo

echo "=== 2. RED: the #4592 swallow must be MEASURED, and must name :root ==="
CSS="$DIR/swallowed.html" HEADS_BASELINE="$BASELINE" node "$GATE"
red=$?
echo "red exit: $red"
echo

echo "=== 3. REFUSE: a rostered file that is not on disk ==="
CSS="$DIR/no-such-file.html" HEADS_BASELINE="$BASELINE" node "$GATE"
gone=$?
echo "missing exit: $gone"
echo

echo "=== 4. REFUSE: the document is there, the inline sheet is not ==="
CSS="$DIR/nostyle.html" HEADS_BASELINE="$BASELINE" node "$GATE"
empty=$?
echo "empty exit: $empty"
echo

if [ "$green" -eq 0 ] && [ "$red" -eq 1 ] && [ "$gone" -eq 2 ] && [ "$empty" -eq 2 ]; then
  echo "PROOF OK — 0/1/2/2: the roster certifies an inline sheet, reds a swallow in it,"
  echo "and REFUSES rather than greening a sheet it cannot measure."
  exit 0
fi
echo "PROOF FAILED — expected green=0 red=1 missing=2 empty=2," >&2
echo "               got green=$green red=$red missing=$gone empty=$empty" >&2
exit 1
