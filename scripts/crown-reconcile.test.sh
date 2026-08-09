#!/usr/bin/env bash
# crown-reconcile.test.sh — the mutation proofs for the crown reconciler.
#
# FULLY HERMETIC. Every probe drives scripts/crown-reconcile.sh over fixtures
# this harness WRITES ITSELF, with `--now` pinning the window and with `gh` and
# `curl` removed from PATH — so "it made no API call" is an assertion about
# behaviour, not a claim about control flow. Nothing here depends on the wall
# clock, on GitHub, or on production being up.
#
# NOTHING HERE ASSERTS "THE SCRIPT RAN". Each verdict is proven by MUTATING one
# field of a base fixture and watching the verdict MOVE — and the base fixture is
# proven GREEN first, so every red below is a difference, not a default.
#
#   (a) a consistent window reconciles                              → exit 0
#   (b) ROW MISSING: a delivering run whose head sha has no row      → exit 1
#   (c) SHA MISMATCHED: a non-carried row no run delivered           → exit 1
#   (c2) RUN ID MISMATCHED: a row whose delivering_run_id is a ghost  → exit 1
#        (its SHA is one a run really delivered, so the old sha-only
#         comparison would have waved it through — this case is the
#         one that keeps the repaired WRONG axis able to LOSE)
#   (c3) NO RUN ID AT ALL: the head-sha comparison is the fallback    → 0 and 1
#   (d) WINDOW EMPTY: nothing to compare is never a green            → exit 2
#   (e) CROWN UNREADABLE: a read that did not happen is never green  → exit 2
#   (f) SERVING-UNRECORDED: the box serves a sha with no cp row      → exit 1
#   (t) THE SANDBOX ITSELF: a tool this harness "removes" is actually
#       gone on BOTH machines — the old shim prepended an empty dir to
#       /usr/bin, where a runner's `gh` lives, so an ABSENCE assertion
#       measured a tool that was still there (137/137 local, 136/137 CI)
#   (g) that same shape, but the process is seconds old              → exit 4
#       (a deploy in flight is NOT YET DUE: a warning, never a page and
#        never a green — and it must NAME the grace that fired, because
#        the three counters it used to print were all zero every time)
#   (g2) a grace in the same run as an unreadable condition           → exit 2
#        (2 outranks 4: a deferral never launders a silence)
#   (n) the graced sha is RE-ASKED on the next run and accused even
#       after the box has moved on to a different sha                 → exit 1
#   (n2) a cp row appearing is the only CLEAN retirement              → exit 0
#   (n3) the grace is charged against FIRST-SEEN, so a restart buys
#        no second grace                                              → exit 1
#   (p) a serving_since in the FUTURE is a FAULT, not leniency        → exit 1
#   (h) a docs-only run delivered nothing and MUST NOT be counted    → exit 0
#       (this is the false-positive that would drown the real reds)
#   (i) a CARRIED row naming a sha with no run of its own is correct → exit 0
#   (j) configuration faults are 3, and never 1 or 2
#   (j2) UNSET and SET-BUT-EMPTY are different statements about the PAT:
#        empty is rc 3 with its own sentence, missing still falls through
#        to the SSH reader CI actually uses                              → 3, 0
#   (s) the RE-ASK LIST states itself over its states, and the three
#       fixtures that were byte-identical now DIFFER          → 2, 0, 0 + cmp
#       …and a DECLARED first run is not a destroyed memory: the same
#       absent file exits 0 with the caller's statement and 2 without   → 0, 2
#   (o) WHICH READER ANSWERED is a verdict field: the same script,
#       driven down the SSH transport against a control plane in effigy,
#       names `route` when the route answers 200 and
#       `postgres-container` when it answers 401                        → 0, 0
#   (m) PREDATES-WRITER: a delivering run created before the
#       record-delivery job existed is its own printed class, with the
#       birth instant beside it — never a BEHIND                      → exit 0
#       and a window with NOTHING BUT such runs has no denominator     → exit 2
#
#   bash scripts/crown-reconcile.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR="$REPO_ROOT/scripts/crown-reconcile.sh"
WF="$REPO_ROOT/.github/workflows/crown-reconcile.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -f "$CR" ] || { echo "missing $CR" >&2; exit 2; }
[ -f "$WF" ] || { echo "missing $WF" >&2; exit 2; }

NOW="2026-08-09T12:00:00Z"
IN1="2026-08-09T09:40:00Z"   # inside a 24h window ending at NOW, AFTER the recorder's birth
IN2="2026-08-09T10:00:00Z"   # ditto
PRE="2026-08-09T06:00:00Z"   # inside the window, but BEFORE the recorder existed
OUT="2026-08-01T00:00:00Z"   # far outside it

