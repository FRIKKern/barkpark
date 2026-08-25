#!/usr/bin/env bash
# absent-context-census.test.sh — the mutation proofs for the absence census.
#
# FULLY HERMETIC. Every probe drives scripts/absent-context-census.sh over
# CAPTURED-SHAPE fixture payloads with --fixtures and a pinned --now, so no
# probe touches the network and no age depends on the wall clock. `gh` is
# additionally removed from PATH for the fixture probes, which makes "made no
# API call" an assertion about behaviour rather than a claim about control flow.
#
# NOTHING HERE ASSERTS "THE SCRIPT RAN". Each classification is proven by
# MUTATING one field of a base fixture and watching the verdict move, and each
# assertion the harness itself makes is then disarmed and watched failing —
# including the queue-comparison assertion, which is the one most likely to be
# written so it can only pass.
#
# THE BASE FIXTURE IS DERIVED, NEVER TYPED. The four required context names and
# their producing workflow files are read out of the committed spec and the real
# .github/workflows tree at build time. A context that is renamed or a job that
# moves file therefore changes these fixtures too — the harness cannot drift
# into testing a required set this repository stopped having.
#
#   bash scripts/absent-context-census.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CENSUS="$REPO_ROOT/scripts/absent-context-census.sh"
WF="$REPO_ROOT/.github/workflows/absent-context-census.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"
WORKFLOWS="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -f "$CENSUS" ] || { echo "missing $CENSUS" >&2; exit 2; }
[ -f "$WF" ]     || { echo "missing $WF" >&2; exit 2; }

# A pinned present. Every created_at below is expressed relative to it, so the
# age column is a fact about the fixture rather than about when CI ran.
NOW="2026-08-07T00:00:00Z"
SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# `gh` is off PATH for every fixture probe. If a code path ever falls back to
# the live API, the probe fails loudly instead of quietly reporting live truth.
NOGH="$TMP/nogh"; mkdir -p "$NOGH"
run_census() { # <fixture dir> [extra args…]
  local dir="$1"; shift
  env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$CENSUS" --fixtures "$dir" --now "$NOW" --spec "$SPEC" --workflows "$WORKFLOWS" \
      --repo FRIKKern/barkpark "$@" 2>&1
}

# ═══ 0. the base fixture — a head on which the census must find nothing ══════
section "0. the base fixture: four required contexts, all rendered, nothing stale"

# Plain array + `while read`, never `mapfile`: this harness must run on stock
# macOS bash 3.2 as well as on CI's bash 5, and a builder who cannot run the
# gate locally does not run it.
CONTEXTS=()
while IFS= read -r line; do
  [ -n "$line" ] && CONTEXTS+=("$line")
done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF
[ "${#CONTEXTS[@]}" -ge 2 ] \
  || { echo "the committed spec lists ${#CONTEXTS[@]} required context(s); these probes need at least 2" >&2; exit 2; }

# Map each context to the workflow file whose job carries that name — the same
# question the script asks, answered independently here so a mapping bug shows
# up as a disagreement rather than as two copies of one mistake.
ctx_path() { # <context>
  local hits
  hits="$(grep -rlE "^[[:space:]]+name:[[:space:]]+$(sed 's/[][\.*^$/]/\\&/g' <<<"$1")[[:space:]]*$" "$WORKFLOWS" 2>/dev/null | sort)"
  [ "$(grep -c . <<<"$hits")" = "1" ] || return 1
  echo ".github/workflows/$(basename "$hits")"
}

for c in "${CONTEXTS[@]}"; do
  ctx_path "$c" >/dev/null || { echo "cannot map required context \"$c\" to a single workflow job name" >&2; exit 2; }
done
ok "0.1 all ${#CONTEXTS[@]} required contexts map to exactly one workflow file each"

# The context every mutation below acts on: prefer Console gate (the live
# specimen) but fall back to the first, so a rename cannot orphan the harness.
VICTIM="${CONTEXTS[0]}"
for c in "${CONTEXTS[@]}"; do [ "$c" = "Console gate" ] && VICTIM="$c"; done
VICTIM_PATH="$(ctx_path "$VICTIM")"
VICTIM_RUN=900001

BASE="$TMP/base"; mkdir -p "$BASE"

jq -n --arg sha "$SHA" '[{number: 9887, headRefOid: $sha, updatedAt: "2026-08-06T12:00:00Z"}]' > "$BASE/prs.json"

# Every required context rendered and concluded success.
: > "$TMP/checkruns.ndjson"
for c in "${CONTEXTS[@]}"; do
  jq -nc --arg n "$c" '{name: $n, status: "completed", conclusion: "success"}' >> "$TMP/checkruns.ndjson"
done
jq -sc '{check_runs: .}' "$TMP/checkruns.ndjson" > "$BASE/checkruns-$SHA.json"

# One completed run per producing workflow. The victim's run id is pinned so the
# mutations below can address it without re-deriving.
: > "$TMP/runs.ndjson"
i=900000
for c in "${CONTEXTS[@]}"; do
  if [ "$c" = "$VICTIM" ]; then id=$VICTIM_RUN; else i=$((i + 2)); id=$i; fi
  jq -nc --arg p "$(ctx_path "$c")" --argjson id "$id" \
    '{id: $id, path: $p, status: "completed", run_attempt: 1, created_at: "2026-08-06T22:00:00Z", head_sha: "'"$SHA"'"}' \
    >> "$TMP/runs.ndjson"
