#!/usr/bin/env bash
# D11 axis 3: PSS with warm WebViews. Two launches:
#   warm0 — 1 active WebView (baseline)
#   warm3 — 1 active + 3 warm mounted-undestroyed WebViews (4 total, the 3-4 band)
# Marginal per warm WebView = (PSS_warm3 - PSS_warm0) / 3.
# Usage: scripts/run-memory.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_device
echo "memory: warm0 baseline"
launch inline 0
wait_for_log "\[BPSPIKE\] cold-load variant=inline" 30 >/dev/null
sleep 3 # let allocation settle
adb shell dumpsys meminfo "$PKG" > "$RESULTS/memory-warm0.meminfo"

echo "memory: warm3 (1 active + 3 warm)"
launch inline 3
wait_for_log "\[BPSPIKE\] warm-ready count=3" 60 >/dev/null
sleep 3
adb shell dumpsys meminfo "$PKG" > "$RESULTS/memory-warm3.meminfo"

adb shell am force-stop "$PKG"
echo "done: $RESULTS/memory-warm0.meminfo + memory-warm3.meminfo"