# The recorder's birth instant is DERIVED from the script's own constant, never
# re-typed here: changing it there must move this harness, not rot into a stale
# literal. An underivable constant is a FAILURE, because an empty needle would
# match anything.
BIRTH="$(sed -n 's/^RECORDER_BIRTH_ISO="\([^"]*\)".*/\1/p' "$CR" | head -1)"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="cccccccccccccccccccccccccccccccccccccccc"
SHA_D="dddddddddddddddddddddddddddddddddddddddd"

# ── fixture builders ─────────────────────────────────────────────────────────
runs_json() { # <name> <sha:created>...
  local out="$TMP/$1.json"; shift
  local first=1
  {
    printf '{"workflow_runs":['
    local n=1
    for spec in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"id":%d,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"}' \
        "$n" "${spec%%:*}" "${spec#*:}"
      n=$((n + 1))
    done
    printf ']}'
  } > "$out"
  echo "$out"
}

jobs_json() { # <name> <run-id:legresult>...
  local out="$TMP/$1.json"; shift
  local first=1
  {
    printf '{'
    for spec in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '"%s":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"%s"},{"name":"instance","conclusion":"%s"}]' \
        "${spec%%:*}" "${spec#*:}" "${spec#*:}"
    done
    printf '}'
  } > "$out"
  echo "$out"
}

row() { # <sha> <target> <carried:true|false|omit> <first_seen> <run:id|omit>
  # Either field can be OMITTED, because both absences are real shapes the crown
  # can hand back: a row written before `carried` was measured, and a row written
  # before `delivering_run_id` existed.
  local carried_kv="" run_kv=""
  [ "$3" = "omit" ] || carried_kv=",\"carried\":$3"
  [ "$5" = "omit" ] || run_kv=",\"delivering_run_id\":\"$5\""
  printf '{"sha":"%s","target":"%s"%s,"first_seen_at":"%s"%s}' "$1" "$2" "$carried_kv" "$4" "$run_kv"
}

crown_json() { # <name> <row-json>...
  local out="$TMP/$1.json"; shift
  local first=1
  {
    printf '['
    for r in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '%s' "$r"
    done
    printf ']'
  } > "$out"
  echo "$out"
}

health_json() { # <name> <serving_sha> <serving_since>
  local out="$TMP/$1.json"
  printf '{"serving_sha":"%s","serving_since":"%s","git_sha":"%s"}' "$2" "$3" "$2" > "$out"
  echo "$out"
}

# `gh` and `curl` are removed from PATH: a fixture run that reaches for either
# is a bug this harness must catch, not tolerate.
#
# AND REMOVED HAS TO MEAN REMOVED ON BOTH MACHINES. This used to be an EMPTY
# directory prepended to `/usr/bin:/bin:/usr/sbin:/sbin` — which removes nothing
# at all when the tool being "removed" lives in one of those directories. On a
# GitHub runner `gh` IS /usr/bin/gh, so the (j2) assertion that the SSH path
# reaches `gh is required` was measuring a tool that was still there: 137/137
# locally, 136/137 in CI, on an assertion whose whole point is an ABSENCE.
# Locally `gh` sits in ~/bin, off that PATH, which is the only reason it passed.
#
# So the sandbox is a symlink FARM: exactly the tools crown-reconcile.sh is
# ALLOWED to see, and PATH is set to it ALONE. A tool that is not named here is
# absent on every machine, by construction, rather than by luck about where the
# distribution put it.
NOTOOLS="$TMP/notools"; mkdir -p "$NOTOOLS"
SANDBOX_ALLOWED="awk basename bash cat cp date dirname grep head install jq mkdir mktemp mv printf rm sed sort tail tr wc"
for t in $SANDBOX_ALLOWED; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$NOTOOLS/$t"
done
# PATH for every probe: the farm and NOTHING else.
SANDBOX_PATH="$NOTOOLS"
# The re-ask list OUTLIVES a run by design, so every probe gets a FRESH one and
# cannot inherit another arm's deferred accusation. An arm that wants two runs to
# share a list — the whole point of the re-read — sets CR_STATE itself.
CR_STATE=""
CR_N=0
# The STEADY state a real run leaves behind: a list that EXISTS and holds
# nothing. state_save writes its header unconditionally, so every run after the
# first finds this shape. Probes start here deliberately — ABSENT is its own
# arm below, because after the first run an absent list means DESTROYED, and a
# probe that started ABSENT would fold that named silence into every verdict.
seed_state() { # <path>
  mkdir -p "$(dirname "$1")"
  printf '# crown-reconcile re-ask list — "<sha> <first-seen-epoch>". Written %s.\n' "$NOW" > "$1"
}
CR_NOSEED=0
run_cr() { # <expected-rc> <label> [args…]
  local want="$1" label="$2"; shift 2
  local out rc state
  CR_N=$((CR_N + 1))
  state="${CR_STATE:-$TMP/state-$CR_N.txt}"
  [ "$CR_NOSEED" = "1" ] || [ -f "$state" ] || seed_state "$state"
  # UNSET, not empty: `CROWN_API_TOKEN=` is now its own configuration fault, and
  # neutralising the ambient environment must not silently assert that fault on
  # every probe. `-u` says what these probes mean — no PAT was asked for.
  out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY \
    PATH="$SANDBOX_PATH" \
    CROWN_STATE_FILE="$state" \
    bash "$CR" --now "$NOW" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last.out"
  if [ "$rc" = "$want" ]; then
    ok "$label → exit $rc"
  else
    bad "$label → exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  fi
  return 0
}

saw() { # <needle> <label>
  if grep -qF "$1" "$TMP/last.out"; then
    ok "$2"
  else
    bad "$2 — the output never said: $1"
    sed 's/^/       | /' "$TMP/last.out" >&2
  fi
}

not_saw() { # <needle> <label>
  if grep -qF "$1" "$TMP/last.out"; then
    bad "$2 — the output said: $1"
    sed 's/^/       | /' "$TMP/last.out" >&2
  else
    ok "$2"
  fi
}

section "(t) THE SANDBOX ITSELF — a tool this harness 'removes' must actually be gone"
# An assertion about an ABSENCE is only worth what the absence is worth. This
# section proves the sandbox on the machine it is running on, rather than
# trusting that `gh` happens to live somewhere the old PATH did not name.
case "$SANDBOX_PATH" in
  *:*) bad "the sandbox PATH still contains a system directory ($SANDBOX_PATH) — a tool 'removed' here is only removed on machines that put it elsewhere, which is exactly the local-pass/CI-fail split being cured" ;;
  "$NOTOOLS") ok "the sandbox PATH is the symlink farm ALONE — no system directory can re-supply a removed tool" ;;
  *) bad "the sandbox PATH is neither the farm nor a farm-plus-system list: $SANDBOX_PATH" ;;
esac
for t in gh curl ssh docker; do
  if (PATH="$SANDBOX_PATH"; command -v "$t" >/dev/null 2>&1); then
    bad "$t is still reachable inside the sandbox — every probe that assumes it is gone is vacuous"
  else
    ok "$t is genuinely absent inside the sandbox"
  fi
done
# …and the farm is not so empty that the script dies for the wrong reason. A
# sandbox missing `jq` would make every probe exit 3 and several would still
# 'pass' on their expected code.
for t in bash jq date sed awk sort grep; do
  if (PATH="$SANDBOX_PATH"; command -v "$t" >/dev/null 2>&1); then
    ok "$t is present inside the sandbox, so a probe fails for the reason it names"
  else
    bad "$t is MISSING from the sandbox farm — probes would fail on the tool, not on the behaviour"
  fi
done

# THE CI FAILURE, REPRODUCED ON PURPOSE. A directory that supplies `gh` stands in
# for /usr/bin on a GitHub runner. Under the OLD shape — farm plus that directory
# — the (j2) SSH-path probe never reaches "gh is required" (this is CI's 136/137).
# Under the new shape it does. Two runs, one difference.
SYSBIN="$TMP/sysbin"; mkdir -p "$SYSBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SYSBIN/gh"; chmod +x "$SYSBIN/gh"
out="$(env -u CROWN_API_TOKEN CP_HOST=cp.example.invalid DEPLOY_SSH_KEY=not-a-key \
  PATH="$SANDBOX_PATH:$SYSBIN" CROWN_STATE_FILE="$TMP/state-runner-emul.txt" \
  bash "$CR" --window-hours 24 2>&1)"
printf '%s\n' "$out" > "$TMP/last.out"
not_saw "gh is required" "with a runner-shaped system directory on PATH, gh is NOT missing — the old shim's absence assertion was measuring nothing on CI"
out="$(env -u CROWN_API_TOKEN CP_HOST=cp.example.invalid DEPLOY_SSH_KEY=not-a-key \
  PATH="$SANDBOX_PATH" CROWN_STATE_FILE="$TMP/state-runner-emul2.txt" \
  bash "$CR" --window-hours 24 2>&1)"
printf '%s\n' "$out" > "$TMP/last.out"
saw "gh is required" "and with the farm alone the SAME probe reaches the absence it asserts — on any machine"

# ── the base fixture: two delivering runs, both recorded ─────────────────────
RUNS_BASE="$(runs_json runs-base "$SHA_A:$IN1" "$SHA_B:$IN2")"
JOBS_BASE="$(jobs_json jobs-base "1:success" "2:success")"
CROWN_BASE="$(crown_json crown-base \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)")"
HEALTH_BASE="$(health_json health-base "$SHA_A" "$IN1")"

