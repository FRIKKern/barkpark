#!/usr/bin/env bash
# D11 axis 1 + 4: cold-load to first meaningful paint, N runs per variant.
# Usage: scripts/run-cold-load.sh <inline|file> [runs=10]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VARIANT=${1:?usage: run-cold-load.sh <inline|file> [runs]}
RUNS=${2:-10}
OUT="$RESULTS/cold-load-$VARIANT.log"
: > "$OUT"

require_device
echo "cold-load: variant=$VARIANT runs=$RUNS -> $OUT"
for i in $(seq 1 "$RUNS"); do
  launch "$VARIANT" 0
  line=$(wait_for_log "\[BPSPIKE\] cold-load variant=$VARIANT" 30)
  echo "$line" | grep -oE "cold-load variant=$VARIANT rn_ms=[0-9]+ dom_ms=[0-9]+" >> "$OUT"
  echo "  run $i/$RUNS: $line"
done
adb shell am force-stop "$PKG"
echo "done: $(wc -l < "$OUT" | tr -d ' ') samples in $OUT"
