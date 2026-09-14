#!/usr/bin/env bash
# scheduled-arm-health.test.sh — proves scripts/scheduled-arm-health.sh can LOSE.
#
# A never-succeeded reader that cannot be shown going red is itself a report-mode
# job that gates nothing, which is the exact disease its subject exists to
# detect. So every case here is a PAIR: a tree/fixture the check must red on and
# a neighbouring one it must stay green on. A case that only ever asserts the
# green half is not in this file.
#
# HERMETIC: every case builds a scratch tree with its own .github/workflows and
# its own --runs-dir fixture payloads. Nothing here touches the network, `gh`, or
# the real repository — the LIVE both-directions proof against named real
# workflows is recorded in the commit message and in task-2c762aa7dfca5bd8, and
# is deliberately not re-run here, because a harness whose green depends on
# GitHub's run history rots the moment that history moves.
#
# --now is PINNED in every case. A staleness check whose expected verdict is read
# off the wall clock passes today and fails in three weeks for no reason anybody
# changed.
#
# EXIT: 0 every case behaved · 1 at least one did not.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/scheduled-arm-health.sh"
[ -f "$SUBJECT" ] || { echo "REFUSING — subject not found at $SUBJECT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "REFUSING — jq is not on PATH" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sah-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; CASES=0
NOW="2026-09-15T00:00:00Z"

# runs_json <total_count> <success-count> <failure-count> <newest-success-iso|"">
# Builds a payload of the shape `actions/workflows/<file>/runs` returns.
runs_json() {
  local tc="$1" ok="$2" bad="$3" last="$4" i=0 rows=""
  for ((i = 0; i < ok; i++)); do
    rows="$rows{\"conclusion\":\"success\",\"run_started_at\":\"${last:-2026-09-01T00:00:00Z}\"},"
  done
  for ((i = 0; i < bad; i++)); do
    rows="$rows{\"conclusion\":\"failure\",\"run_started_at\":\"2026-09-01T00:00:00Z\"},"
  done
  rows="${rows%,}"
  printf '{"total_count":%s,"workflow_runs":[%s]}' "$tc" "$rows"
}

# run_case <label> <fixture> <expected-rc> <expected-substring|""> <extra-args...>
# <fixture> names the scratch tree laid down by lay_tree, and is DELIBERATELY a
# separate argument from <label>: two cases read the SAME fixture at different
# thresholds (5 and 6), which is how "--min-runs is what separates them" is
# demonstrated rather than asserted.
run_case() {
  local label="$1" fixture="$2" want_rc="$3" want_text="$4"; shift 4
  local out rc
  CASES=$((CASES + 1))
  [ -d "$TMP/$fixture/tree" ] || { FAIL=$((FAIL + 1)); printf '  FAIL %-42s no fixture tree at %s\n' "$label" "$TMP/$fixture/tree"; return; }
  out="$(SAH_ROOT="$TMP/$fixture/tree" bash "$SUBJECT" --runs-dir "$TMP/$fixture/runs" --now "$NOW" "$@" 2>&1)"
  rc=$?
  local ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  if [ -n "$want_text" ]; then
    case "$out" in *"$want_text"*) : ;; *) ok=0 ;; esac
  fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1)); printf '  ok   %-42s rc=%s\n' "$label" "$rc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-42s rc=%s (wanted %s%s)\n' "$label" "$rc" "$want_rc" "${want_text:+, containing \"$want_text\"}"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# lay_tree <label> <workflow-basename> <cron|nocron>
lay_tree() {
  local label="$1" base="$2" cron="$3"
  mkdir -p "$TMP/$label/tree/.github/workflows" "$TMP/$label/runs"
  {
    echo "name: ${base%.yml}"
    echo "on:"
    if [ "$cron" = cron ]; then
      echo "  schedule:"
      echo "    - cron: \"40 6 * * *\""
    else
      echo "  push:"
      echo "    branches: [main]"
    fi
    echo "jobs: {}"
  } > "$TMP/$label/tree/.github/workflows/$base"
}

echo "scheduled-arm-health.test.sh — every case is a pair; --now pinned to $NOW"
echo

# ── 1. THE SUBJECT'S OWN SHAPE ───────────────────────────────────────────────
# Zero scheduled successes over a population above the floor, while the
# all-events read is mostly green. This is studio-journey-smoke exactly: 47
# scheduled failures, 0 successes, and a healthy-looking all-events number that
# belongs to a different job on a different event.
lay_tree never-succeeded subject.yml cron
runs_json 47 0 47 ""                      > "$TMP/never-succeeded/runs/subject.yml.schedule.json"
runs_json 100 51 7 "2026-09-14T00:00:00Z" > "$TMP/never-succeeded/runs/subject.yml.all.json"
run_case never-succeeded never-succeeded 1 "NEVER SUCCEEDED"

# THE LAUNDERING LINE ITSELF, not just the red. This is the sentence that says
# WHY a naive reader called it healthy; without it the red is correct and
# unexplained, and the next person re-derives the split by event from scratch.
run_case names-laundering never-succeeded 1 "LAUNDERED"

# ── 2. THE GREEN HALF OF THE SAME PAIR ───────────────────────────────────────
# Same tree, same cron, same all-events payload — the ONLY thing that moves is
# the scheduled arm's own success count. If this case ever goes red too, the
# check is stuck on one answer and case 1 proved nothing.
lay_tree healthy subject.yml cron
runs_json 50 50 0 "2026-09-14T00:00:00Z"  > "$TMP/healthy/runs/subject.yml.schedule.json"
runs_json 100 94 1 "2026-09-14T00:00:00Z" > "$TMP/healthy/runs/subject.yml.all.json"
run_case healthy healthy 0 "ok              subject.yml"

# ── 3. EVENT SCOPING IS LOAD-BEARING ─────────────────────────────────────────
# The fixture a reader that ignored `event` would see: an all-events payload that
# is overwhelmingly green sitting on top of a scheduled arm that is entirely red.
# The verdict must follow the SCHEDULE file, never the ALL file. Distinguishing
# this case from case 2 is the only thing that proves the split is real: the two
# differ ONLY in the .schedule.json payload.
lay_tree event-scoped subject.yml cron
runs_json 40 0 40 ""                      > "$TMP/event-scoped/runs/subject.yml.schedule.json"
runs_json 100 99 1 "2026-09-14T00:00:00Z" > "$TMP/event-scoped/runs/subject.yml.all.json"
run_case event-scoped event-scoped 1 "NOT ONE of the 40 completed scheduled runs"

# ── 4. STALE, AND ITS FRESH TWIN ─────────────────────────────────────────────
# It HAS succeeded — so the never-succeeded rule cannot fire — and the only
# question is age. Both cases carry successes; only the timestamp moves.
lay_tree stale subject.yml cron
runs_json 30 5 25 "2026-07-01T00:00:00Z"  > "$TMP/stale/runs/subject.yml.schedule.json"
runs_json 60 30 30 "2026-09-14T00:00:00Z" > "$TMP/stale/runs/subject.yml.all.json"
run_case stale stale 1 "STALE"

lay_tree fresh subject.yml cron
runs_json 30 5 25 "2026-09-10T00:00:00Z"  > "$TMP/fresh/runs/subject.yml.schedule.json"
runs_json 60 30 30 "2026-09-14T00:00:00Z" > "$TMP/fresh/runs/subject.yml.all.json"
run_case fresh fresh 0 "ok "

# ── 5. A SMALL POPULATION IS NOT A VERDICT ───────────────────────────────────
# Four failures and no successes is the same SHAPE as case 1 and must NOT red:
# a cron that has fired four times has not yet earned "it has never worked".
# --min-runs is what separates them, so the pair here is the same fixture read
# at two thresholds.
lay_tree young subject.yml cron
runs_json 4 0 4 ""                        > "$TMP/young/runs/subject.yml.schedule.json"
runs_json 20 18 2 "2026-09-14T00:00:00Z"  > "$TMP/young/runs/subject.yml.all.json"
run_case young-under-floor young 0 "no verdict yet"
run_case young-over-floor  young 1 "NEVER SUCCEEDED" --min-runs 3

# ── 6. NEVER RAN ─────────────────────────────────────────────────────────────
# A declared cron the API knows nothing about. Reported, never omitted — and NOT
# red by default, because a cron added yesterday is indistinguishable from one
# GitHub disabled. --strict-never-ran is the other half of the pair, and its
# existence is why the default silence is a policy rather than a blind spot.
lay_tree never-ran subject.yml cron
runs_json 0 0 0 ""                        > "$TMP/never-ran/runs/subject.yml.schedule.json"
runs_json 100 94 1 "2026-09-14T00:00:00Z" > "$TMP/never-ran/runs/subject.yml.all.json"
run_case never-ran-reported never-ran 0 "NEVER RAN"
run_case never-ran-strict never-ran 1 "NEVER RAN" --strict-never-ran

# ── 7. THE ROSTER IS THE CRON, NOT THE TREE ──────────────────────────────────
# A workflow with no cron is not this instrument's business and must not be
# fetched or judged. With NO cron'd file at all the script REFUSES (exit 2)
# rather than printing a clean empty report — "0 red over 0 rows" is the verdict
# shape this whole file exists to distrust.
lay_tree no-cron subject.yml nocron
runs_json 47 0 47 ""                      > "$TMP/no-cron/runs/subject.yml.schedule.json"
runs_json 100 51 7 "2026-09-14T00:00:00Z" > "$TMP/no-cron/runs/subject.yml.all.json"
run_case roster-is-cron-only no-cron 2 "REFUSING"

# ── 8. AN UNREADABLE ROW IS NEVER GREEN ──────────────────────────────────────
# The fixture for a cron'd workflow is simply absent — the offline stand-in for
# the `gh api` timeout that really happened during bring-up (main-gate-watch.yml,
# 2026-09-15). The run must exit 2 CANNOT MEASURE, not skip the row and print a
# clean summary it did not earn. Paired with case 2, which differs only in that
# the fixture exists.
lay_tree unreadable subject.yml cron
run_case unreadable-is-not-green unreadable 2 "CANNOT MEASURE"

# ── 9. THE SUBJECT REFUSES AN ARGUMENT IT DOES NOT KNOW ──────────────────────
# A typo'd flag that silently parsed as a no-op would make every case above run
# with default settings, and cases 5 and 6 would then "pass" for the wrong
# reason. So an unknown argument is an exit 2 refusal.
lay_tree bad-arg subject.yml cron
runs_json 50 50 0 "2026-09-14T00:00:00Z"  > "$TMP/bad-arg/runs/subject.yml.schedule.json"
runs_json 100 94 1 "2026-09-14T00:00:00Z" > "$TMP/bad-arg/runs/subject.yml.all.json"
run_case unknown-argument-refused bad-arg 2 "REFUSING" --not-a-real-flag

echo
echo "scheduled-arm-health.test.sh — $CASES cases · $PASS passed · $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