base_args() {
  echo --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
}

section "(a) the unmutated window reconciles — every red below is a DIFFERENCE"
run_cr 0 "consistent runs + rows + serving sha" $(base_args)
saw "RECONCILED: all 2 delivering run(s)" "it names its population when it is green"

section "(b) MUTATION: the row is missing — a delivering run nothing recorded"
CROWN_NOROW="$(crown_json crown-norow \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)")"
run_cr 1 "run 2 delivered $SHA_B and the crown has no row" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_NOROW" --health-fixture "$HEALTH_BASE"
saw "BEHIND: 1 of 2 delivering run(s) examined (50.0%)" "the BEHIND rate prints its POPULATION, not a bare count"
saw "$SHA_B" "it names the sha that was delivered and never recorded"

section "(c) MUTATION: the sha is mismatched — a row no run delivered"
CROWN_GHOST="$(crown_json crown-ghost \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN2" 9)")"
run_cr 1 "the crown carries a non-carried row for $SHA_C that no run delivered" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_GHOST" --health-fixture "$HEALTH_BASE"
saw "WRONG: 1 of 4 crown row(s) examined (25.0%)" "the WRONG rate prints its POPULATION too"
saw "$SHA_C" "it names the ghost sha"

section "(c2) MUTATION: the delivering_run_id is a ghost, though the sha is real"
# This is the case the old sha-keyed comparison could not lose on: $SHA_A WAS
# delivered, so a sha-only alibi waves this row through. The row states run 9999
# wrote it, and no such delivering run exists.
CROWN_GHOSTRUN="$(crown_json crown-ghostrun \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 9999)" \
  "$(row "$SHA_B" instance false "$IN2" 2)")"
run_cr 1 "a row for the delivered $SHA_A claims delivering run 9999, which does not exist" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_GHOSTRUN" --health-fixture "$HEALTH_BASE"
saw "WRONG: 1 of 3 crown row(s) examined" "the run-id alibi can LOSE even when the sha is one a run delivered"
saw "run 9999" "it names the delivering run the row invented"

section "(c2b) the inverse: a served sha no run has as its HEAD sha is CORRECT"
# The live false accusation, in fixture form. #11203 made the recorder write the
# sha the BOX WAS SERVING as the primary carried=false row, so a legitimate row
# routinely names a sha that appears in no run's head_sha — as long as the run
# that wrote it is real. Before this slice, this exact shape printed WRONG.
CROWN_SERVED="$(crown_json crown-served \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN2" 2)")"
run_cr 0 "$SHA_C was SERVED by run 2, whose own head sha is $SHA_B" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_SERVED" --health-fixture "$HEALTH_BASE"
not_saw "WRONG:" "a row whose delivering run is real is never accused over its sha"

section "(c3) NO delivering_run_id at all — the head sha is the FALLBACK, not dead"
CROWN_NORUNID_OK="$(crown_json crown-norunid-ok \
  "$(row "$SHA_A" cp false "$IN1" omit)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)")"
run_cr 0 "a row with no run id whose sha a run DID deliver is clean" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_NORUNID_OK" --health-fixture "$HEALTH_BASE"
not_saw "WRONG:" "the fallback clears a legacy row whose sha is accounted for"

CROWN_NORUNID_BAD="$(crown_json crown-norunid-bad \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN2" omit)")"
run_cr 1 "a row with no run id and a sha no run delivered is still WRONG" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_NORUNID_BAD" --health-fixture "$HEALTH_BASE"
saw "no delivering run id" "it says the row stated no run and was judged on its sha"

section "(d) MUTATION: the window is empty — nothing compared is never a green"
RUNS_OLD="$(runs_json runs-old "$SHA_A:$OUT" "$SHA_B:$OUT")"
run_cr 2 "every successful run predates the window" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE"
saw "COULD NOT VERIFY: the population was EMPTY" "an empty population is refused, not rounded to reconciled"
not_saw "RECONCILED:" "it never claims reconciliation over zero runs"

section "(e) MUTATION: the crown cannot be read — a silence is never a green"
run_cr 2 "the crown fixture does not exist" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$TMP/does-not-exist.json"
saw "COULD NOT FULLY READ" "an unreadable crown is reported as a read failure"
not_saw "RECONCILED:" "it never reconciles what it could not read"

section "(f) MUTATION: production serves a sha the crown never heard of"
HEALTH_GHOST="$(health_json health-ghost "$SHA_D" "$IN2")"
run_cr 1 "barkpark.cloud serves $SHA_D and no cp row exists" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_GHOST"
saw "SERVING-UNRECORDED" "the serving check is its own named verdict"

section "(g) the same shape, seconds old — a deploy in flight is NOT YET DUE (rc 4)"
# MEASURED, not predicted: rc=2 fired six times in crown-reconcile.yml's whole
# history and FIVE of them were exactly this benign grace (four the same sha in
# four consecutive minutes). It is now its own code, so the workflow can warn
# instead of paging — WITHOUT the grace becoming silent, which is what the
# assertions below hold down.
HEALTH_FRESH="$(health_json health-fresh "$SHA_D" "2026-08-09T11:55:00Z")"
run_cr 4 "the serving process is 300s old — too young to accuse, so NOT YET DUE" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
not_saw "SERVING-UNRECORDED" "an in-flight deploy is never reported as a missing record"
# The silence used to announce itself with three counters that were ALL ZERO on
# every one of the four live runs that graced 4c8314c94 — the reason the run was
# not clean was nowhere in the sentence that said it was not clean.
saw "NOT YET DUE: 1 deferred condition(s) fired" "the rc-4 sentence COUNTS the deferrals that actually fired"
saw "SERVING GRACE:" "and it NAMES the grace, rather than printing counters the grace does not move"
not_saw "0 sha(s) unreadable" "the all-zero counter sentence is gone"
saw "DEFERRED to the next run" "the grace says out loud that it is a deferral, not a dismissal"
not_saw "COULD NOT FULLY READ" "a deferral is no longer reported as a condition that could not be READ"
not_saw "RECONCILED:" "and it is still not a green — a deferral is neither a page nor a pass"

section "(g2) A DEFERRAL NEVER LAUNDERS A SILENCE — 2 outranks 4"
# The regression the split invites: one benign grace in the same run as a real
# unreadable condition, downgrading the page to a warning. The unreadable row
# below ('carried' never measured) and the young serving process both fire.
CROWN_GRACE_AND_SILENCE="$(crown_json crown-grace-and-silence \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" instance omit "$IN1" 1)")"
run_cr 2 "a grace AND an unmeasured row in the same run — the silence wins" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_GRACE_AND_SILENCE" --health-fixture "$HEALTH_FRESH"
saw "SERVING GRACE:" "the deferral still fires and is still named"
saw "COULD NOT FULLY READ" "and the run is still reported as one that could not be fully read"
not_saw "NOT YET DUE:" "rc 4 does not get to speak over a condition that could not be read"