done
jq -sc '{workflow_runs: .}' "$TMP/runs.ndjson" > "$BASE/runs-$SHA.json"

# THE QUEUE. Seven runs are genuinely queued; the default page — the 30 newest
# runs, which on a busy repo are all recent and mostly completed — happens to
# contain two of them. That gap is the whole point of the paginated form, and it
# is reproduced here at fixture scale rather than asserted in prose.
queued_run() { # <id> <path> <created_at> <attempt>
  jq -nc --argjson id "$1" --arg p "$2" --arg t "$3" --argjson a "$4" \
    '{id: $id, path: $p, status: "queued", run_attempt: $a, created_at: $t, head_sha: "beefbeefbeefbeefbeefbeefbeefbeefbeefbeef"}'
}
{
  queued_run 910001 ".github/workflows/doc-gates.yml"       "2026-08-06T23:40:00Z" 1
  queued_run 910002 ".github/workflows/aesthetics-guard.yml" "2026-08-06T23:30:00Z" 1
  queued_run 910003 ".github/workflows/reland-check.yml"     "2026-08-06T23:20:00Z" 1
  queued_run 910004 ".github/workflows/go-tests.yml"         "2026-08-06T22:10:00Z" 1
  queued_run 910005 ".github/workflows/security.yml"         "2026-08-06T21:10:00Z" 1
  queued_run 910006 ".github/workflows/cloud.yml"            "2026-08-06T20:10:00Z" 1
  queued_run 910007 ".github/workflows/elixir.yml"           "2026-08-06T19:10:00Z" 1
} | jq -sc '{workflow_runs: .}' > "$BASE/queued-paginated.json"

# The default page: the two newest queued runs, plus completed noise that the
# client-side `select(.status=="queued")` correctly drops. Nothing older is on
# it, which is exactly why it cannot see the rest.
{
  queued_run 910001 ".github/workflows/doc-gates.yml"       "2026-08-06T23:40:00Z" 1
  queued_run 910002 ".github/workflows/aesthetics-guard.yml" "2026-08-06T23:30:00Z" 1
  jq -nc '{id: 910099, path: ".github/workflows/ci.yml", status: "completed", run_attempt: 1, created_at: "2026-08-06T23:50:00Z"}'
} | jq -sc '{workflow_runs: .}' > "$BASE/queued-unpaginated.json"

OUT="$(run_census "$BASE")"; RC=$?
if [ "$RC" = "0" ] && grep -q 'SUMMARY  absent=0  stale-queued=0  unknown=0' <<<"$OUT"; then
  ok "0.2 the base head is CLEAN — exit 0, $(grep -o 'SUMMARY.*' <<<"$OUT")"
else
  bad "0.2 the base fixture should be clean; exit $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
grep -q 'heads examined: 1' <<<"$OUT" \
  && ok "0.3 the open-PR list drove the walk — one head examined, read from prs.json" \
  || bad "0.3 expected 'heads examined: 1'"

# ═══ 1. MUTATION, DIRECTION ONE — an absent context must make this FAIL ══════
section "1. DIRECTION ONE: delete one rendered context and the census screams"

# Each specimen is the base with ONE field changed. Re-typing a whole fixture
# would prove the new fixture, not the mutation.
derive() { # <name> — copy of base, echoes its dir
  local d="$TMP/$1"; rm -rf "$d"; cp -R "$BASE" "$d"; echo "$d"
}
drop_victim_checkrun() { # <dir>
  jq --arg n "$VICTIM" '{check_runs: [.check_runs[] | select(.name != $n)]}' \
    "$1/checkruns-$SHA.json" > "$1/.tmp" && mv "$1/.tmp" "$1/checkruns-$SHA.json"
}

D1="$(derive zombied)"
drop_victim_checkrun "$D1"
# The producing run exists, is queued, is on its FIRST attempt, dispatched
# nothing (jobs.total_count 0), AND IS OLDER THAN THE THRESHOLD. All four are
# ZOMBIED. The age is not decoration: 2026-08-05T11:00:00Z against the pinned
# NOW is 37h, past the 24h default, and §1.6 below removes only the age and
# watches this same tuple stop being a zombie.
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "queued" | .created_at = "2026-08-05T11:00:00Z" else . end]}' \
  "$D1/runs-$SHA.json" > "$D1/.tmp" && mv "$D1/.tmp" "$D1/runs-$SHA.json"
jq -n '{total_count: 0, jobs: []}' > "$D1/jobs-$VICTIM_RUN.json"

OUT="$(run_census "$D1")"; RC=$?
if [ "$RC" = "1" ]; then
  ok "1.1 a head missing a required context FAILS the census (exit 1)"
else
  bad "1.1 expected exit 1 on an absent required context; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
if grep -q "ABSENT" <<<"$OUT" && grep -qF "context \"$VICTIM\" renders nowhere" <<<"$OUT"; then
  ok "1.2 …and it names the context: $(grep -F "renders nowhere" <<<"$OUT" | sed 's/^ *//')"
else
  bad "1.2 the failing output does not name \"$VICTIM\""; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
if grep -qE '^ +class +ZOMBIED$' <<<"$OUT"; then
  ok "1.3 …classified ZOMBIED (queued, attempt 1, jobs.total_count 0)"
else
  bad "1.3 expected class ZOMBIED"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
AGE="$(grep -oE 'age +[0-9.]+h' <<<"$OUT" | head -1 | grep -oE '[0-9.]+')"
if [ -n "$AGE" ] && awk -v a="$AGE" 'BEGIN { exit !(a > 0) }'; then
  ok "1.4 …and DATED: age ${AGE}h, anchored on the oldest queued run for that head"
