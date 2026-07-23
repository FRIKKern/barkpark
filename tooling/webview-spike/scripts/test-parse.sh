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
check 'janky % \(>16.6 ms\) +26.1 .*FAIL' 'planted janky FAIL detected (26.1%)'
check 'frames > 100 ms +0 .*PASS' 'zero frames > 100 ms'
check 'total PSS, 4 WebViews \(MB\) +291.2 .*PASS' 'total PSS 291.2 MB PASS'
check 'marginal per warm WebView \(MB\) +49.7 .*PASS' 'marginal 49.7 MB PASS'
check 'file P50 / inline P50 .* 1.1 .*PASS' 'file/inline ratio 1.1 PASS'
check 'OVERALL: FAIL' 'overall FAIL (single-axis FAIL propagates)'
[ "$CODE" -eq 2 ] && echo "  [PASS] exit code 2 on FAIL" || { echo "  [FAIL] exit code $CODE != 2"; fail=1; }

[ "$fail" -eq 0 ] && echo "self-test: all checks passed" || { echo "self-test FAILED"; exit 1; }