section "(n) THE DEFERRED RE-READ: a graced sha is re-asked after the box moves on"
# The live defect, in fixture form. 4c8314c94 was served 13:34–13:42Z with no row
# that could ever exist (its deploy run was CANCELLED with zero jobs). Four runs
# graced it; at 13:42:23Z the box moved to another sha and the accusation became
# permanently unmakeable. Run N grants the grace; run N+1 must still accuse.
CR_STATE="$TMP/state-reask.txt"; rm -f "$CR_STATE"
run_cr 4 "run N: $SHA_D is served, 300s old, unrecorded — graced" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
if grep -q "^$SHA_D " "$CR_STATE" 2>/dev/null; then
  ok "the graced sha and its first-seen instant were PERSISTED to the re-ask list"
else
  bad "the graced sha never reached the re-ask list at $CR_STATE — the next run has nothing to re-ask"
  [ -f "$CR_STATE" ] && sed 's/^/       | /' "$CR_STATE" >&2
fi
run_cr 1 "run N+1: the box now serves $SHA_A, and the graced $SHA_D is STILL accused" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
saw "GRACED-UNRECORDED: 1 sha(s)" "the deferred accusation fires on the next run"
saw "$SHA_D" "it names the sha the earlier run graced"
saw "graced-unrecorded=1" "the verdict line carries the new axis beside the others"
saw "whether or not the box still serves them" "it says the accusation does not depend on the box still serving it"
CR_STATE=""

section "(n2) a row appearing is the ONLY clean retirement"
CR_STATE="$TMP/state-retire.txt"; rm -f "$CR_STATE"
run_cr 4 "run N: $SHA_D graced again, on its own list" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
CROWN_RECORDED_D="$(crown_json crown-recorded-d \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_D" cp true "$IN2" 2)")"
run_cr 0 "run N+1: the crown now HAS a cp row for $SHA_D — the debt is settled" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_RECORDED_D" --health-fixture "$HEALTH_BASE"
not_saw "GRACED-UNRECORDED" "a sha that got its row is not accused"
saw "retired from the re-ask list" "the retirement is stated, not silent"
if grep -q "^$SHA_D " "$CR_STATE" 2>/dev/null; then
  bad "$SHA_D is still on the re-ask list after its row appeared — the list never drains"
else
  ok "the recorded sha was dropped from the re-ask list"
fi
CR_STATE=""

section "(n3) the grace is charged against FIRST-SEEN, not against process age"
# A box that restarts every few minutes reported a fresh young process every run,
# and under the old rule that bought a fresh grace forever. The list remembers.
CR_STATE="$TMP/state-nofresh.txt"
printf '%s %s\n' "$SHA_D" "$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s) - 3600 ))" > "$CR_STATE"
run_cr 1 "$SHA_D was first seen an hour ago and the process is 300s old — no second grace" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
saw "SERVING-UNRECORDED" "an hour-old debt is accused even though the process is young"
CR_STATE=""

section "(p) a serving_since in the FUTURE is a FAULT, never leniency"
# Live run 31316144030 printed "only -3s old" and granted the grace off a clock
# that disagreed with it. A guard that reads disagreement as kindness cannot lose.
HEALTH_SKEW="$(health_json health-skew "$SHA_D" "2026-08-09T12:05:00Z")"
run_cr 1 "the serving process claims to have started 300s from now" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_SKEW"
saw "SERVING-CLOCK-SKEW" "clock skew is its own named fault"
saw "300s in the FUTURE" "it says how far ahead the reported instant is"
saw "SERVING-UNRECORDED" "and the missing row is accused rather than excused"
not_saw "SERVING GRACE:" "no grace is granted off a clock that disagrees"

section "(h) a docs-only run delivered NOTHING and must not be counted BEHIND"
RUNS_DOCS="$(runs_json runs-docs "$SHA_A:$IN1" "$SHA_C:$IN2")"
JOBS_DOCS="$(jobs_json jobs-docs "1:success" "2:skipped")"
CROWN_DOCS="$(crown_json crown-docs \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)")"
run_cr 0 "run 2 skipped both legs and has no row — correctly" \
  --runs-fixture "$RUNS_DOCS" --jobs-fixture "$JOBS_DOCS" --crown-fixture "$CROWN_DOCS" --health-fixture "$HEALTH_BASE"
saw "1 delivered nothing (both legs skipped" "it says how many runs delivered nothing, beside the population"
not_saw "BEHIND:" "a docs-only merge never manufactures a BEHIND"

section "(i) a CARRIED row rides another run and is not WRONG"
CROWN_CARRIED="$(crown_json crown-carried \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" instance true "$IN1" 1)")"
run_cr 0 "$SHA_C rode run 1's range and has no run of its own" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_CARRIED" --health-fixture "$HEALTH_BASE"
not_saw "WRONG:" "a carried row is correct, not a ghost"

section "(i2) a row whose carried was NEVER MEASURED is not counted clean"
CROWN_UNMEASURED="$(crown_json crown-unmeasured \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" instance omit "$IN1" 1)")"
run_cr 2 "$SHA_C's carried flag is absent — unclassifiable, never assumed correct" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_UNMEASURED" --health-fixture "$HEALTH_BASE"
saw "never measured" "it says which row it could not classify"

section "(m) PREDATES-WRITER: a run older than the recorder is not BEHIND"
if [ -n "$BIRTH" ]; then
  ok "the recorder's birth instant is derivable from the script's own constant ($BIRTH)"
else
  bad "could not derive RECORDER_BIRTH_ISO from $CR — this section would be vacuous, so it fails instead"
fi
RUNS_PREDATE="$(runs_json runs-predate "$SHA_A:$IN1" "$SHA_B:$PRE")"
CROWN_ONLY_A="$(crown_json crown-only-a \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)")"
run_cr 0 "run 2 delivered $SHA_B before any recorder existed and has no row" \
  --runs-fixture "$RUNS_PREDATE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_ONLY_A" --health-fixture "$HEALTH_BASE"
not_saw "BEHIND:" "a run older than the writer is never accused of being BEHIND"
saw "PREDATES-WRITER: 1 of 2 delivering run(s)" "the exemption prints its own count over the full population"
saw "$BIRTH" "the birth instant is printed, so the exemption can be re-derived"
saw "$SHA_B" "the exempted run is named, not swallowed"

# The identical fixture judged BEHIND when its run is NEWER than the writer: the
# exemption keys on the run's own age, not on the row being absent.
RUNS_AFTER="$(runs_json runs-after "$SHA_A:$IN1" "$SHA_B:$IN2")"
run_cr 1 "the same missing row, but run 2 is newer than the writer" \
  --runs-fixture "$RUNS_AFTER" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_ONLY_A" --health-fixture "$HEALTH_BASE"
saw "BEHIND: 1 of 2" "after the writer existed, a missing row is BEHIND again"

section "(m2) a window of NOTHING BUT pre-writer runs has no denominator"
RUNS_ALL_PRE="$(runs_json runs-all-pre "$SHA_A:$PRE" "$SHA_B:$PRE")"
run_cr 2 "every delivering run in the window predates the recorder" \
  --runs-fixture "$RUNS_ALL_PRE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
