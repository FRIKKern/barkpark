#!/usr/bin/env bash
# Self-test for parse-results.mjs against the synthetic fixtures — proves the
# raw-output -> verdict-table path with NO device attached. The fixture plants
# a janky-% FAIL on purpose, so the expected overall is FAIL (exit 2).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# .log.fixture dodges the repo-root *.log gitignore; restore real names in TMP.
cp "$HERE/fixtures/cold-load-inline.log.fixture" "$TMP/cold-load-inline.log"
cp "$HERE/fixtures/cold-load-file.log.fixture" "$TMP/cold-load-file.log"
cp "$HERE"/fixtures/*.framestats "$HERE"/fixtures/*.meminfo "$HERE"/fixtures/device.txt "$TMP/"

set +e
OUT=$(BPSPIKE_RESULTS_DIR="$TMP" node "$HERE/parse-results.mjs" 2>&1)
CODE=$?
set -e

fail=0
check() {
  if echo "$OUT" | grep -qE "$1"; then
    echo "  [PASS] $2"
  else
    echo "  [FAIL] $2 — pattern not found: $1"
    fail=1
  fi
}

echo "parse-results self-test:"
check 'P50 \(inline, n=10\) +445 .*PASS' 'cold-load P50 = 445 ms PASS'
check 'P95 \(inline\) +880 .*PASS' 'cold-load P95 = 880 ms PASS'
check 'avg fps \(179 frames / 3 sections\) +69.4 .*PASS' 'multi-section framestats aggregated (179 frames / 3 per-swipe sections)'
check 'janky % \(>16.6 ms\) +24 .*FAIL' 'planted janky FAIL detected (24.0%)'
check 'frames > 100 ms +0 .*PASS' 'zero frames > 100 ms'
check 'total PSS, 4 WebViews \(MB\) +291.2 .*PASS' 'total PSS 291.2 MB PASS'
check 'marginal per warm WebView \(MB\) +49.7 .*PASS' 'marginal 49.7 MB PASS'
check 'file P50 / inline P50 .* 1.1 .*PASS' 'file/inline ratio 1.1 PASS'
check 'OVERALL: FAIL' 'overall FAIL (single-axis FAIL propagates)'
[ "$CODE" -eq 2 ] && echo "  [PASS] exit code 2 on FAIL" || { echo "  [FAIL] exit code $CODE != 2"; fail=1; }
if echo "$OUT" | grep -q 'ADVISORY'; then
  echo "  [FAIL] release+hardware fixture must NOT be marked advisory"
  fail=1
else
  echo "  [PASS] release + real-hardware fixture not marked advisory"
fi

# Debug-build variant of the same fixture must flip the run to ADVISORY (F4).
sed -i.bak 's/^build=release/build=debug/' "$TMP/device.txt"
set +e
OUT_DEBUG=$(BPSPIKE_RESULTS_DIR="$TMP" node "$HERE/parse-results.mjs" 2>&1)
set -e
if echo "$OUT_DEBUG" | grep -q 'DEBUG APK — ADVISORY ONLY'; then
  echo "  [PASS] debug APK flips the run to ADVISORY"
else
  echo "  [FAIL] debug APK did not flip the run to ADVISORY"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "self-test: all checks passed" || { echo "self-test FAILED"; exit 1; }
