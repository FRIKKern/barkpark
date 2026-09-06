#!/usr/bin/env bash
#
# landed-open-report.test.sh — the MUTATION harness for scripts/landed-open-report.sh.
#
# `--selftest` proves the reader passes its own assertions. This proves those
# assertions are LOAD-BEARING: each mutation below breaks exactly one arm in a
# scratch copy and REQUIRES the selftest to go RED. A guard whose selftest
# stays green when the guard is deleted is theatre, and this repo has shipped
# that twice.
#
# Every mutation is asserted to have APPLIED — the anchor must appear EXACTLY
# ONCE and the resulting diff must be non-empty — because a mutation that did
# not build is not a catch: the selftest would go red for the wrong reason, or
# stay green while the mutation silently no-op'd.
#
#   bash scripts/landed-open-report.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$ROOT/scripts/landed-open-report.sh"
PY="$ROOT/scripts/lib/landed_open_report.py"

WORK="$(mktemp -d -t landed-open-report-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
PASS=0

# $1 label · $2 file-under-scratch (sh|py) · $3 anchor · $4 replacement
mutate_must_red() {
  local label="$1" which="$2" anchor="$3" repl="$4"
  local dir="$WORK/m$$RANDOM"
  mkdir -p "$dir/scripts/lib"
  cp "$SH" "$dir/scripts/landed-open-report.sh"
  cp "$PY" "$dir/scripts/lib/landed_open_report.py"
  local target="$dir/scripts/landed-open-report.sh"
  [ "$which" = "py" ] && target="$dir/scripts/lib/landed_open_report.py"

  # THE MUTATION MUST HAVE APPLIED. Count the anchor and diff the result;
  # a zero-hit or multi-hit anchor is a harness defect, not a caught bug.
  local hits
  hits="$(python3 -c 'import sys;print(open(sys.argv[1]).read().count(sys.argv[2]))' "$target" "$anchor")"
  if [ "$hits" != "1" ]; then
    echo "HARNESS FAIL [$label]: anchor matched $hits times, want exactly 1"
    FAIL=$((FAIL + 1)); return
  fi
  python3 -c '
import sys
p,a,r=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
open(p,"w").write(s.replace(a,r,1))
' "$target" "$anchor" "$repl"
  if cmp -s "$target" "${SH}" && [ "$which" = "sh" ]; then
    echo "HARNESS FAIL [$label]: mutation left the file byte-identical"
    FAIL=$((FAIL + 1)); return
  fi

  local out rc
  out="$(bash "$dir/scripts/landed-open-report.sh" --selftest 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL [$label]: the selftest stayed GREEN with this arm broken — the assertion is not load-bearing"
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
    echo "ok   [$label] selftest went red (exit $rc)"
  fi
}

# 0. The unmutated pair must be GREEN, or every red below is meaningless.
if ! bash "$SH" --selftest >/dev/null 2>&1; then
  echo "HARNESS FAIL: the UNMUTATED selftest is already red. Nothing below proves anything."
  exit 1
fi
echo "ok   [baseline] unmutated selftest is green"
PASS=$((PASS + 1))

# 1. THE LIVE FILTER. If every landed row counts as live, done rows leak into
#    the debt list and the report becomes a changelog.
mutate_must_red "live-filter" py \
  '"live": lifecycle in LIVE,' \
  '"live": True,'

# 2. THE LABEL FILTER. If the class label stops gating, the report lists the
#    whole ledger — the loudest possible false positive.
mutate_must_red "label-filter" py \
  'if LANDED_CLASS not in labels:' \
  'if False:'

# 3. THE PAGE-ACCOUNTING ASSERTION. This is the arm that catches a walk which
#    silently drops rows while printing a tidy count.
mutate_must_red "page-accounting" sh \
  'if [ "$returned" -ge 0 ] && [ "$docs_len" -ne "$returned" ]; then' \
  'if false; then'

# 4. THE `docs` ARRAY-NAME CHECK. Keyed on `.tasks` this returns a confident
#    zero at exit 0 — the original defect.
mutate_must_red "docs-array-check" py \
  'if not isinstance(docs, list):' \
  'if False:
        pass
    elif False:'

# 5. THE MIN-POPULATION FLOOR — the positive control. Disarm it and a reader
#    that has gone blind reports a clean ledger.
mutate_must_red "min-population-floor" sh \
  'if [ "$LABELLED" -lt "$MIN_POPULATION" ]; then' \
  'if false; then'

# 6. THE MIXED-SHAPE LABEL NORMALISER. Objects carrying {tag,...} must not be
#    stringified into never-matching junk.
mutate_must_red "label-normaliser" py \
  '            tag = item.get("tag")' \
  '            tag = item.get("nope")'

# 7. THE FALSE-POSITIVE FLAGS. A report that stops flagging PARENT/GATE? rows
#    invites a lead to close an epic a single PR merely contributed to.
mutate_must_red "false-positive-flags" py \
  '    flags = []' \
  '    return []
    flags = []'

# 8. THE BOOLEAN READ. `met` must be tested for `is True`; a truthy read would
#    count a met:"false" string as met and inflate the discharge tally.
mutate_must_red "met-boolean" py \
  '        if c.get("met") is True:' \
  '        if c.get("met") is not None:'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "landed-open-report.test.sh: $PASS/$PASS mutations caught — every assertion is load-bearing"
  exit 0
fi
echo "landed-open-report.test.sh: $FAIL of $((PASS + FAIL)) arms are NOT load-bearing"
exit 1