saw "PREDATE the recorder's birth" "an all-exempt window is refused, not rounded to reconciled"
not_saw "RECONCILED:" "it never claims reconciliation over an empty BEHIND denominator"

section "(j) configuration faults are 3 — never a verdict, never a warning"
run_cr 3 "an unknown flag" --runs-fixture "$RUNS_BASE" --nonsense
run_cr 3 "--window-hours that is not a number" --runs-fixture "$RUNS_BASE" --window-hours soon
run_cr 3 "--now that is not an instant" --runs-fixture "$RUNS_BASE" --now yesterday
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" CROWN_STATE_FILE="$TMP/state-config.txt" bash "$CR" --window-hours 24 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "3" ]; then ok "no fixture and no credential → exit 3"; else bad "no credential → exit $rc, wanted 3"; fi
saw "CONFIG: no way to read the crown" "a missing credential says CREDENTIAL, never 'nothing to reconcile'"

section "(j2) UNSET and SET-BUT-EMPTY are different statements about the PAT"
# They were byte-identical: both printed `reader=ssh` and both returned 0 on the
# CI path, so an operator who exported an empty token was silently answered by a
# reader they did not choose. The two halves of this section are the whole point
# — the empty one must FAULT, and the missing one must still WORK.
out="$(env -u CP_HOST -u DEPLOY_SSH_KEY CROWN_API_TOKEN= PATH="$SANDBOX_PATH" CROWN_STATE_FILE="$TMP/state-emptypat.txt" bash "$CR" --window-hours 24 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "3" ]; then ok "CROWN_API_TOKEN set but EMPTY → exit 3"; else bad "an empty CROWN_API_TOKEN → exit $rc, wanted 3 (a reader asked for and not supplied is a CONFIGURATION fault)"; fi
saw "SET BUT EMPTY" "an explicitly-empty PAT names itself, rather than being downgraded in silence"
not_saw "CONFIG: no way to read the crown" "the empty-PAT fault is DISTINGUISHABLE from having no credential at all"

# The other half, and the one that would break CI if this slice over-reached: a
# MISSING PAT is not a fault. It falls through to the CP_HOST + DEPLOY_SSH_KEY
# reader deploy.yml already uses. `gh` is off PATH here, so the run dies later,
# at the RUN LIST — which is exactly the proof that select_reader let it past.
out="$(env -u CROWN_API_TOKEN CP_HOST=cp.example.invalid DEPLOY_SSH_KEY=not-a-key PATH="$SANDBOX_PATH" CROWN_STATE_FILE="$TMP/state-sshpath.txt" bash "$CR" --window-hours 24 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
saw "reader-transport=ssh" "with no PAT and CP_HOST + DEPLOY_SSH_KEY present, the SSH reader is selected — the working CI path is NOT broken"
not_saw "SET BUT EMPTY" "an absent PAT is never reported as an empty one"
not_saw "CONFIG: no way to read the crown" "an absent PAT with the SSH credentials present is not a missing credential"
saw "gh is required" "the run gets PAST reader selection and only then fails on a tool this harness removed"

section "(s) THE RE-ASK LIST STATES ITSELF — four states, one always-printed line"
# The defect, measured on THIS base fixture before the fix: an ABSENT state file
# and a PRESENT-but-header-only one produced output with the SAME md5
# (4b4399a7f447f078b11943d574892e3e), both ending in `RECONCILED: … and no
# earlier grace is still owed a row` — an assertion about a memory the run did
# not have. The three fixtures are driven here and required to DIFFER.
STATE_ABSENT="$TMP/state-absent.txt"; rm -f "$STATE_ABSENT"
CR_STATE="$STATE_ABSENT"; CR_NOSEED=1
run_cr 2 "ABSENT: the path is configured and the file is not there" $(base_args)
CR_NOSEED=0; CR_STATE=""
saw "— ABSENT; loaded 0 entry(ies), dropped 0 malformed line(s)." "ABSENT prints its own state, its path and its counts"
saw "the memory was destroyed between runs or the fetch that would have carried it failed" "ABSENT is a REASON, not a silent early return"
saw "COULD NOT FULLY READ" "a destroyed memory is NOT counted clean"
not_saw "RECONCILED:" "it never asserts 'no earlier grace is still owed a row' over a list it does not have"
cp "$TMP/last.out" "$TMP/out-absent.txt"

# ── A FIRST RUN IS NOT A DESTROYED MEMORY ────────────────────────────────────
# /var/lib/crown-reconcile/graced.txt has never been written on CP_HOST, so the
# ABSENT arm above is the state production is ACTUALLY in — and it pages. The
# distinguishing fact belongs to the CALLER, who holds the store, so it is
# stated: CROWN_STATE_FIRST_RUN=1. Both halves are proven, because a tolerance
# that also swallows a destroyed memory is the laundering it is meant to avoid.
STATE_FIRST="$TMP/state-first-run.txt"; rm -f "$STATE_FIRST"
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
  CROWN_STATE_FILE="$STATE_FIRST" CROWN_STATE_FIRST_RUN=1 \
  bash "$CR" --now "$NOW" $(base_args) 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "0" ]; then ok "ABSENT-FIRST-RUN: the caller states the store has never held a list → exit 0"; else bad "a declared first run → exit $rc, wanted 0 (the operator's first delivered crown alarm must not be about a file that never existed)"; printf '%s\n' "$out" | sed 's/^/       | /' >&2; fi
saw "— ABSENT-FIRST-RUN; loaded 0 entry(ies)" "a first run names itself as its own state, not as PRESENT-EMPTY"
saw "this is a FIRST RUN, not a destroyed memory" "and it says which of the two absences it is"
not_saw "COULD NOT FULLY READ" "a first run is not an unreadable condition"

# The other half, and the one that keeps the tolerance honest: the SAME absent
# file WITHOUT the caller's statement still pages. A run that could not REACH the
# store cannot make the claim, so transport silence lands here.
STATE_DESTROYED="$TMP/state-destroyed.txt"; rm -f "$STATE_DESTROYED"
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
  CROWN_STATE_FILE="$STATE_DESTROYED" \
  bash "$CR" --now "$NOW" $(base_args) 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "2" ]; then ok "the identical absence with NO first-run statement still exits 2 — a destroyed memory is not tolerated"; else bad "an unclaimed absent list → exit $rc, wanted 2 (the first-run tolerance is swallowing a destroyed memory)"; fi
not_saw "ABSENT-FIRST-RUN" "an absence nobody vouched for is never reported as a first run"

# A value that is not the literal 1 is NOT a claim: a typo must not buy silence.
STATE_TYPO="$TMP/state-typo.txt"; rm -f "$STATE_TYPO"
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
  CROWN_STATE_FILE="$STATE_TYPO" CROWN_STATE_FIRST_RUN=true \
  bash "$CR" --now "$NOW" $(base_args) 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "2" ]; then ok "CROWN_STATE_FIRST_RUN=true is not the literal 1, so it is not a claim → exit 2"; else bad "a non-1 first-run value → exit $rc, wanted 2"; fi

