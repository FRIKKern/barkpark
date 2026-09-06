#!/usr/bin/env bash
#
# run-level-reader-census.sh — WHICH READERS ANSWER A PASS/FAIL QUESTION FROM A
# WORKFLOW **RUN** CONCLUSION, WHERE THAT IS A TRUE GREEN ABOUT THE WRONG OBJECT?
#
# THE CLASS
# ---------
# A GitHub Actions RUN conclusion and its JOB conclusions are different facts.
# `continue-on-error: true` makes a job report `failure` while the run it belongs
# to reports `success` — correctly, by design. The green is real. It is simply a
# green about the wrong object. Anything that reads the RUN conclusion to answer
# "did the check pass" therefore reports success over a failed audit, forever,
# with no red anywhere for a human to notice.
#
# Measured, re-derivable (hg-bl-scaffy-served-catalog-drift-and-run-level-lie):
#
#   gh run list --workflow scaffy-catalog-drift --branch main --limit 1
#     -> success, 2026-07-27T13:13, run 30269281675
#   gh run view 30269281675 --json conclusion,jobs
#     -> RUN conclusion: success
#        JOB "served-catalog drift audit (advisory)": failure
#
# At that moment `go run ./scaffy/seed --check` reported `21/22 MATCH, 1 DRIFT`.
# The catalog really was drifted and the only surface anyone reads said success.
#
# scripts/main-gate-watch.sh's own header states the same thing independently:
# "`gh run list` itself launders the red (a run whose Sobelow job concluded
# `failure` reads `success` at the RUN level)".
#
# WHAT THIS IS AND IS NOT
# -----------------------
# A CENSUS, not a fix. It changes no reader's behaviour and re-seeds nothing. It
# answers one question — which readers touch run-level conclusions, and has each
# one been looked at — and it makes the answer impossible to leave un-updated.
# Adjudication lives in .github/run-level-readers.allow, one row per file, each
# carrying a VERDICT and a reason a reviewer can check.
#
# WHY A PER-FILE COUNT AND NOT A LINE NUMBER
# ------------------------------------------
# Line-anchored pins break on insertion: add a line anywhere above and every
# anchor below slides, so the gate reds naming files the diff never touched. The
# allowlist pins a COUNT of run-level source references per file instead. Adding
# one to an already-adjudicated file changes the count and reds; moving code
# around inside it does not.
#
# THIS FILE ADJUDICATES ITSELF
# ----------------------------
# The census matches its own scan patterns and its own selftest fixtures, so it
# appears in its own results. It is adjudicated in the allowlist like everything
# else (verdict CENSUS) rather than excluded from the walk. An exclusion would be
# a blind spot written into the instrument by hand, which is the defect this
# whole file exists to find; a row is checkable, and its count moves if the scan
# patterns are edited.
#
# WHY THE ROW COUNT IS A COMMITTED LITERAL
# ----------------------------------------
# ALLOW_ROWS_EXPECTED is pinned by hand and MUST NOT be derived from the file it
# checks. A BLIND READER MAKES BOTH SIDES ZERO AND THE CHECK AGREES WITH ITSELF:
# if the scan breaks, the scanned set is empty, the allowlist is "fully
# accounted for", and this prints PASS over nothing. That is the same failure as
# a gate passing over a corpus of zero, and it is the single most common defect
# found in this repo's guards. The literal is what a broken scan cannot satisfy.
# Same shape as CAPS_ROWS_EXPECTED in scripts/check-doc-budgets.sh (PR #12774).
#
# The passing output STATES ITS SAMPLE SIZE for the same reason. A green that
# cannot tell you how many things it examined is not evidence.
#
# EXIT CODES
#   0  every run-level reader is adjudicated and its count matches
#   1  an unadjudicated reader, a changed count, a stale row, or a bad verdict
#   2  REFUSED TO MEASURE — the scan roots hold nothing to read
#
# Usage: bash scripts/run-level-reader-census.sh            # the census
#        bash scripts/run-level-reader-census.sh --selftest # prove it can lose

