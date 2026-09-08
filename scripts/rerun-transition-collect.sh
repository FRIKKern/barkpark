#!/usr/bin/env bash
# rerun-transition-collect.sh — the passive collector for in-place re-runs.
#
# WHY THIS EXISTS. "How often does the main-red breaker accuse a red that was
# never the author's because the job is non-deterministic?" cannot be answered
# from the run history, and the reason is structural rather than bad luck:
#
#   AN AGENT FLEET DOES NOT RE-RUN. It diagnoses, or it pushes again — which
#   makes a NEW SHA and a NEW RUN, not a second attempt.
#
# So the only free evidence of a flake is `run_attempt > 1` on the SAME run id
# (a re-run is in place, so "unchanged tree" is true BY CONSTRUCTION), and those
# are vanishingly rare: MEASURED 2026-09-08, over 1000 pull_request runs spanning
# 00:22:10Z..05:52:13Z, exactly TWO existed — 0.200% of listed PR runs, 10% of
# the 20 failed ones. Both cleared. n=2 is a FLOOR, not a rate, and it must never
# be quoted as "100% of re-runs are flakes": re-runs are triggered precisely when
# somebody already suspects a flake, which is a selection effect.
#
# AND THE FREE INSTRUMENT IS EXHAUSTED, NOT UNDER-USED. GitHub's Actions runs
# listing caps at 1000 items no matter how many pages are requested — 60 pages
# were asked for and 11 returned data. The window cannot be widened by paging,
# only by filtering, and event=pull_request was already the filter. That is the
# difference between "try harder" and "try differently": the harvest is capped,
# so the DENOMINATOR HAS TO ACCUMULATE INSTEAD OF BEING HARVESTED.
#
# WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT. It is a collector and a file.
# It is NOT a verdict: it never exits non-zero on what it finds, never accuses
# anyone, and no gate consumes it. It is NOT a dashboard. Building a
# FLAKE-SUSPECTED verdict on today's evidence is exactly the mistake this file's
# subject already made twice (M6's four accused PRs; #16908's over-reach), so
# this collects until a rate exists and stops there.
#
# WHY IT DOES NOT COMMIT FROM CI. No workflow in this repository pushes to main
# — the established pattern is upload-artifact — and `git pull` IS the deploy on
# the prod box, so a bot commit to main is a production event. The accumulation
# therefore lives in the COMMITTED FILE and the file is updated by whoever runs
# this, through an ordinary PR. Each run appends what is visible NOW; the file
# remembers what has since scrolled out of the capped window.
#
# USAGE
#   scripts/rerun-transition-collect.sh                  # collect into the ledger
#   scripts/rerun-transition-collect.sh --dry-run        # print rows, write nothing
#   scripts/rerun-transition-collect.sh --fixture <file> # runs listing from a file
#   scripts/rerun-transition-collect.sh --selftest       # hermetic, no network
#
# EXIT CODES
#   0 = collected (including "nothing new to add" — an empty harvest is normal)
#   2 = the runs listing could not be read, or was not JSON. NOT a finding: a
#       collector that cannot look must say so rather than record a quiet zero.
#   3 = configuration fault (bad argument, unwritable ledger).
set -uo pipefail

LEDGER="${RERUN_LEDGER:-scripts/rerun-transitions.jsonl}"
LIMIT="${RERUN_LIMIT:-100}"
PAGES="${RERUN_PAGES:-10}"
FIXTURE=""
DRY_RUN=0
SELFTEST=0

say() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ledger)   LEDGER="${2:-}"; shift 2 ;;
    --limit)    LIMIT="${2:-}"; shift 2 ;;
    --pages)    PAGES="${2:-}"; shift 2 ;;
    --fixture)  FIXTURE="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help)  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) red "unknown argument: $1"; exit 3 ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*) red "--limit must be a positive integer, got: '$LIMIT'"; exit 3 ;; esac
[ "$LIMIT" -ge 1 ] || { red "--limit must be at least 1: a listing of zero runs is not a read."; exit 3; }
case "$PAGES" in ''|*[!0-9]*) red "--pages must be a positive integer, got: '$PAGES'"; exit 3 ;; esac
[ "$PAGES" -ge 1 ] || { red "--pages must be at least 1: zero pages is not a read."; exit 3; }

# ── the harvest ─────────────────────────────────────────────────────────────
# One listing call. `run_attempt` on the listing is the LATEST attempt number,
# so `> 1` is exactly "this run was re-run in place at least once".
fetch_runs() {
  if [ -n "$FIXTURE" ]; then
    [ -f "$FIXTURE" ] || { red "no such fixture: $FIXTURE"; return 2; }
    cat -- "$FIXTURE"
    return 0
  fi
  # PAGES matters: per_page caps at 100 and 100 runs is roughly TWELVE MINUTES
  # of this fleet, so a single page would miss nearly everything between
  # invocations. The listing itself caps at 1000 items no matter what, which is
  # why this collects FORWARD instead of harvesting backward.
  local p out acc='{"workflow_runs":[]}'
  for p in $(seq 1 "$PAGES"); do
    out="$(gh api "repos/{owner}/{repo}/actions/runs?event=pull_request&per_page=${LIMIT}&page=${p}" 2>/dev/null)" || return 2
    [ -n "$out" ] || return 2
    printf '%s' "$out" | jq -e '(.workflow_runs // []) | length > 0' >/dev/null 2>&1 || break
    acc="$(printf '%s\n%s' "$acc" "$out" | jq -c -s '{workflow_runs: (.[0].workflow_runs + .[1].workflow_runs)}' 2>/dev/null)" || return 2
  done
  printf '%s' "$acc"
}