else
  bad "1.4 the absence carries no positive age (got '${AGE:-none}')"
fi

# THE MUTATION THAT PROVES 1.1 CAN LOSE: put the check run back, change nothing
# else, and the same fixture must go green. Without this, 1.1 is satisfied by a
# script that fails on everything.
D1B="$(derive zombied-restored)"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "queued" else . end]}' \
  "$D1B/runs-$SHA.json" > "$D1B/.tmp" && mv "$D1B/.tmp" "$D1B/runs-$SHA.json"
jq -n '{total_count: 0, jobs: []}' > "$D1B/jobs-$VICTIM_RUN.json"
OUT="$(run_census "$D1B")"; RC=$?
if [ "$RC" = "0" ] && ! grep -q 'ABSENT' <<<"$OUT"; then
  ok "1.5 …and with the SAME zombied run but the context RENDERED, it is exit 0 — the verdict tracks absence, not queue state"
else
  bad "1.5 a rendered context beside a queued run should be exit 0; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# THE AGE GUARD, MUTATION-PROVEN. The live census scored a run created SIXTY
# SECONDS earlier as ZOMBIED — the class the header defines off a FIFTEEN-DAY
# specimen — because the implementation kept the tuple and dropped the age that
# made the tuple mean anything. Here the ONLY field that moves is created_at.
D1C="$(derive zombied-young)"
drop_victim_checkrun "$D1C"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "queued" | .created_at = "2026-08-06T23:59:00Z" else . end]}' \
  "$D1C/runs-$SHA.json" > "$D1C/.tmp" && mv "$D1C/.tmp" "$D1C/runs-$SHA.json"
jq -n '{total_count: 0, jobs: []}' > "$D1C/jobs-$VICTIM_RUN.json"
OUT="$(run_census "$D1C")"; RC=$?
if [ "$RC" = "0" ] && grep -qE '^ +class +UNDISPATCHED_YOUNG$' <<<"$OUT" && ! grep -q 'ABSENT' <<<"$OUT"; then
  ok "1.6 …and the SAME tuple one minute old is UNDISPATCHED_YOUNG at exit 0 — age is the discriminator, not the tuple"
else
  bad "1.6 a one-minute-old undispatched run must not be ZOMBIED; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
# …and the threshold is what does it, not the date literal: drop the bar under
# its age and the identical fixture becomes a zombie again.
OUT="$(run_census "$D1C" --stale-queue-hours 0)"; RC=$?
if [ "$RC" = "1" ] && grep -q 'ABSENT' <<<"$OUT" && grep -qE '^ +class +ZOMBIED$' <<<"$OUT"; then
  ok "1.7 …and lowering --stale-queue-hours to 0 turns that identical fixture back into a screaming ZOMBIED — the guard is the threshold"
else
  bad "1.7 the young fixture should be ZOMBIED under a zero threshold; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# ═══ 2. the other two classes ════════════════════════════════════════════════
section "2. RERUN_DELETED and NO_RUN are discriminated from ZOMBIED"

D2="$(derive rerun-deleted)"
drop_victim_checkrun "$D2"
# Same absence, ONE field different from the ZOMBIED specimen: run_attempt.
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .run_attempt = 3 else . end]}' \
  "$D2/runs-$SHA.json" > "$D2/.tmp" && mv "$D2/.tmp" "$D2/runs-$SHA.json"
OUT="$(run_census "$D2")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +RERUN_DELETED$' <<<"$OUT"; then
  ok "2.1 run_attempt=3 with no rendered check run ⇒ RERUN_DELETED (exit 1)"
else
  bad "2.1 expected class RERUN_DELETED at exit 1; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

D3="$(derive no-run)"
drop_victim_checkrun "$D3"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | select(.path != $p)]}' \
  "$D3/runs-$SHA.json" > "$D3/.tmp" && mv "$D3/.tmp" "$D3/runs-$SHA.json"
OUT="$(run_census "$D3")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +NO_RUN$' <<<"$OUT"; then
  ok "2.2 no run at all for the producing workflow ⇒ NO_RUN (exit 1)"
else
  bad "2.2 expected class NO_RUN at exit 1; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# Review fix. THE DOMINANT LIVE CLASS, and it used to have no name. The first
# real run of this census found ten absent contexts and three of them were a
# producing run that RAN TO COMPLETION on the head and still rendered no check
# run under that name — heads from July that predate a required context. They
# came out `UNCLASSIFIED(status=completed)`, i.e. the census reporting that it
# did not know, about the thing it knew most about. Different remedy from
# ZOMBIED (rebase or edit the spec, never re-dispatch), so a different name.
D2C="$(derive name-not-in-run)"
drop_victim_checkrun "$D2C"
OUT="$(run_census "$D2C")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +NAME_NOT_IN_RUN$' <<<"$OUT"; then
  ok "2.4 a COMPLETED producing run that rendered no check run of that name ⇒ NAME_NOT_IN_RUN (exit 1)"
else
  bad "2.4 expected class NAME_NOT_IN_RUN at exit 1; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
# …and it must not be reachable from a status the census has NOT ruled on: the
# named class is the `completed` arm alone, never a catch-all wearing a name.
D2D="$(derive unnamed-status)"
drop_victim_checkrun "$D2D"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "some_future_status" else . end]}' \
  "$D2D/runs-$SHA.json" > "$D2D/.tmp" && mv "$D2D/.tmp" "$D2D/runs-$SHA.json"