set -euo pipefail

# Absolute, captured BEFORE any cd, because --selftest re-invokes this very file.
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
REPO_ROOT="$(dirname "$(dirname "$SELF")")"

# --selftest points this at a throwaway tree so its assertions drive the REAL
# census. Nothing else ever sets it.
ROOT="${RUN_LEVEL_CENSUS_ROOT:-$REPO_ROOT}"
cd "$ROOT"

ALLOW_REL=".github/run-level-readers.allow"

# PIN. Hand-maintained. See "WHY THE ROW COUNT IS A COMMITTED LITERAL" above.
ALLOW_ROWS_EXPECTED=17

SCAN_DIRS="scripts tooling .github/workflows"

# A run-level SOURCE: the feed that carries workflow-run objects.
SRC_RE='gh run list|gh run view|workflow_runs\[|actions/runs'
# A verdict READ: what turns that feed into a pass/fail answer.
READ_RE='conclusion|--status[= ]success'

VERDICTS="RUN-LEVEL JOB-LEVEL KNOWS-THE-CLASS HARNESS PROSE CENSUS"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
refuse() { echo "run-level-reader-census: REFUSED TO MEASURE — $1" >&2; exit 2; }

# Code lines only: a `#`-leading line is a comment, and comment churn must not
# move a count. (This is also why the prose above can describe `gh run list`
# freely without the census counting its own documentation.)
code_lines() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }

# The ONE scan. Emits "<path>\t<src-count>" for every file that both reaches a
# run-level feed AND reads a conclusion off it. Both the census and --selftest
# go through here, so a passing selftest is a statement about shipping code.
scan_readers() {
  local dirs="" d f code src rd
  for d in $SCAN_DIRS; do [ -d "$d" ] && dirs="$dirs $d"; done
  [ -z "$dirs" ] && return 0
  # shellcheck disable=SC2086  # $dirs is a controlled, space-joined list
  for f in $(grep -rl --include='*.sh' --include='*.yml' --include='*.mjs' \
               -e 'gh run list' -e 'gh run view' -e 'workflow_runs\[' -e 'actions/runs' \
               $dirs 2>/dev/null | sort); do
    code="$(code_lines "$f")"
    src=$(printf '%s\n' "$code" | grep -cE "$SRC_RE" || true)
    rd=$(printf '%s\n' "$code" | grep -cE "$READ_RE" || true)
    if [ "$src" -gt 0 ] && [ "$rd" -gt 0 ]; then printf '%s\t%s\n' "$f" "$src"; fi
  done
}

# Every file the scan COULD have looked at. Its own sample size — the number
# that separates "no run-level readers" from "I read nothing".
scan_corpus_size() {
  local dirs="" d
  for d in $SCAN_DIRS; do [ -d "$d" ] && dirs="$dirs $d"; done
  [ -z "$dirs" ] && { echo 0; return 0; }
  # shellcheck disable=SC2086
  find $dirs \( -name '*.sh' -o -name '*.yml' -o -name '*.mjs' \) -type f 2>/dev/null | grep -c . || true
}

