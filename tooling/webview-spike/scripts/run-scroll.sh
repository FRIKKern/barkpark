#!/usr/bin/env bash
# D11 axis 2: full-document scroll via dumpsys gfxinfo framestats.
# The WebView renders in-process on modern Android, so the app package's
# gfxinfo covers WebView-driven frames.
#
# framestats retains only a rolling window of ~120 frames, so a single dump at
# the end would grade only the last ~2 s of the pass and systematically miss
# mid-document jank (mermaid/table regions) on the strict 0-frames>100ms axis
# (review F2). Fix: dump + reset AFTER EVERY swipe — each ---PROFILEDATA---
# section is appended to the same file and parse-results.mjs aggregates all
# sections, so EVERY swipe of the pass is graded with no overlap. The default
# of 20 down-swipes (~60% viewport each, flung) is sized to traverse the full
# 104-block document on a typical phone; coverage detail lands in RESULTS.md.
# Usage: scripts/run-scroll.sh [inline|file] [swipes=20]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VARIANT=${1:-inline}
SWIPES=${2:-20}
OUT="$RESULTS/scroll-$VARIANT.framestats"

require_device
echo "scroll: variant=$VARIANT swipes=$SWIPES -> $OUT"
launch "$VARIANT" 0
wait_for_log "\[BPSPIKE\] cold-load variant=$VARIANT" 30 >/dev/null
sleep 1

# Swipe geometry from the real screen size (80% -> 20% height, centered).
SIZE=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
W=${SIZE%x*}; H=${SIZE#*x}
X=$((W / 2)); Y1=$((H * 8 / 10)); Y2=$((H * 2 / 10))

# dump_frames: append this swipe's framestats section, then reset so the next
# capture starts fresh (no duplicate frames across sections).
dump_frames() {
  adb shell dumpsys gfxinfo "$PKG" framestats >> "$OUT"
  adb shell dumpsys gfxinfo "$PKG" reset >/dev/null
}

: > "$OUT"
adb shell dumpsys gfxinfo "$PKG" reset >/dev/null
for i in $(seq 1 "$SWIPES"); do
  adb shell input swipe "$X" "$Y1" "$X" "$Y2" 250
  sleep 0.4
  dump_frames
done
# A couple of upward swipes so the pass covers both directions.
for i in 1 2; do
  adb shell input swipe "$X" "$Y2" "$X" "$Y1" 250
  sleep 0.4
  dump_frames
done
adb shell am force-stop "$PKG"
SECTIONS=$(grep -c -- '---PROFILEDATA---' "$OUT" || true)
echo "done: $((SECTIONS / 2)) per-swipe framestats sections in $OUT"