OUT="$(run_census "$D2D")"; RC=$?
if grep -qE '^ +class +UNCLASSIFIED\(status=some_future_status\)$' <<<"$OUT"; then
  ok "2.5 …and a status the census has never ruled on stays UNCLASSIFIED — the new name did not become a catch-all"
else
  bad "2.5 an unruled status was absorbed by a named class"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# A run whose job count cannot be read must NOT land in the calm class. Same
# ZOMBIED tuple as 1.3, one thing removed: the jobs feed.
D2E="$(derive jobs-unreadable)"
drop_victim_checkrun "$D2E"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "queued" else . end]}' \
  "$D2E/runs-$SHA.json" > "$D2E/.tmp" && mv "$D2E/.tmp" "$D2E/runs-$SHA.json"
rm -f "$D2E/jobs-$VICTIM_RUN.json"
OUT="$(run_census "$D2E")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +UNCLASSIFIED\(jobs-unreadable\)$' <<<"$OUT"; then
  ok "2.6 a queued run whose jobs feed cannot be read is UNCLASSIFIED(jobs-unreadable), never DISPATCHED_PENDING"
else
  bad "2.6 an unreadable jobs feed did not fail closed; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# The classes must be genuinely different verdicts on inputs that differ by ONE
# field, or the classifier is a label generator.
Z="$(run_census "$D1" | grep -E '^ +class ' | head -1)"
R="$(run_census "$D2" | grep -E '^ +class ' | head -1)"
N="$(run_census "$D3" | grep -E '^ +class ' | head -1)"
C="$(run_census "$D2C" | grep -E '^ +class ' | head -1)"
if [ "$(printf '%s\n%s\n%s\n%s\n' "$Z" "$R" "$N" "$C" | sort -u | grep -c .)" = "4" ]; then
  ok "2.3 the four classes are pairwise DISTINCT on inputs differing by one field:$(printf ' [%s]' "${Z//class/}" "${R//class/}" "${N//class/}" "${C//class/}" | tr -s ' ')"
else
  bad "2.3 two classes collapsed: [$Z] [$R] [$N] [$C]"
fi

# ═══ 3. MUTATION, DIRECTION TWO — a rendered PENDING check is NOT absent ═════
section "3. DIRECTION TWO: a rendered-but-unconcluded check run reports NOTHING"

# honest-gates D76 rules that a PENDING required check stays exit 0 in the merge
# path. This census is not that path and does not reverse it: its population is
# names that RENDER NOWHERE. Here the name renders — queued, conclusion null —
# and it must therefore be invisible to this instrument. If this probe ever goes
# red, the census has grown into the PENDING half and that is a different
# slice's territory.
D4="$(derive pending-rendered)"
jq --arg n "$VICTIM" '{check_runs: [.check_runs[] | if .name == $n then .status = "queued" | .conclusion = null else . end]}' \
  "$D4/checkruns-$SHA.json" > "$D4/.tmp" && mv "$D4/.tmp" "$D4/checkruns-$SHA.json"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "in_progress" else . end]}' \
  "$D4/runs-$SHA.json" > "$D4/.tmp" && mv "$D4/.tmp" "$D4/runs-$SHA.json"
OUT="$(run_census "$D4")"; RC=$?
if [ "$RC" = "0" ] && ! grep -q 'ABSENT' <<<"$OUT" && grep -q 'absent=0' <<<"$OUT"; then
  ok "3.1 a rendered check run with status=queued, conclusion=null is NOT reported ABSENT (exit 0, absent=0)"
else
  bad "3.1 a rendered pending check must not be reported absent; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
# And the probe is not vacuous: remove that same check run, leave the producing
# run COMPLETED, and the identical fixture screams. Completed is load-bearing
# here — while the producing run is still working, a missing name is population
# 3 below, not an absence, and §3.4 pins that separately.
D4B="$(derive pending-deleted)"
drop_victim_checkrun "$D4B"
OUT="$(run_census "$D4B")"; RC=$?
if [ "$RC" = "1" ] && grep -q 'ABSENT' <<<"$OUT"; then
  ok "3.2 …and REMOVING that check run beside a COMPLETED producing run flips the identical fixture to ABSENT — the probe can lose"
else
  bad "3.2 the pending probe is vacuous: removing the check run did not flip it (exit $RC)"
fi

# ═══ 3b. POPULATION THREE — the job GitHub has not created yet ═══════════════
section "3b. a needs:-gated job that does not exist YET is not an absence"

# THE FIXTURE THIS HARNESS NEVER HAD, and its absence is why the census ran red
# 71 times out of 71 between 2026-08-07 and 2026-08-24 while this suite passed
# on every one of those runs. §3.1 above pins a check run that IS RENDERED and
# unconcluded. It says nothing about a job that DOES NOT EXIST — and GitHub does
# not create a `needs:`-gated job, or any check run for it, until every one of
# its `needs:` has concluded. Every gate in this repo is a terminal aggregator,
# so this population is non-empty on every pull request for the whole first
# phase of its CI.
#
# The shape, captured from run 32766664303 (cloud.yml, PR #14040) at 19:11Z on
# 2026-08-24: the run is queued, jobs.total_count is 2, and the two jobs are the
# UPSTREAM ones — the gate itself is not in the list. Twenty minutes later the
# same run id reported total_count 5 with `Cloud gate` present. Nothing was
# fixed in between.
D4C="$(derive job-not-created-yet)"
drop_victim_checkrun "$D4C"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "queued" else . end]}' \
  "$D4C/runs-$SHA.json" > "$D4C/.tmp" && mv "$D4C/.tmp" "$D4C/runs-$SHA.json"