census() {
  echo "== run-level reader census: who answers pass/fail from a RUN conclusion? =="

  local corpus
  corpus="$(scan_corpus_size)"
  if [ "$corpus" -eq 0 ]; then
    refuse "no .sh/.yml/.mjs files under $SCAN_DIRS at $ROOT.
  An empty reading is not a clean reading — 'no run-level readers found' is true of an
  empty directory too. Run this from a real checkout."
  fi

  local scanned
  scanned="$(scan_readers)"

  if [ ! -f "$ALLOW_REL" ]; then
    fail "$ALLOW_REL is missing. The adjudication IS the deliverable; without it this
      census has nothing to compare against and would pass by having no opinion."
    echo ""
    echo "run-level-reader-census: FAILED"
    return 1
  fi

  # allow rows: <path> <count> <verdict> <reason...>
  local allow rows
  allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW_REL" || true)"
  rows=$(printf '%s\n' "$allow" | grep -c . || true)

  if [ "$rows" -ne "$ALLOW_ROWS_EXPECTED" ]; then
    fail "$ALLOW_REL holds $rows row(s), expected $ALLOW_ROWS_EXPECTED.
      Either the allowlist changed and ALLOW_ROWS_EXPECTED must be bumped to match, or
      the reader went blind — a broken scan makes the scanned set empty, every row looks
      accounted for, and this would print PASS over nothing."
  fi

  # (a) every scanned reader is adjudicated, at the count it actually carries
  local path count arow acount averdict
  while IFS="$(printf '\t')" read -r path count; do
    [ -z "$path" ] && continue
    # The herestring belongs INSIDE the substitution. Outside the `)"` it
    # redirects the ASSIGNMENT, which is a no-op, and awk silently reads the
    # enclosing while-loop's stdin instead — the same shape as the bug this
    # commit fixes: no error, wrong answer.
    arow="$(awk -v p="$path" '$1 == p { print; exit }' <<<"$allow")"
    if [ -z "$arow" ]; then
      fail "UNADJUDICATED run-level reader: $path ($count run-level reference(s)).
      It reaches a workflow-run feed and reads a conclusion off it, and nobody has said
      whether that is a job-level descent or a true green about the wrong object. Add a
      row to $ALLOW_REL: '<path> <count> <VERDICT> <reason>'."
      continue
    fi
    acount="$(printf '%s' "$arow" | awk '{print $2}')"
    averdict="$(printf '%s' "$arow" | awk '{print $3}')"
    if [ "$acount" != "$count" ]; then
      fail "$path now carries $count run-level reference(s), adjudicated at $acount.
      Someone added or removed one. Re-read the file, confirm the verdict still holds,
      and update the count in $ALLOW_REL."
    fi
    case " $VERDICTS " in
      *" $averdict "*) ;;
      *) fail "$path carries verdict '$averdict', which is not one of: $VERDICTS" ;;
    esac
  done <<EOF
$scanned
EOF

  # (b) anti-rot: an adjudicated path that is no longer a run-level reader
  while read -r path _rest; do
    [ -z "$path" ] && continue
    if ! printf '%s\n' "$scanned" | awk -F'\t' -v p="$path" '$1 == p { found = 1 } END { exit !found }'; then
      fail "STALE row in $ALLOW_REL: $path is adjudicated but no longer reads a run-level
      conclusion. An exemption that describes nothing is a hole nobody is watching."
    fi
  done <<EOF
$allow
EOF

  local n_scanned n_hazard
  n_scanned=$(printf '%s\n' "$scanned" | grep -c . || true)
  n_hazard=$(printf '%s\n' "$allow" | awk '$3 == "RUN-LEVEL"' | grep -c . || true)

  if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "run-level-reader-census: FAILED"
    return 1
  fi

  # The sample size, out loud. A green that cannot say how many things it looked
  # at is not evidence.
  echo "ok:   read $corpus scannable file(s); $n_scanned reach a run-level feed and read a conclusion"
  echo "ok:   all $n_scanned adjudicated in $ALLOW_REL at the counts they carry"
  echo "ok:   $n_hazard classified RUN-LEVEL — they answer from the run conclusion (enumerated, not fixed: this is a census)"
  echo "run-level-reader-census: PASS"
  return 0
}