# Whether the breaker accused on attempt 1. UNKNOWN is a real value here and is
# recorded as such: a log we could not read is not a log with no accusation in
# it, and collapsing those two would poison the very number this file exists to
# collect.
accused_on_attempt1() { # $1 = run id -> "yes" | "no" | "unknown"
  local rid="$1" log
  [ -n "$FIXTURE" ] && { printf 'unknown'; return 0; }
  log="$(gh run view "$rid" --attempt 1 --log 2>/dev/null)" || { printf 'unknown'; return 0; }
  [ -n "$log" ] || { printf 'unknown'; return 0; }
  case "$log" in
    *"the red is this PR's own"*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

collect() {
  local raw rows existing new_n=0 total=0
  raw="$(fetch_runs)" || return 2
  [ -n "$raw" ] || { red "the runs listing came back empty — this is a failed read, not an empty harvest."; return 2; }

  rows="$(printf '%s' "$raw" | jq -c '
      [ (.workflow_runs // [])[]
        | select((.run_attempt // 1) > 1)
        | {run_id: .id, workflow: .name, head_sha: .head_sha,
           attempts: .run_attempt, latest_conclusion: .conclusion,
           created_at: .created_at,
           # carried for --fixture only; a live listing has no such field, and
           # the emitted row drops it below so the ledger shape is identical
           # either way.
           fixture_attempt1: .fixture_attempt1} ] | .[]' 2>/dev/null)" || {
    red "the runs listing did not parse as JSON — the read produced something, but not a listing."
    return 2
  }

  existing=""
  [ -f "$LEDGER" ] && existing="$(jq -r '.run_id // empty' < "$LEDGER" 2>/dev/null | tr '\n' ' ')"

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    total=$((total + 1))
    local rid; rid="$(printf '%s' "$row" | jq -r '.run_id')"
    case " $existing " in *" $rid "*) continue ;; esac

    # attempt 1's own conclusion — the half that makes "cleared on an unchanged
    # tree" a fact rather than an inference.
    local a1="unknown" a1sha=""
    if [ -z "$FIXTURE" ]; then
      local a1json
      a1json="$(gh api "repos/{owner}/{repo}/actions/runs/${rid}/attempts/1" 2>/dev/null)" || a1json=""
      if [ -n "$a1json" ]; then
        a1="$(printf '%s' "$a1json" | jq -r '.conclusion // "unknown"' 2>/dev/null || echo unknown)"
        a1sha="$(printf '%s' "$a1json" | jq -r '.head_sha // ""' 2>/dev/null || echo "")"
      fi
    else
      a1="$(printf '%s' "$row" | jq -r '.fixture_attempt1 // "unknown"')"
      a1sha="$(printf '%s' "$row" | jq -r '.head_sha')"
    fi

    local acc; acc="$(accused_on_attempt1 "$rid")"
    local out
    out="$(printf '%s' "$row" | jq -c \
        --arg a1 "$a1" --arg a1sha "$a1sha" --arg acc "$acc" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.fixture_attempt1)
        + {attempt1_conclusion: $a1,
           attempt1_head_sha: $a1sha,
           same_sha: ($a1sha == "" or $a1sha == .head_sha),
           breaker_accused_on_attempt1: $acc,
           recorded_at: $now}')"
    if [ "$DRY_RUN" = "1" ]; then
      say "$out"
    else
      printf '%s\n' "$out" >> "$LEDGER" || { red "cannot write the ledger at $LEDGER"; return 3; }
    fi
    new_n=$((new_n + 1))
  done <<< "$rows"

  # `grep -c ''` EXITS 1 on an empty file, so `grep -c … || echo 0` prints BOTH
  # its own 0 and the fallback 0, and the count becomes "0\n0". wc has no such
  # arm. Measured, not reasoned about: the first seed run printed
  # "ledger now holds 0\n0 row(s)".
  local held=0
  [ -f "$LEDGER" ] && held="$(wc -l < "$LEDGER" | tr -d '[:space:]')"
  say "rerun-transition-collect: $total re-run(s) visible across ${PAGES} page(s) of ${LIMIT}; $new_n new; ledger now holds $held row(s)."
  # An empty harvest is the NORMAL case and is not a finding: measured
  # 2026-09-08, in-place re-runs are 0.2% of PR runs.
  return 0
}

# ── selftest ────────────────────────────────────────────────────────────────
# The discipline this harness family uses: a collector must be shown RECORDING a
# known transition, not merely failing to crash. So there is a positive arm, a
# NEGATIVE arm (a single-attempt run must NOT be recorded), a dedup arm, and a
# MUTATION that removes the attempt filter and proves the negative arm can fail.
if [ "$SELFTEST" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS + 1)); say "  ok   $1"; }
  bad() { FAIL=$((FAIL + 1)); say "  FAIL $1"; }
  T="$(mktemp -d -t rerun-collect-test.XXXXXX)"; trap 'rm -rf "$T"' EXIT

  cat > "$T/runs.json" <<'J'
{"workflow_runs":[
 {"id":34184567197,"name":"compose-smoke","head_sha":"f76da66b1","run_attempt":2,
  "conclusion":"success","created_at":"2026-09-08T03:44:47Z","fixture_attempt1":"failure"},
 {"id":34189243358,"name":"pr-task-gate","head_sha":"9d3324d67","run_attempt":2,
  "conclusion":"success","created_at":"2026-09-08T05:04:25Z","fixture_attempt1":"failure"},
 {"id":34191279191,"name":"doc-gates","head_sha":"568941ad1","run_attempt":1,
  "conclusion":"failure","created_at":"2026-09-08T05:34:00Z","fixture_attempt1":"failure"}
]}
J

  say "rerun-transition-collect --selftest"
  say ""

  # (a) POSITIVE: a known transition is RECORDED, and it is the real one.
  : > "$T/ledger.jsonl"
  out="$("$0" --fixture "$T/runs.json" --ledger "$T/ledger.jsonl" 2>&1)"; rc=$?
  n="$(grep -c '' < "$T/ledger.jsonl")"
  [ "$rc" = "0" ] && ok "(a) a fixture with two re-runs collects cleanly (exit 0)" \
                  || bad "(a) expected exit 0, got $rc — $out"
  [ "$n" = "2" ] && ok "(a) …and RECORDED exactly the 2 re-run rows" \
                 || bad "(a) expected 2 rows in the ledger, got $n"
  grep -q '34184567197' "$T/ledger.jsonl" \
    && ok "(a) …including compose-smoke 34184567197, the known 2026-09-08 transition" \
    || bad "(a) the known transition was NOT recorded — the collector collects nothing real"
  grep -q '"attempt1_conclusion":"failure"' "$T/ledger.jsonl" \
    && ok "(a) …carrying attempt 1's own conclusion, so failure->success is a fact not an inference" \
    || bad "(a) attempt1_conclusion was not recorded"

  # (b) NEGATIVE: a single-attempt run must NOT be recorded. Without this arm,
  #     a collector that records EVERYTHING would pass (a) and be useless.
  grep -q '34191279191' "$T/ledger.jsonl" \
    && bad "(b) a single-attempt run was recorded — the attempt filter is not filtering" \
    || ok "(b) a run that was never re-run is NOT recorded"

  # (c) DEDUP: re-running the collector adds nothing. The ledger accumulates
  #     across days precisely because a second look does not double-count.
  out="$("$0" --fixture "$T/runs.json" --ledger "$T/ledger.jsonl" 2>&1)"
  n2="$(grep -c '' < "$T/ledger.jsonl")"
  [ "$n2" = "2" ] && ok "(c) a second collection over the same window adds nothing (still 2 rows)" \
                  || bad "(c) dedup failed: $n2 rows after a second pass"

  # (d) MUTATION — the negative arm must be able to LOSE. Strip the attempt
  #     filter on a copy; the single-attempt run must then be recorded, which
  #     proves (b) is measuring the filter and not the fixture.
  sed 's/select((.run_attempt \/\/ 1) > 1)/select((.run_attempt \/\/ 1) > 0)/' "$0" > "$T/mut.sh"
  chmod +x "$T/mut.sh"
  if diff -q "$0" "$T/mut.sh" >/dev/null 2>&1; then
    bad "(d) MUTATION did not apply — the anchor moved, so (b) proves nothing"
  else
    : > "$T/mut-ledger.jsonl"
    "$T/mut.sh" --fixture "$T/runs.json" --ledger "$T/mut-ledger.jsonl" >/dev/null 2>&1
    grep -q '34191279191' "$T/mut-ledger.jsonl" \
      && ok "(d) with the attempt filter removed the single-attempt run IS recorded — (b) is not vacuous" \
      || bad "(d) MUTATION SURVIVED: the single-attempt run stayed out even without the filter"
  fi

  # (e) A FAILED READ IS NOT AN EMPTY HARVEST.
  out="$("$0" --fixture "$T/nonexistent.json" --ledger "$T/ledger.jsonl" 2>&1)"; rc=$?
  [ "$rc" = "2" ] && ok "(e) an unreadable listing exits 2, never 0 with a quiet zero" \
                  || bad "(e) expected exit 2 for an unreadable fixture, got $rc"

  say ""
  say "rerun-transition-collect.test: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

collect
exit $?