# Jobs DISPATCHED — and the victim's own job deliberately not among them.
jq -n --arg v "$VICTIM" '{total_count: 2, jobs: [
    {name: "Dispatch (changed-path sets)", status: "completed", conclusion: "success"},
    {name: "path-escape ratchet",          status: "queued",    conclusion: null}
  ]}' > "$D4C/jobs-$VICTIM_RUN.json"
OUT="$(run_census "$D4C")"; RC=$?
if [ "$RC" = "0" ] && grep -qE '^ +class +DISPATCHED_PENDING$' <<<"$OUT" && grep -q 'absent=0' <<<"$OUT"; then
  ok "3.3 a producing run still working, with the gate job NOT in its job list, is DISPATCHED_PENDING at exit 0 — not an absence"
else
  bad "3.3 a not-yet-created needs:-gated job must not be reported absent; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
if grep -qF "context \"$VICTIM\" has not been created yet" <<<"$OUT"; then
  ok "3.4 …and it is REPORTED, in the in-flight column, naming the context — routed, never suppressed"
else
  bad "3.4 the in-flight row does not name \"$VICTIM\""; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# THE MUTATION THAT PROVES 3.3 CAN LOSE. One field moves — the producing run
# finishes — and the very same missing name becomes a standing absence. Without
# this, 3.3 is satisfied by a census that stopped looking at heads entirely.
D4D="$(derive job-never-created)"
cp -R "$D4C/." "$D4D/"
jq --arg p "$VICTIM_PATH" '{workflow_runs: [.workflow_runs[] | if .path == $p then .status = "completed" else . end]}' \
  "$D4D/runs-$SHA.json" > "$D4D/.tmp" && mv "$D4D/.tmp" "$D4D/runs-$SHA.json"
OUT="$(run_census "$D4D")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +NAME_NOT_IN_RUN$' <<<"$OUT" && grep -qF "context \"$VICTIM\" renders nowhere" <<<"$OUT"; then
  ok "3.5 …and the SAME fixture with the producing run COMPLETED screams NAME_NOT_IN_RUN, naming it — 'still working' is the discriminator, not 'we stopped looking'"
else
  bad "3.5 completing the producing run did not flip 3.3 to a scream; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# ═══ 3c. the conflicted head ═════════════════════════════════════════════════
section "3c. a CONFLICTING pull request is a merge conflict, not a missing context"

# GitHub cannot compute a merge commit for a conflicted pull request, so it runs
# no `pull_request` workflow at all and every required context goes missing at
# once. That is already reported — by the pull request's own UI and by
# `mergeable` — and this census exists for what NOTHING ELSE reports.
D4E="$(derive pr-conflicted)"
jq '[.[] | .mergeable = "CONFLICTING"]' "$D4E/prs.json" > "$D4E/.tmp" && mv "$D4E/.tmp" "$D4E/prs.json"
jq '{check_runs: []}' "$D4E/checkruns-$SHA.json" > "$D4E/.tmp" && mv "$D4E/.tmp" "$D4E/checkruns-$SHA.json"
jq '{workflow_runs: []}' "$D4E/runs-$SHA.json" > "$D4E/.tmp" && mv "$D4E/.tmp" "$D4E/runs-$SHA.json"
OUT="$(run_census "$D4E")"; RC=$?
if [ "$RC" = "0" ] && grep -qE '^ +class +PR_CONFLICTED$' <<<"$OUT" && grep -q 'absent=0' <<<"$OUT"; then
  ok "3.6 a CONFLICTING head with no runs and nothing rendered is PR_CONFLICTED at exit 0"
else
  bad "3.6 expected PR_CONFLICTED at exit 0; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
# …and `mergeable` is doing the work, not the empty run list: flip that ONE
# field back and the identical fixture screams NO_RUN for every context.
D4F="$(derive pr-mergeable)"
cp -R "$D4E/." "$D4F/"
jq '[.[] | .mergeable = "MERGEABLE"]' "$D4F/prs.json" > "$D4F/.tmp" && mv "$D4F/.tmp" "$D4F/prs.json"
OUT="$(run_census "$D4F")"; RC=$?
if [ "$RC" = "1" ] && grep -qE '^ +class +NO_RUN$' <<<"$OUT"; then
  ok "3.7 …and flipping mergeable to MERGEABLE turns the identical fixture into a screaming NO_RUN — one field, whole verdict"
else
  bad "3.7 mergeable is not the discriminator: the MERGEABLE twin did not scream; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# ═══ 4. the queue query, and the assertion that can lose ═════════════════════
section "4. the paginated queue query beats the default-page form — STRICTLY"

queue_pair() { # <fixture dir> -> "<paginated> <default>"
  local o p d
  o="$(run_census "$1")"
  # `--` before the pattern, and never a pattern that STARTS with a dash: the
  # first attempt here anchored on `--paginate)` and grep read it as an option,
  # which made both counts unreadable and printed `x` — the harness would have
  # reported its own parse failure as a queue with no gap.
  p="$(grep -oE -- 'paginate\): +[0-9]+' <<<"$o" | grep -oE '[0-9]+$')"
  d="$(grep -oE -- 'form that loses\): +[0-9]+' <<<"$o" | grep -oE '[0-9]+$')"
  echo "${p:-x} ${d:-x}"
}