STATE_EMPTY="$TMP/state-empty.txt"; seed_state "$STATE_EMPTY"
CR_STATE="$STATE_EMPTY"
run_cr 0 "PRESENT-EMPTY: the file exists and holds nothing" $(base_args)
CR_STATE=""
saw "— PRESENT-EMPTY; loaded 0 entry(ies), dropped 0 malformed line(s)." "PRESENT-EMPTY names itself"
saw "RECONCILED:" "an empty list is NOT a fault — it is the affirmative statement that nothing is owed"
cp "$TMP/last.out" "$TMP/out-empty.txt"

# PRESENT, and the entry retires cleanly, so the state line is the only thing
# separating this run from the one above.
STATE_PRESENT="$TMP/state-present.txt"; seed_state "$STATE_PRESENT"
printf '%s %s\n' "$SHA_D" "$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s) - 600 ))" >> "$STATE_PRESENT"
CROWN_WITH_D="$(crown_json crown-with-d \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_D" cp true "$IN2" 2)")"
CR_STATE="$STATE_PRESENT"
run_cr 0 "PRESENT: one entry loaded, and it retires because its row appeared" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_WITH_D" --health-fixture "$HEALTH_BASE"
CR_STATE=""
saw "— PRESENT; loaded 1 entry(ies), dropped 0 malformed line(s)." "PRESENT prints how many entries it actually loaded"
cp "$TMP/last.out" "$TMP/out-present.txt"

for pair in "absent:empty" "absent:present" "empty:present"; do
  a="$TMP/out-${pair%%:*}.txt"; b="$TMP/out-${pair#*:}.txt"
  if cmp -s "$a" "$b"; then
    bad "the ${pair%%:*} and ${pair#*:} runs are still byte-identical — the state line is not distinguishing them"
  else
    ok "the ${pair%%:*} and ${pair#*:} runs are no longer byte-identical"
  fi
done

# D is counted SEPARATELY from N, so a corrupted list cannot masquerade as a
# short one.
STATE_BAD="$TMP/state-malformed.txt"; seed_state "$STATE_BAD"
printf 'not-a-sha 123\n%s no-instant\n' "$SHA_D" >> "$STATE_BAD"
CR_STATE="$STATE_BAD"
run_cr 2 "two malformed lines are DROPPED and counted apart from the entries" $(base_args)
CR_STATE=""
saw "— PRESENT-EMPTY; loaded 0 entry(ies), dropped 2 malformed line(s)." "a corrupted list cannot masquerade as a short one"

# The closing half. `wrote M>0` followed by the next run's `loaded 0` is the
# eviction signature, and it only reads if BOTH halves are always printed.
STATE_WROTE="$TMP/state-wrote.txt"; seed_state "$STATE_WROTE"
CR_STATE="$STATE_WROTE"
run_cr 4 "a grace is granted, so the run must say what it wrote" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
CR_STATE=""
saw "RE-ASK LIST: wrote 1 entry(ies) to $STATE_WROTE" "state_save closes symmetrically with what it persisted"

# UNCONFIGURED is still rc 2, and now says so on the same line as the others.
# `--state-file ""` is how a caller says "no list at all" out loud; an unset
# CROWN_STATE_FILE falls back to the temp-directory default, which is the
# separate (and also printed) hole below.
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" bash "$CR" --now "$NOW" --state-file "" $(base_args) 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "2" ]; then ok "UNCONFIGURED: no path at all → exit 2"; else bad "an unconfigured re-ask list → exit $rc, wanted 2"; fi
saw "RE-ASK LIST: <none> [nowhere] — UNCONFIGURED" "UNCONFIGURED prints on the same always-present line as the other three states"

# A path under a temp directory is named as the hole it is, rather than implying
# a memory it does not have — this is what the production workflow's default was.
STATE_TMP="${TMPDIR:-/tmp}/crown-reconcile-harness-$$.txt"; seed_state "$STATE_TMP"
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" CROWN_STATE_FILE="$STATE_TMP" bash "$CR" --now "$NOW" $(base_args) 2>&1)"
printf '%s\n' "$out" > "$TMP/last.out"
rm -f "$STATE_TMP"
saw "does NOT survive a run boundary" "a state file in a temp directory says so, instead of passing for persistence"

section "(o) WHICH READER ANSWERED is a verdict field, not a repeated note:"
# The live shape, in effigy. A production run took the 401→postgres downgrade on
# every read and said so TEN times as a `note:` on stderr, behind a header that
# named only the TRANSPORT (`reader=ssh`). The transport is not the reader: the
# SSH transport carries two of them, and only the route's answer to the WORKER
# principal decides which one produced the rows.
#
# So this arm stands up a control plane in effigy — `gh`, `curl` and `ssh` are
# all fakes on PATH — and drives the SAME script down the SSH reader twice, once
# where the route answers 200 and once where it answers 401. The verdict field
# must NAME a different reader in each. A field that printed a constant would
# pass a single-case assertion, which is why there are two.
FAKE="$TMP/fake"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */jobs*) cat "$CR_FAKE_JOBS" ;;
  *) cat "$CR_FAKE_RUNS" ;;
esac
SH
cat > "$FAKE/curl" <<'SH'
#!/usr/bin/env bash
cat "$CR_FAKE_HEALTH"
SH
cat > "$FAKE/ssh" <<'SH'
#!/usr/bin/env bash
# The control plane's remote reader, in effigy: it reports which reader answered
# exactly the way scripts/crown-reconcile.sh's own remote.sh does.
echo "CR_HTTP=$CR_FAKE_HTTP"
echo "CR_VIA=$CR_FAKE_VIA"
echo "CR_BODY={\"deliveries\":$(cat "$CR_FAKE_ROWS")}"
SH
chmod +x "$FAKE/gh" "$FAKE/curl" "$FAKE/ssh"

RUNS_FAKE="$(runs_json runs-fake "$SHA_A:$IN1")"
printf '[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"success"},{"name":"instance","conclusion":"success"}]' > "$TMP/jobs-fake.json"
printf '[%s,%s]' "$(row "$SHA_A" cp false "$IN1" 1)" "$(row "$SHA_A" instance false "$IN1" 1)" > "$TMP/rows-fake.json"
HEALTH_FAKE="$(health_json health-fake "$SHA_A" "$IN1")"

run_fake() { # <expected-rc> <label> <http> <via>
  local want="$1" label="$2" http="$3" via="$4"
  local out rc state
  CR_N=$((CR_N + 1))
  state="$TMP/state-fake-$CR_N.txt"
  seed_state "$state"
  out="$(env -u CROWN_API_TOKEN PATH="$FAKE:$SANDBOX_PATH" \
    CP_HOST=cp.example.invalid DEPLOY_SSH_KEY=not-a-key \
    CR_FAKE_RUNS="$RUNS_FAKE" CR_FAKE_JOBS="$TMP/jobs-fake.json" \
    CR_FAKE_ROWS="$TMP/rows-fake.json" CR_FAKE_HEALTH="$HEALTH_FAKE" \
    CR_FAKE_HTTP="$http" CR_FAKE_VIA="$via" CROWN_STATE_FILE="$state" \
    bash "$CR" --now "$NOW" --window-hours 24 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last.out"
  if [ "$rc" = "$want" ]; then ok "$label → exit $rc"; else bad "$label → exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/       | /' >&2; fi
  return 0
}