# ── selftest: prove the census BITES, and stays silent when it should ────────
#
# Every arm builds a throwaway tree and re-invokes THIS script against it via
# RUN_LEVEL_CENSUS_ROOT, so the assertions drive the shipping code path — not a
# second implementation of the scan that could agree while both are wrong.
#
# EVERY ARM VERIFIES ITS OWN PLANT LANDED before the probe runs. An arm whose
# mutation silently failed to apply passes while testing nothing: measured in
# this repo when a fresh() helper declared its own `for e in $SCANNED_EXTS` and
# clobbered the enclosing loop variable, so six per-extension arms all tested one
# extension while printing six correct-looking labels.
selftest() {
  local tmp bad=0 rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }

  # A minimal tree: one RUN-LEVEL reader, one JOB-LEVEL reader, an allowlist
  # pinning both, and ALLOW_ROWS_EXPECTED patched to this fixture's row count.
  fresh() {
    local probe
    rm -rf "$tmp/t"
    mkdir -p "$tmp/t/scripts" "$tmp/t/.github/workflows" "$tmp/t/tooling"
    printf 'gh run list --workflow x.yml --json conclusion -q ".[0].conclusion"\n' \
      > "$tmp/t/scripts/reader-run.sh"
    printf 'gh api "repos/o/r/actions/runs/$id/jobs" --jq ".jobs[].conclusion"\n' \
      > "$tmp/t/scripts/reader-job.sh"
    mkdir -p "$tmp/t/.github"
    { echo "# <path> <count> <VERDICT> <reason>"
      echo "scripts/reader-run.sh 1 RUN-LEVEL answers from the run rollup"
      echo "scripts/reader-job.sh 1 JOB-LEVEL descends to jobs"
    } > "$tmp/t/.github/run-level-readers.allow"
    # the fixture's own pin: 2 rows
    probe="$tmp/t/census.sh"
    # Match ANY digits, never the committed value: a fixture pinned to today's
    # literal stops patching the day the literal changes, and every arm then
    # fails for that reason instead of its own. That happened while writing this.
    sed 's/^ALLOW_ROWS_EXPECTED=[0-9][0-9]*$/ALLOW_ROWS_EXPECTED=2/' "$SELF" > "$probe"
    grep -q '^ALLOW_ROWS_EXPECTED=2$' "$probe" \
      || { echo "  FAIL  PLANT CHECK: the fixture pin did not patch ALLOW_ROWS_EXPECTED"; bad=$((bad + 1)); }
  }
  # The probe must live where REPO_ROOT resolution still finds the fixture, so it
  # is invoked with RUN_LEVEL_CENSUS_ROOT set explicitly.
  probe() { RUN_LEVEL_CENSUS_ROOT="$tmp/t" bash "$tmp/t/census.sh" > "$tmp/out" 2>&1; echo $?; }

  echo "run-level-reader-census --selftest (throwaway trees)"

  # 1. SILENT ARM — a fully adjudicated tree must pass, and say its sample size.
  fresh; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "2 reach a run-level feed" "$tmp/out"; } \
    && say "fully adjudicated tree -> PASS, and states its sample size" 0 \
    || { say "fully adjudicated tree -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2. BITE ARM — a NEW run-level reader nobody has adjudicated.
  fresh
  printf 'gh run view 1 --json conclusion\n' > "$tmp/t/scripts/reader-new.sh"
  grep -q 'gh run view' "$tmp/t/scripts/reader-new.sh" \
    || { say "PLANT CHECK: the new-reader plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "UNADJUDICATED run-level reader: scripts/reader-new.sh" "$tmp/out"; } \
    && say "an unadjudicated run-level reader -> FAIL, path named" 0 \
    || { say "an unadjudicated run-level reader -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 3. BITE ARM — a reference ADDED to an already-adjudicated file. This is the
  #    arm a line-anchored pin could not have: the file is known, the count moved.
  fresh
  printf 'gh run view 2 --json conclusion\n' >> "$tmp/t/scripts/reader-run.sh"
  [ "$(grep -cE 'gh run list|gh run view' "$tmp/t/scripts/reader-run.sh")" -eq 2 ] \
    || { say "PLANT CHECK: the extra-reference plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "now carries 2 run-level reference(s), adjudicated at 1" "$tmp/out"; } \
    && say "a reference added to an adjudicated file -> FAIL, both counts named" 0 \
    || { say "a reference added to an adjudicated file -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 4. BITE ARM — anti-rot: a row that no longer describes a run-level reader.
  fresh
  rm -f "$tmp/t/scripts/reader-job.sh"
  [ ! -e "$tmp/t/scripts/reader-job.sh" ] \
    || { say "PLANT CHECK: the stale-row plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "STALE row" "$tmp/out"; } \
    && say "an adjudicated path that is no longer a reader -> FAIL (exemptions cannot rot)" 0 \
    || { say "an adjudicated path that is no longer a reader -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5. BITE ARM — an unknown verdict is not an adjudication.
  fresh
  sed 's/ JOB-LEVEL / PROBABLY-FINE /' "$tmp/t/.github/run-level-readers.allow" > "$tmp/a" \
    && mv "$tmp/a" "$tmp/t/.github/run-level-readers.allow"
  grep -q 'PROBABLY-FINE' "$tmp/t/.github/run-level-readers.allow" \
    || { say "PLANT CHECK: the bad-verdict plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "not one of" "$tmp/out"; } \
    && say "a verdict outside the vocabulary -> FAIL" 0 \
    || { say "a verdict outside the vocabulary -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 6. THE POINT OF THE PIN — a BLIND scan must not read as a clean tree.
  #    With the scan neutered the scanned set is empty, every row looks accounted
  #    for, and only the committed literal can tell the difference.
  fresh
  sed "s/^SRC_RE='.*'$/SRC_RE='ZZZ-matches-nothing'/" "$tmp/t/census.sh" > "$tmp/b" \
    && mv "$tmp/b" "$tmp/t/census.sh"
  grep -q "ZZZ-matches-nothing" "$tmp/t/census.sh" \
    || { say "PLANT CHECK: the blinding plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "STALE row" "$tmp/out"; } \
    && say "a BLIND scan -> FAIL, not a clean tree" 0 \
    || { say "a BLIND scan -> FAIL, not a clean tree (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7. THE PIN ITSELF. Nothing above proves ALLOW_ROWS_EXPECTED is even consulted,
  #    and it is the anti-vacuity core of this design: without it a blind scan
  #    leaves the allowlist looking fully accounted for. Mutation-checked — with
  #    the ratchet removed, every OTHER arm still passed 7/7.
  fresh
  sed 's/^ALLOW_ROWS_EXPECTED=2$/ALLOW_ROWS_EXPECTED=99/' "$tmp/t/census.sh" > "$tmp/c" \
    && mv "$tmp/c" "$tmp/t/census.sh"
  grep -q '^ALLOW_ROWS_EXPECTED=99$' "$tmp/t/census.sh" \
    || { say "PLANT CHECK: the pin-drift plant did not land" 1; }
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "holds 2 row(s), expected 99" "$tmp/out"; } \
    && say "the pinned row count disagreeing with the allowlist -> FAIL, both numbers named" 0 \
    || { say "the pinned row count disagreeing with the allowlist -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 8. REFUSED TO MEASURE — nothing to read at all.
  rm -rf "$tmp/t"; mkdir -p "$tmp/t"
  sed 's/^ALLOW_ROWS_EXPECTED=[0-9][0-9]*$/ALLOW_ROWS_EXPECTED=2/' "$SELF" > "$tmp/t/census.sh"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "no scannable files at all -> REFUSED TO MEASURE (2), never a silent PASS" 0 \
    || { say "no scannable files at all -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  echo ""
  if [ "$bad" -eq 0 ]; then echo "run-level-reader-census --selftest: PASS (8/8)"; return 0; fi
  echo "run-level-reader-census --selftest: FAILED ($bad case(s))"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         census ;;
  *)          echo "usage: bash scripts/run-level-reader-census.sh [--selftest]" >&2; exit 64 ;;
esac