# THE ACCEPTANCE IS A STRICT INEQUALITY, NEVER A PINNED PAIR. Four live samples
# in one night gave 0-vs-6, 0-vs-6, 1-vs-7 and 0-vs-7 — the pair is a property
# of the hour, the relation is the property of the query.
read -r QP QD <<<"$(queue_pair "$BASE")"
if [ "$QP" != "x" ] && [ "$QD" != "x" ] && [ "$QP" -gt "$QD" ]; then
  ok "4.1 paginated ($QP) > default page ($QD) — the strict inequality holds, and no pair is pinned"
else
  bad "4.1 expected paginated > default page; read paginated=$QP default=$QD"
fi

# THE ASSERTION ABOVE MUST BE ABLE TO LOSE. Hand the script a world where the
# default page happens to carry the whole queue and 4.1's comparison must fail —
# otherwise it is a `>` that has never been asked a hard question.
D5="$(derive queue-no-gap)"
cp "$BASE/queued-paginated.json" "$D5/queued-unpaginated.json"
read -r QP2 QD2 <<<"$(queue_pair "$D5")"
if [ "$QP2" = "$QD2" ]; then
  ok "4.2 …and on a fixture where the default page carries the whole queue the counts are EQUAL ($QP2 = $QD2), so 4.1's \`>\` is a question the harness can fail"
else
  bad "4.2 the no-gap fixture did not produce equal counts: paginated=$QP2 default=$QD2"
fi

# The undercount is reported in words, not left for a reader to subtract.
# Here-string, never `run_census … | grep -q`: under `set -o pipefail` a matching
# `grep -q` exits at once, the census upstream takes SIGPIPE, and the pipeline
# reports 141 — so a PRESENT line reads as absent. This probe failed exactly that
# way before the rewrite, which is the same trap required-checks-verify.sh
# documents at its own set-difference loop.
grep -q 'UNDERCOUNTING by 5 run(s)' <<<"$(run_census "$BASE")" \
  && ok "4.3 the gap is named in the report: 'the default-page form is UNDERCOUNTING by 5 run(s) right now'" \
  || bad "4.3 the undercount line is missing or wrong"

section "5. a queued run older than the threshold screams on its own"

# The fifteen-day pr-task-gate zombie sits on a branch that will never push
# again: no PR head carries it, so the ABSENT walk above can never see it. Only
# the repo-wide queue census can, which is why this exits non-zero WITHOUT any
# absent context.
D6="$(derive stale-queue)"
jq '{workflow_runs: [.workflow_runs[] | if .id == 910007 then .created_at = "2026-07-23T07:38:15Z" | .run_attempt = 9 else . end]}' \
  "$D6/queued-paginated.json" > "$D6/.tmp" && mv "$D6/.tmp" "$D6/queued-paginated.json"
OUT="$(run_census "$D6")"; RC=$?
if [ "$RC" = "1" ] && grep -q 'STALE (> 24h)' <<<"$OUT" && grep -q 'absent=0  stale-queued=1' <<<"$OUT"; then
  ok "5.1 a 15-day queued run FAILS the census with zero absent contexts: $(grep -o 'attempt 9 .*STALE.*' <<<"$OUT")"
else
  bad "5.1 expected exit 1 from the stale queue alone; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi
OUT="$(run_census "$D6" --stale-queue-hours 100000)"; RC=$?
if [ "$RC" = "0" ]; then
  ok "5.2 …and raising --stale-queue-hours past its age clears it — the threshold is doing the work, not a hardcoded id"
else
  bad "5.2 the same fixture should pass under an enormous threshold; got $RC"
fi

# ═══ 5b. the two limbs are reported APART ════════════════════════════════════
section "5b. the queue limb states its own verdict, whatever the absence limb does"

# WHY THIS PROBE EXISTS. The two limbs used to share one sentence and one exit
# code, and the consequence was measured: seven undispatched runs on a real main
# commit sat unactioned for seventeen days while the absence limb over-reported
# on every one of the 71 runs this census had. The queue finding was correct the
# whole time and nobody could see it. A reader grepping for the queue verdict
# must get an answer the absence limb cannot dilute or suppress.
QUEUE_LINE='VERDICT  queue limb'
ABSENCE_LINE='VERDICT  absence limb'

# Both limbs firing at once — the hard case, and the one the fused report lost.
D10="$(derive both-limbs)"
drop_victim_checkrun "$D10"
jq '{workflow_runs: [.workflow_runs[] | if .id == 910007 then .created_at = "2026-07-23T07:38:15Z" | .run_attempt = 9 else . end]}' \
  "$D10/queued-paginated.json" > "$D10/.tmp" && mv "$D10/.tmp" "$D10/queued-paginated.json"
OUT="$(run_census "$D10")"; RC=$?
if [ "$RC" = "1" ] \
   && grep -qF "$QUEUE_LINE   : SCREAM" <<<"$OUT" \
   && grep -qF "$ABSENCE_LINE : SCREAM" <<<"$OUT"; then
  ok "5.3 with BOTH limbs firing, each states its own SCREAM on its own line — neither is folded into the other"
else
  bad "5.3 both limbs firing did not produce two separate verdict lines; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# THE ONE THAT MATTERS: a screaming absence limb must not make the queue limb
# report anything but the truth about the queue.
D11="$(derive absence-only)"
drop_victim_checkrun "$D11"
OUT="$(run_census "$D11")"; RC=$?
if [ "$RC" = "1" ] \
   && grep -qF "$ABSENCE_LINE : SCREAM" <<<"$OUT" \
   && grep -qF "$QUEUE_LINE   : clean" <<<"$OUT"; then
  ok "5.4 …and a screaming ABSENCE limb still lets the queue limb report CLEAN — the limbs cannot contaminate each other"
