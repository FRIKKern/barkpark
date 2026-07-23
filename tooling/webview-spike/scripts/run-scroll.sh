#!/usr/bin/env bash
# D11 axis 2: full-document scroll via dumpsys gfxinfo framestats.
# The WebView renders in-process on modern Android, so the app package's
# gfxinfo covers WebView-driven frames.
# Usage: scripts/run-scroll.sh [inline|file] [swipes=10]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VARIANT=${1:-inline}
SWIPES=${2:-10}
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

adb shell dumpsys gfxinfo "$PKG" reset >/dev/null
for i in $(seq 1 "$SWIPES"); do
  adb shell input swipe "$X" "$Y1" "$X" "$Y2" 250
  sleep 0.4
done
# A couple of upward swipes so the pass covers both directions.
for i in 1 2; do
  adb shell input swipe "$X" "$Y2" "$X" "$Y1" 250
  sleep 0.4
done
adb shell dumpsys gfxinfo "$PKG" framestats > "$OUT"
adb shell am force-stop "$PKG"
echo "done: framestats in $OUT"