run_fake 0 "the route answers 200 over the SSH transport" 200 route
saw "READER: transport=ssh, answered by route" "the reader that answered is its own printed field, beside the verdict"
saw "read by route" "and the green sentence names it too"

run_fake 0 "the route answers 401 to the WORKER principal and postgres answers instead" 401 sql
saw "READER: transport=ssh, answered by postgres-container" "the 401 downgrade is NAMED in the verdict field, not only in the body"
saw "the /v1/deliveries route answered HTTP 401 to the WORKER principal" "the field says WHY the reader changed"
saw "read by postgres-container" "the green sentence carries the downgraded reader, so a green cannot hide which reader produced it"
not_saw "answered by route" "the transport did not decide the answer — the two runs report DIFFERENT readers"

section "(k) the workflow's own shape"
if grep -q "cron:" "$WF"; then ok "the workflow carries a cron"; else bad "the workflow has no cron"; fi
if grep -q "workflow_dispatch:" "$WF"; then ok "the workflow carries workflow_dispatch"; else bad "no workflow_dispatch"; fi
if grep -q "if: github.event_name != 'pull_request'" "$WF"; then ok "the product step is fenced off pull_request heads"; else bad "the product job is not fenced off pull_request"; fi
# The KEY, not the word: this file's own prose explains why continue-on-error is
# absent, and a bare grep would red on the explanation.
if grep -qE '^[[:space:]]*continue-on-error:' "$WF"; then bad "continue-on-error is present — this scream can be laundered to success"; else ok "no continue-on-error key anywhere"; fi
if grep -q "file-ci-failure-issue.sh" "$WF"; then ok "it screams through scripts/file-ci-failure-issue.sh"; else bad "nothing files an issue when this reds"; fi

# A scream that cannot be HEARD is the defect this section was already one
# assertion short of catching. The first production run, 31311406793, reached
# the scream step and died with "GITHUB_TOKEN is empty" — the step set GH_TOKEN,
# and file-ci-failure-issue.sh reads GITHUB_TOKEN. Every other assertion above
# was green.
#
# DERIVED, NOT QUOTED: the variable name is read out of the scream script itself,
# so renaming it there reds here instead of rotting into a stale literal. If the
# derivation stops working, that is a FAILURE — a pin that silently becomes an
# empty string would pass `grep ""` against anything.
SCREAM="$REPO_ROOT/scripts/file-ci-failure-issue.sh"
if [ -f "$SCREAM" ]; then
  SCREAM_TOKEN_VAR="$(sed -n 's/^token="\${\([A-Z_][A-Z_0-9]*\):-}".*/\1/p' "$SCREAM" | head -1)"
  if [ -n "$SCREAM_TOKEN_VAR" ]; then
    ok "the scream's token variable is derivable from its own source ($SCREAM_TOKEN_VAR)"
    if grep -qE "^[[:space:]]*${SCREAM_TOKEN_VAR}:[[:space:]]*\\\$\{\{" "$WF"; then
      ok "the scream step sets $SCREAM_TOKEN_VAR — the alert can actually be delivered"
    else
      bad "$WF never sets $SCREAM_TOKEN_VAR, so file-ci-failure-issue.sh will die 'empty' and the failure goes UNREPORTED"
    fi
  else
    bad "could not derive the token variable from $SCREAM — this assertion would be vacuous, so it fails instead"
  fi
else
  bad "missing $SCREAM — the scream step invokes a script that is not there"
fi
for n in 0 1 2 3 4; do
  if grep -q "^            $n)" "$WF"; then ok "the case arm for rc $n exists"; else bad "rc $n has no case arm of its own"; fi
done
if [ -f "$SPEC" ] && grep -q "crown-reconcile" "$SPEC"; then
  bad "crown-reconcile appears in .github/required-checks.json — it must NOT be a required context"
else
  ok "crown-reconcile is not in the required-check spec"
fi

# THE SILENCE STOPS EXITING 0. The rc=2 arm's own text has always said it is not
# a green; run 31321844876 exited rc=2 and published a run conclusion of SUCCESS.
RC2_ARM="$(grep '^            2)' "$WF" | head -1)"
if [ -z "$RC2_ARM" ]; then
  bad "there is no rc=2 case arm to check — this assertion would be vacuous, so it fails instead"
elif printf '%s' "$RC2_ARM" | grep -q 'exit 0'; then
  bad "the rc=2 arm still exits 0 — a SILENCE is being laundered into a green run conclusion"
else
  ok "the rc=2 SILENCE arm exits non-zero"
fi

# …AND THE SPLIT DOES NOT PUT THE SILENCE BACK. rc 4 is the benign in-flight
# deferral and MUST warn rather than page; rc 2 stays a page. Asserting both on
# the same file is what stops the split from sliding back into laundering — a
# future edit that maps 2 to a warning, or 4 to an error, reds here.
RC4_ARM="$(grep '^            4)' "$WF" | head -1)"
if [ -z "$RC4_ARM" ]; then
  bad "there is no rc=4 case arm — the NOT-YET-DUE deferral would fall to the catch-all and page, which is the false alarm being cured"
else
  if printf '%s' "$RC4_ARM" | grep -q 'exit 0'; then
    ok "the rc=4 NOT-YET-DUE arm exits 0 — a benign in-flight grace does not page"
  else
    bad "the rc=4 arm does not exit 0 — the deferral still pages, and five of the last six rc=2 firings were exactly this"
  fi
  if printf '%s' "$RC4_ARM" | grep -q '::warning::'; then
    ok "and it is a ::warning — the deferral is still SAID, not swallowed into a clean green"
  else
    bad "the rc=4 arm is silent or an error; a deferral must be announced as a warning"
  fi
  if printf '%s' "$RC4_ARM" | grep -q '::error::'; then
    bad "the rc=4 arm is an ::error — that is the page this split exists to stop"
  else
    ok "the rc=4 arm does not raise an error annotation"
  fi
fi
# The script and the workflow must agree on what 4 MEANS: an rc the yml handles
# and the script never returns is decoration, and the reverse is a page.
if grep -q '^#             4 = NOT YET DUE' "$CR"; then
  ok "crown-reconcile.sh documents rc 4 in its own EXIT CODES block"
else
  bad "$CR never defines rc 4, but $WF has a case arm for it — the workflow is handling a code the script does not produce"
fi
if grep -q '^  exit 4$' "$CR"; then
  ok "and it actually exits 4 somewhere"
else
  bad "$CR documents rc 4 and never exits with it"
fi
# The deferral must not be able to become UNREADABLE again by accident: defer()
# is the only writer of the deferral counter, exactly as reason() is of UNREADABLE.
if [ "$(grep -c '^  DEFERRED=\$((DEFERRED + 1))$' "$CR")" = "1" ]; then
  ok "the deferral counter is incremented in exactly one place — inside defer()"
else
  bad "DEFERRED is incremented outside defer() — that deferral would print as unnamed"
  grep -n 'DEFERRED=' "$CR" >&2