else
  bad "5.4 the queue limb did not report clean beside a screaming absence limb; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# And the mirror, which is the seventeen-day case exactly: a clean absence limb
# beside a screaming queue.
OUT="$(run_census "$D6")"; RC=$?
if [ "$RC" = "1" ] \
   && grep -qF "$QUEUE_LINE   : SCREAM" <<<"$OUT" \
   && grep -qF "$ABSENCE_LINE : clean" <<<"$OUT"; then
  ok "5.5 …and a queue-only finding is stated as a queue-only finding, with the absence limb explicitly CLEAN"
else
  bad "5.5 the queue-only fixture did not separate the limbs; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# The verdict lines must be able to say `clean` — otherwise 5.4 and 5.5 are
# satisfied by a report that prints SCREAM unconditionally.
OUT="$(run_census "$BASE")"; RC=$?
if [ "$RC" = "0" ] \
   && grep -qF "$QUEUE_LINE   : clean" <<<"$OUT" \
   && grep -qF "$ABSENCE_LINE : clean" <<<"$OUT"; then
  ok "5.6 …and on the clean base fixture BOTH lines read clean — the word SCREAM is earned, not printed"
else
  bad "5.6 the base fixture did not report both limbs clean; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# ═══ 6. it fails CLOSED — an unreadable feed is never a clean bill of health ══
section "6. an unreadable feed is UNKNOWN (exit 2), never a silent pass"

D7="$(derive unreadable-checkruns)"
rm -f "$D7/checkruns-$SHA.json"
OUT="$(run_census "$D7")"; RC=$?
if [ "$RC" = "2" ] && grep -q 'UNKNOWN' <<<"$OUT"; then
  ok "6.1 a missing check-run feed exits 2 and says UNKNOWN — the head is NOT certified clean"
else
  bad "6.1 expected exit 2 + UNKNOWN on an unreadable check-run feed; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

D8="$(derive empty-spec)"
jq '.protection.required_status_checks.checks = []' "$SPEC" > "$D8/spec.json"
OUT="$(env PATH="$NOGH:/usr/bin:/bin" bash "$CENSUS" --fixtures "$D8" --now "$NOW" \
        --spec "$D8/spec.json" --workflows "$WORKFLOWS" --repo FRIKKern/barkpark 2>&1)"; RC=$?
if [ "$RC" = "2" ]; then
  ok "6.2 a spec with ZERO required contexts exits 2 — 'nothing absent' out of an empty required set is a broken input, not health"
else
  bad "6.2 an empty required set should exit 2; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

D9="$(derive unmapped-context)"
drop_victim_checkrun "$D9"
OUT="$(env PATH="$NOGH:/usr/bin:/bin" bash "$CENSUS" --fixtures "$D9" --now "$NOW" \
        --spec "$SPEC" --workflows "$TMP/nogh" --repo FRIKKern/barkpark 2>&1)"; RC=$?
if [ "$RC" = "2" ] && grep -q 'maps to no single workflow job name' <<<"$OUT"; then
  ok "6.3 an absent context that maps to no workflow is UNKNOWN, not a guessed class"
else
  bad "6.3 expected exit 2 on an unmappable absent context; got $RC"; printf '%s\n' "$OUT" | sed 's/^/       /' >&2
fi

# ═══ 7. the workflow shape ═══════════════════════════════════════════════════
section "7. the workflow is schedule-only with a static job name"

# THE SHAPE IS LOAD-BEARING, TWICE OVER. A `pull_request` trigger would put this
# workflow's names into the required-check generator's sample; a templated job
# name is refused outright by the blocking spec gate. And a schedule is the only
# trigger that can observe a queue on a branch that will never push again.
shape_report() { # <yml file> -> lines of findings, empty when the shape is right
  local f="$1"
  # Workflow-level trigger block only: everything from the trigger key to the
  # next top-level key. A `pull_request` mentioned in a comment or in an `if:`
  # is not a trigger and must not be matched.
  #
  # THE KEY IS `on:`, `"on":` OR `'on':` — all three the same key to GitHub.
  # YAML 1.1 resolves a bare `on` to the BOOLEAN true, so yamllint's `truthy`
  # rule pushes authors to quote it, and a `/^on:/` byte anchor reads a quoted
  # workflow as having NO trigger block at all: this shape check would then
  # print ok over an empty string — a green earned over nothing, which is the
  # exact defect this harness exists to catch. Same anchor, same three
  # spellings, as scripts/required-checks-generate.sh build_workflow_index.
  local trig
  trig="$(awk '/^("on"|\047on\047|on)[ \t]*:/ {inon=1; next} /^[A-Za-z"\047]/ {inon=0} inon {print}' "$f" | sed 's/#.*//')"
  grep -qE '^[[:space:]]+schedule:' <<<"$trig" || echo "NO SCHEDULE TRIGGER"
  grep -qE '^[[:space:]]+pull_request(_target)?:' <<<"$trig" && echo "PULL_REQUEST TRIGGER"
  # Job names, comments stripped.
  local names
  names="$(sed 's/#.*//' "$f" | grep -E '^[[:space:]]+name:[[:space:]]*\S' || true)"
  [ -n "$names" ] || echo "NO JOB NAME"
  grep -qF '${{' <<<"$names" && echo "TEMPLATED JOB NAME"
  true
}

SHAPE="$(shape_report "$WF")"
if [ -z "$SHAPE" ]; then
  ok "7.1 $(basename "$WF"): schedule trigger present, no pull_request trigger, job name is a static literal"
else
  bad "7.1 workflow shape is wrong: $(tr '\n' ';' <<<"$SHAPE")"
fi
JOBNAME="$(sed 's/#.*//' "$WF" | grep -E '^[[:space:]]+name:[[:space:]]*\S' | head -1 | sed 's/^[[:space:]]*name:[[:space:]]*//')"
ok "7.2 the literal job name is: $JOBNAME"

# The shape checker must be able to fail, in each direction independently.
CANARY="$TMP/canary-pr.yml"
awk '/^("on"|\047on\047|on)[ \t]*:/ { print; print "  pull_request:"; next } { print }' "$WF" > "$CANARY"
grep -q 'PULL_REQUEST TRIGGER' <<<"$(shape_report "$CANARY")" \
  && ok "7.3 …and a planted \`pull_request:\` trigger FIRES the check (mutation-proven able to fail)" \
  || bad "7.3 the shape checker did not fire on a planted pull_request trigger"

CANARY2="$TMP/canary-name.yml"
sed 's/^\([[:space:]]*\)name:\([[:space:]]*\).*$/\1name:\2Census ${{ matrix.thing }}/' "$WF" \
  | awk 'NR==1 && /name:/ { print "name: absent-context-census"; next } { print }' > "$CANARY2"
grep -q 'TEMPLATED JOB NAME' <<<"$(shape_report "$CANARY2")" \
  && ok "7.4 …and a templated job name FIRES it too — the shape the spec gate refuses as CATCH-ALL cannot land here" \
  || bad "7.4 the shape checker did not fire on a templated job name"

# The scheduled run must actually execute this harness, or the census ships
# without its own tripwire.
grep -q 'absent-context-census.test.sh' "$WF" \
  && ok "7.5 the scheduled run executes this harness — the instrument proves it can fail before it reports" \
  || bad "7.5 $(basename "$WF") never runs absent-context-census.test.sh"

# ═══ 8. the fence ════════════════════════════════════════════════════════════
section "8. the three new files stay inside the fence"

# THE SCANNED SET EXCLUDES THIS FILE, and the exclusion is the same one
# required-checks.test.sh makes for its own §13 and §18 ratchets: a harness that
# plants a specimen in order to watch a scan fire necessarily contains the
# specimen, so scanning itself pins the guard to its own canaries and reds on
# every edit. The two files that SHIP the behaviour are both scanned; the canary
# below then proves the scan is live.
MINE=("$CENSUS" "$WF")

if grep -lE 'gh pr merge[^`]*--admin' "${MINE[@]}" >/dev/null 2>&1; then
  bad "8.1 one of the new files teaches the abolished merge verb"
else
  ok "8.1 none of the three new files teaches \`gh pr merge … --admin\` (required-checks.test.sh §13)"
fi
# Disarmed: plant it and watch the same grep fire.
printf 'poll checks + gh pr merge --squash --admin\n' > "$TMP/admin-canary.txt"
grep -lE 'gh pr merge[^`]*--admin' "$TMP/admin-canary.txt" >/dev/null 2>&1 \
  && ok "8.2 …and the scan FIRES on a planted line (it is not a grep that can only pass)" \
  || bad "8.2 the admin-verb scan did not fire on its canary"

CLAIM_RE='(no|No|NO|zero|Zero) branch protection|main is NOT PROTECTED|no CI check in this repo can block a merge'
if grep -lE "$CLAIM_RE" "${MINE[@]}" >/dev/null 2>&1; then
  bad "8.3 one of the new files claims this repo's main is unprotected"
else
  ok "8.3 none of the three new files makes a protection claim §18 censuses"
fi
# THE CANARY IS MATERIALISED FROM THE REGEX, NEVER TYPED. required-checks.test.sh
# §18 is a BYTE census over scripts/ — writing the phrase literally here would
# plant a fresh UNPINNED row in that census and red the blocking spec gate with
# this harness's own canary. Deriving it keeps the specimen out of the file
# while still handing the scan a genuine hit at runtime.
CLAIM_CANARY="$(sed 's/^([^)]*)/no/; s/|.*//' <<<"$CLAIM_RE")"
printf 'this repo has %s at all\n' "$CLAIM_CANARY" > "$TMP/claim-canary.txt"
grep -lE "$CLAIM_RE" "$TMP/claim-canary.txt" >/dev/null 2>&1 \
  && ok "8.4 …and that scan FIRES on a planted claim too" \
  || bad "8.4 the protection-claim scan did not fire on its canary"

# The census must never be able to write. It reads three GitHub endpoints and
# nothing else, and a mutating verb in this file would be a merge-path actor
# wearing a reporter's name.
if grep -nE 'gh (api[^|]*-X (PUT|POST|PATCH|DELETE)|pr merge|api -X)' "$CENSUS" >/dev/null 2>&1; then
  bad "8.5 the census contains a mutating GitHub call"
else
  ok "8.5 the census makes no mutating GitHub call — it is a reader, never an actor"
fi

for f in "${MINE[@]}"; do
  case "$f" in
    *.yml) : ;;
    *) bash -n "$f" || bad "8.6 $(basename "$f") does not parse" ;;
  esac
done
ok "8.6 both shell files pass \`bash -n\`"

echo
echo "─────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