fi
if grep -q 'defer "SERVING GRACE' "$CR"; then
  ok "the serving grace goes through defer(), not reason() — it is a deferral, not a silence"
else
  bad "the serving grace no longer calls defer() — if it went back to reason() the benign grace pages again"
fi

# An INPUT that can break this harness must be able to TRIGGER it.
# crown-reconcile.test.sh reads .github/required-checks.json above, and that file
# was in no crown-reconcile trigger path at all.
if grep -q '^      - "\.github/required-checks\.json"' "$WF"; then
  ok "the spec file this harness reads is in the workflow's pull_request paths"
else
  bad "$WF does not trigger on .github/required-checks.json, which this harness READS — an input that can break the harness cannot fire it"
fi

# …and it must fire ONCE. crown-reconcile.yml carries its own paths-filtered
# pull_request harness job (proven live by run 31320596893), so adding the same
# harness to shell-harnesses.yml would double-run it.
HARNESSES="$REPO_ROOT/.github/workflows/shell-harnesses.yml"
if [ ! -f "$HARNESSES" ]; then
  bad "missing $HARNESSES — this assertion would be vacuous, so it fails instead"
elif grep -q "crown-reconcile" "$HARNESSES"; then
  bad "crown-reconcile appears in shell-harnesses.yml as well as in its own workflow — the harness would run TWICE"
else
  ok "crown-reconcile rides its own harness job only — it is not double-run by shell-harnesses.yml"
fi

# The PAT env line exists so a human can mint the secret without touching this
# file again, and the step UNSETS an empty one so an unminted secret cannot be
# handed to the script as the configuration fault it now (correctly) refuses.
if grep -q 'CROWN_API_TOKEN: \${{ secrets.CROWN_API_TOKEN }}' "$WF"; then
  ok "the reconcile step carries the CROWN_API_TOKEN env line"
else
  bad "$WF never passes CROWN_API_TOKEN — the PAT reader cannot be armed without editing this file again"
fi
if grep -q 'unset CROWN_API_TOKEN' "$WF"; then
  ok "an empty CROWN_API_TOKEN is unset before the script runs, so an UNMINTED secret cannot fault the working SSH reader"
else
  bad "$WF hands CROWN_API_TOKEN straight to the script; an unminted secret renders as the EMPTY string, which is now rc 3 — this would break the CI reader"
fi

# The re-ask list must be pointed somewhere that survives the VM, and that
# somewhere must not be a temp directory.
if grep -q 'CROWN_STATE_FILE:' "$WF"; then
  ok "the workflow sets CROWN_STATE_FILE — the re-ask list is no longer written to a default nobody carries"
else
  bad "$WF never sets CROWN_STATE_FILE, so the re-ask list defaults under \$TMPDIR on a VM that is destroyed — GRACED-UNRECORDED cannot fire"
fi
if grep -q '/var/lib/crown-reconcile' "$WF"; then
  ok "the list is carried to /var/lib/crown-reconcile on the control plane"
else
  bad "$WF names no persistent home for the re-ask list"
fi
# The KEY, not the word: the file's own prose explains why actions/cache was
# REFUSED, and a bare grep would red on the explanation.
if grep -qE '^[[:space:]]*uses:[[:space:]]*actions/cache' "$WF"; then
  bad "the re-ask list rides actions/cache — a silent eviction is indistinguishable from an empty list, which is the defect being cured"
else
  ok "the re-ask list does NOT ride actions/cache"
fi
for phrase in "Re-ask list — fetch from the control plane" "Re-ask list — write back to the control plane" "if: always()"; do
  if grep -qF "$phrase" "$WF"; then ok "the workflow carries: $phrase"; else bad "the workflow is missing '$phrase' — the list cannot make a round trip"; fi
done

# THE WRITE-BACK IS ATOMIC. `cat > graced.txt` truncates the remote file before
# the first byte arrives, so a stream that dies mid-write leaves a SHORT list —
# indistinguishable from one that legitimately drained, which forgives every
# accusation past the cut. Both halves are asserted: the temp file AND the move.
if grep -qF "cat > /var/lib/crown-reconcile/graced.txt'" "$WF"; then
  bad "the write-back still redirects straight onto graced.txt — a truncating write can leave a short list that reads as a drained one"
else
  ok "the write-back does not truncate graced.txt in place"
fi
if grep -qF "mv -f /var/lib/crown-reconcile/graced.txt.tmp /var/lib/crown-reconcile/graced.txt" "$WF"; then
  ok "the write-back is write-then-move — the next run reads the whole old list or the whole new one"
else
  bad "$WF never renames a temp file over graced.txt, so the write is not atomic"
fi

# THE FIRST-RUN STATEMENT IS THE CALLER'S, AND ONLY A CALLER THAT LOOKED MAY
# MAKE IT. The remote command must decide it, the reconcile step must carry it,
# and a fetch that FAILED must not.
if grep -qF "CROWN_STATE_FIRST_RUN: \${{ steps.reask.outputs.first_run }}" "$WF"; then
  ok "the reconcile step carries the fetch step's first-run finding, rather than hard-coding a tolerance"
else
  bad "$WF does not pass a first-run statement derived from the fetch — either the first run pages over a file that never existed, or the tolerance is asserted blind"
fi
if grep -qF "echo CR_LIST=FIRST-RUN" "$WF" && grep -qF "echo CR_LIST=PRESENT" "$WF"; then
  ok "the remote command distinguishes a store that has never held a list from one that has"
else
  bad "$WF never asks the control plane whether the list exists — an absence cannot be classified from the runner alone"
fi
if grep -qF 'first_run=1' "$WF"; then
  ok "the first-run claim is the literal 1 the script requires"
else
  bad "$WF never emits first_run=1, so the script will read the claim as unmade"
fi

section "(q) the re-ask boundary is STATED in the script, not only implemented"
# A deferral whose retirement rule lives only in code is a rule the next reader
# has to reverse-engineer from a while-loop.
for phrase in "CLEAN RETIREMENT" "DIRTY RETIREMENT" "RE-ASK LIST" "charged against FIRST-SEEN"; do
  if grep -qF "$phrase" "$CR"; then ok "the header states: $phrase"; else bad "the header never states '$phrase' — the boundary is undocumented"; fi
done
# Every UNREADABLE=1 must go through reason(), or a silence can go unnamed again.
if [ "$(grep -c '^  UNREADABLE=1$' "$CR")" = "1" ]; then
  ok "UNREADABLE is set in exactly one place — inside reason(), so no silence can be anonymous"
else
  bad "UNREADABLE=1 appears outside reason() — that site's silence would print as unnamed"
  grep -n 'UNREADABLE=1' "$CR" >&2
fi

section "(l) no jq call takes a payload as an argv word (charter D486)"
if grep -n 'argjson' "$CR" | grep -vqE 'argjson (cut|wide) '; then
  bad "an --argjson carries something other than the two window scalars"
  grep -n 'argjson' "$CR" >&2
else
  ok "--argjson carries only the two window epochs; every list travels by file"
fi

echo
echo "crown-reconcile.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
