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
#   (w) THE TORN READ: the run list and the crown are sampled MINUTES
#       apart, and a row written inside that gap was called WRONG.
#       Each arm forces the two sides apart on purpose and watches the
#       verdict move — and every exclusion is held down by a negative
#       arm proving a REAL orphan still reds with the gap present:
#         (w1) run-keyed, CLOCK-FREE: one field — the run's status on
#              the page — flips cancelled to in_progress       → 1, then 0
#         (w2) time-keyed: the SAME fixture, red when the script does
#              not know the two sides were sampled apart and green
#              when it does — the gap is the only difference   → 1, then 0
#         (w3) a row written BEFORE the watermark is still WRONG → exit 1
#         (w4) a ghost run id BELOW the page maximum is still WRONG,
#              so being recent is never on its own an excuse     → exit 1
#         (w5) a row with NO run id: excluded after the watermark,
#              still WRONG before it                             → 0, then 1
#         (w6) a TRUNCATED page cannot manufacture a ghost: the same
#              row is rc 2 UNJUDGEABLE on a filled page and rc 1
#              WRONG on a page that saw the whole window         → 2, then 1
#   (d) WINDOW EMPTY: nothing to compare is never a green            → exit 2
#   (u) QUIET WINDOW: an empty window on a VERIFIED crown — serving
#       sha recorded, re-ask list PRESENT-EMPTY, zero in-window rows —
#       is a NAMED deferral (rc 0, own ::warning), not a 6-hourly
#       page; each condition is pinned by the ONE fixture that fails
#       it alone, and rows-exist-but-no-runs STAYS rc 2          → 0, then 2×4
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
#   (r) …unless a deploy for that EXACT sha is still running, which is
#       the disagreement's own explanation                             → exit 4
#       and unless it is inside the measured jitter epsilon            → exit 4
#       with both non-vacuity halves held down: the same future stamp
#       with nothing in flight still accuses, and a run in flight for
#       ANOTHER sha still accuses                                  → 1, 1
#   (h) a docs-only run delivered nothing and MUST NOT be counted    → exit 0
#       (this is the false-positive that would drown the real reds)
#   (i) a CARRIED row naming a sha with no run of its own is correct → exit 0
#   (x) AN UNREADABLE ALIBI IS NOT AN ABSENT ONE: the run a row names
#       could not have its job list read, so the row is DEFERRED and
#       NAMED rather than accused — with both non-vacuity halves held
#       down (the same run READ and delivering nothing is still WRONG,
#       and READ and delivering is still reconciled)      → 1, 0, then 2
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
#       names `route` when the route answers 200, and when the route
#       answers 401 to the WORKER principal it names the REFUSAL — the
#       postgres detour is deleted, so a 401 is a VERDICT (#14979) and a
#       body claiming any substitute reader is refused           → 0, 2, 2
#   (o2) THE REMOTE READER ITSELF, extracted from the script and run
#       against docker/curl in effigy: 401 and 403 emit
#       CR_ERROR=http_<code>_worker_principal plus a CR_DETAIL naming
#       the route, WORKER_TOKEN and #14979, `docker` is NEVER asked for
#       the postgres container and `psql` is never run; a 500 still
#       emits the plain CR_ERROR=http_500 arm
#   (m) PREDATES-WRITER: a delivering run created before the
#       record-delivery job existed is its own printed class, with the
#       birth instant beside it — never a BEHIND                      → exit 0
#       and a window with NOTHING BUT such runs has no denominator     → exit 2
#
#   (y) CANCELLED IS A CLASS, AND IT POINTS BOTH WAYS: one fixture holds
#       a cancelled run that delivered nothing (a superseded push) and a
#       cancelled run that DELIVERED (its recorder died with the cancel);
#       both are named, the existing totals do not move, a window with
#       nothing cancelled prints the same clause with zeroes, and a
#       MUTATED SCRIPT with the split dropped loses both names   → 0, 0, 0
#   (z) THE RUN LISTING PAGES TO THE WINDOW START: 101 runs inside the
#       window are a COUNT, not a floor — the same 101 rows from a
#       listing that stopped SHORT still print `N+` with the residual,
#       and a MUTATED SCRIPT that keys the floor on row count again
#       calls the WHOLE listing a floor                          → 0, 0, 0
#
#   bash scripts/crown-reconcile.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# THE SCRIPT UNDER TEST, overridable ONLY so a red-before can be RUN rather than
# asserted. `CROWN_RECONCILE_SH=<a pre-fix copy> bash scripts/crown-reconcile.test.sh`
# drives these same cases at an older script and is how the 401-is-a-verdict arms
# below were proven to RED before the fix. CI sets nothing and gets the repo's own.
CR="${CROWN_RECONCILE_SH:-$REPO_ROOT/scripts/crown-reconcile.sh}"
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

# A fixture that is EMPTY or truncated reds as an unnamed exit 2, which is
# indistinguishable from a real failure — one verification run on a full disk
# reported ~34 failures across nine unrelated sections that reproduced as 5 on a
# healthy host. Every write that can be checked for nothing is checked here.
fixture_ok() { # <path>
  [ -s "$1" ] && return 0
  echo "FIXTURE WRITE FAILED (out of disk?): $1 is empty — every verdict below would be an unnamed exit 2, not a real red" >&2
  exit 2
}

# runs_json hardcodes conclusion=success / status=completed, so it cannot express
# the one shape this whole arm is about: a deploy that is STILL RUNNING. This
# appends exactly that row — status in_progress, conclusion null — to an
# otherwise ordinary run page. The in-flight run is deliberately NOT a success,
# so a harness that stopped filtering conclusion would show up as a moved count.
with_inflight() { # <name> <in-flight-sha> <in-flight-created> <sha:created>...
  local name="$1" isha="$2" icreated="$3"; shift 3
  local base out
  base="$(runs_json "$name-completed" "$@")"
  out="$TMP/$name.json"
  jq --arg sha "$isha" --arg created "$icreated" \
    '.workflow_runs += [{id: 9001, head_sha: $sha, conclusion: null, status: "in_progress", created_at: $created}]' \
    "$base" > "$out" 2>/dev/null
  fixture_ok "$out"
  echo "$out"
}

# runs_json fixes status=completed / conclusion=success for every row, which
# cannot express the shape the torn read is made of: a run that was mid-flight,
# or had not been created at all, WHEN THE RUN LIST WAS SAMPLED. This appends
# one run with every field stated, so a probe can mutate exactly one of them.
runs_add() { # <name> <base-json> <id> <sha> <status> <conclusion|null> <created>
  local out="$TMP/$1.json"
  jq --argjson id "$3" --arg sha "$4" --arg st "$5" --arg cc "$6" --arg cr "$7" \
    '.workflow_runs += [{id: $id, head_sha: $sha, status: $st,
                         conclusion: (if $cc == "null" then null else $cc end),
                         created_at: $cr}]' "$2" > "$out" 2>/dev/null
  fixture_ok "$out"
  echo "$out"
}

# A listing that stopped SHORT of the window start, which is what the live
# reconciler gets when the pager hits its cap on a very busy day. Two real
# delivering runs plus enough in-flight filler to fill a page, with ids offset so
# a row can name a run BELOW the listing minimum: the shape a run that fell off
# the listing produces.
#
# `"truncated": true` is the fixture-only handle fetch_runs reads for this. It
# has to be STATED now: a fixture is one file and cannot page, and since the
# listing pages to the window start, row count alone no longer means truncation —
# that is precisely the (b2) arm below, where the same 100+ rows WITHOUT this key
# are an exact count. Dropping it here would make every arm below vacuous.
runs_filled() { # <name> <first-id> <shaA:created> <shaB:created> <filler-sha> <filler-created>
  local out="$TMP/$1.json" base="$2" fsha="$5" fcreated="$6"
  local a="${3%%:*}" acr="${3#*:}" b="${4%%:*}" bcr="${4#*:}"
  {
    printf '{"truncated":true,"workflow_runs":['
    printf '{"id":%d,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"}' "$base" "$a" "$acr"
    printf ',{"id":%d,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"}' "$((base + 1))" "$b" "$bcr"
    local i=2
    while [ "$i" -lt 100 ]; do
      printf ',{"id":%d,"head_sha":"%s","conclusion":null,"status":"in_progress","created_at":"%s"}' \
        "$((base + i))" "$fsha" "$fcreated"
      i=$((i + 1))
    done
    printf ']}'
  } > "$out"
  fixture_ok "$out"
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

# jobs_json fixes BOTH legs to the same conclusion, so it cannot express the one
# shape the live crown-reconcile red is made of: a deploy whose INSTANCE leg
# concluded success while its CONTROL-PLANE leg failed (the owner's CP box). That
# run's overall conclusion is `failure`, and it DELIVERED. This states each leg
# separately so a probe can move one of them alone.
jobs_legs() { # <name> <run-id:control-plane-conclusion:instance-conclusion>...
  local out="$TMP/$1.json"; shift
  local first=1
  {
    printf '{'
    for spec in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      local id="${spec%%:*}" rest="${spec#*:}"
      printf '"%s":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"%s"},{"name":"instance","conclusion":"%s"}]' \
        "$id" "${rest%%:*}" "${rest#*:}"
    done
    printf '}'
  } > "$out"
  fixture_ok "$out"
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
# A MUTATION OF THE SCRIPT ITSELF, not of a fixture. Most arms here move one
# field of a fixture and watch the verdict follow; two arms below have to move
# the SCRIPT instead, because what they guard is a sentence the script prints and
# a condition it tests, and no fixture can delete either. CR_ALT points run_cr at
# a mutated copy for exactly one probe and is cleared straight after.
CR_ALT=""
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
    bash "${CR_ALT:-$CR}" --now "$NOW" "$@" 2>&1)"
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

section "(w) THE TORN READ — the two sides are sampled MINUTES apart"
# THE DEFECT, IN ONE SENTENCE. fetch_runs takes the run page at T0; the jobs API
# is then asked once per examined run (65 runs on the live window, so minutes);
# the crown page is read at T1. A row written between T0 and T1 names a run that
# was NOT YET TERMINAL at T0, so `.conclusion == "success"` could not have
# matched it, so the row had no alibi it could possibly have had — and the
# verdict called it WRONG. Live: run 32726853411 printed `behind=0/65` (nothing
# was lost) beside `wrong=2/100`, both rows the SAME sha, delivered by runs
# 32726835915 and 32726853417 — ids ADJACENT to the reconciler's own.
#
# Every probe below FORCES that gap rather than hoping for it, which is the
# whole point: a "1 of 100 WRONG" reproduced without forcing the two sides apart
# does not distinguish a torn read from a real miss.
TEAR_T0="2026-08-09T11:00:00Z"   # the instant the run list was sampled
TEAR_T1="2026-08-09T11:30:00Z"   # the row lands 30 minutes later, still inside the window
# NOW is 12:00 — the crown read. So the fixtures below are literally a NEWER
# crown compared against an OLDER run list.

section "(w0) THE LIVE FAILURE, REPLAYED FROM THE ACTIONS API"
# Not a shape LIKE the live one — the live one, with the real ids, the real
# shas and the real instants, every value read back out of the Actions API on
# 2026-08-24 and pasted here. Run 32726853411 (crown-reconcile, push, main
# 4d35c5ab08) printed:
#
#     WRONG: 2 of 100 crown row(s) examined (2.0%) ...
#         4d35c5ab08... delivered by run 32726835915, which is not a delivering run
#         4d35c5ab08... delivered by run 32726853417, which is not a delivering run
#     VERDICT: NOT reconciled — behind=0/65 ... wrong=2/100 ...
#
# THE TIMELINE, verbatim from the API, is the whole diagnosis:
#
#     12:23:24Z  deploy 32726835915 STARTS   (13s before the reconciler)
#     12:23:37Z  deploy 32726853417 STARTS   (the SAME second as the reconciler)
#     12:23:37Z  crown-reconcile 32726853411 STARTS, and samples its run list
#                — BOTH deploy runs are in_progress, so NEITHER can match
#                  `.conclusion == "success"`
#     12:29:38Z  deploy 32726835915 completes, success
#     12:31:18Z  deploy 32726853417 completes, success
#     12:32:59Z  the reconciler concludes, having read the crown ~9 MINUTES
#                after it froze the run side, and accuses both their rows
#
# `behind=0/65` is the proof nothing was lost: not one delivering run was
# missing a row. Both accused runs concluded SUCCESS. Both rows are correct.
# The COMPARISON was torn, and the run-keyed arm below is clock-free, so this
# replay never touches a timestamp to clear it.
LIVE_NOW="2026-08-24T12:32:59Z"          # when the verdict concluded
LIVE_SHA="4d35c5ab08ebf6f749baad913c0de4058afa5a4f"
LIVE_SHA2="c47ced9291264e75149a7adbda46ce1532d947c3"
LIVE_PRIOR="f74939277c283668f461a92989820bcecb05733b"
RUNS_LIVE="$TMP/runs-live.json"
printf '%s' '{"workflow_runs":[
  {"id":32726853417,"head_sha":"'"$LIVE_SHA"'","status":"in_progress","conclusion":null,"created_at":"2026-08-24T12:23:37Z"},
  {"id":32726835915,"head_sha":"'"$LIVE_SHA2"'","status":"in_progress","conclusion":null,"created_at":"2026-08-24T12:23:24Z"},
  {"id":32723174205,"head_sha":"'"$LIVE_PRIOR"'","status":"completed","conclusion":"success","created_at":"2026-08-24T11:41:52Z"}]}' \
  > "$RUNS_LIVE"
fixture_ok "$RUNS_LIVE"
# EVERY run on this page states its legs, including the two that were in flight.
# OMITTING a run from the jobs fixture used to be how "this run delivered
# nothing" was expressed — but an omitted entry is exactly what a jobs-API call
# that DID NOT ANSWER looks like to the script, and those are opposite claims
# (task-a8bb36d8622be137). The terminal arm below flips both runs to
# completed/cancelled and needs them to be READ and non-delivering, not silent.
JOBS_LIVE="$(jobs_json jobs-live "32723174205:success" "32726853417:cancelled" "32726835915:cancelled")"
# The rows the two in-flight deploys wrote. BOTH name $LIVE_SHA — the sha the
# BOX WAS SERVING — which is the carried=false shape #11203 established, so the
# head-sha fallback could never have alibied them either.
CROWN_LIVE="$(crown_json crown-live \
  "$(row "$LIVE_PRIOR" cp false "2026-08-24T11:51:00Z" 32723174205)" \
  "$(row "$LIVE_SHA" cp false "2026-08-24T12:29:38Z" 32726835915)" \
  "$(row "$LIVE_SHA" instance false "2026-08-24T12:31:18Z" 32726853417)")"
HEALTH_LIVE="$(health_json health-live "$LIVE_PRIOR" "2026-08-24T11:51:00Z")"

live_probe() { # <expected-rc> <label> [extra args…]
  local want="$1" label="$2"; shift 2
  local out rc
  CR_N=$((CR_N + 1))
  seed_state "$TMP/state-live-$CR_N.txt"
  out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
    CROWN_STATE_FILE="$TMP/state-live-$CR_N.txt" \
    bash "$CR" --now "$LIVE_NOW" \
      --runs-fixture "$RUNS_LIVE" --jobs-fixture "$JOBS_LIVE" \
      --crown-fixture "$CROWN_LIVE" --health-fixture "$HEALTH_LIVE" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last.out"
  if [ "$rc" = "$want" ]; then ok "$label → exit $rc"; else
    bad "$label → exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  fi
}

live_probe 0 "the live tear, replayed against the repaired comparison"
saw "WRITTEN-IN-FLIGHT: 2 of 3" "both accused rows are excluded, and the count is the live wrong=2"
saw "run 32726835915" "it names the first run the live verdict accused"
saw "run 32726853417" "it names the second run the live verdict accused"
saw "no clock was consulted" "the live shape is cleared CLOCK-FREE — the page said both runs were running"
not_saw "WRONG:" "the reconciler no longer accuses its own concurrent writers"
not_saw "BEHIND:" "behind stays 0, exactly as the live run measured it"

# NON-VACUITY. The replay must be a DIFFERENCE, not a fixture that was always
# going to pass: flip ONLY the two runs' status to completed/cancelled — every
# other byte identical — and the live WRONG=2 comes straight back.
RUNS_LIVE_TERM="$TMP/runs-live-terminal.json"
jq '.workflow_runs |= map(if .status == "in_progress"
      then .status = "completed" | .conclusion = "cancelled" else . end)' \
  "$RUNS_LIVE" > "$RUNS_LIVE_TERM" 2>/dev/null
fixture_ok "$RUNS_LIVE_TERM"
CR_N=$((CR_N + 1))
seed_state "$TMP/state-live-term.txt"
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
  CROWN_STATE_FILE="$TMP/state-live-term.txt" \
  bash "$CR" --now "$LIVE_NOW" --runs-fixture "$RUNS_LIVE_TERM" --jobs-fixture "$JOBS_LIVE" \
    --crown-fixture "$CROWN_LIVE" --health-fixture "$HEALTH_LIVE" 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "1" ]; then
  ok "the SAME live fixture with both runs TERMINAL and non-delivering → exit 1"
else
  bad "the terminal-run arm of the live replay → exit $rc, wanted 1"
  printf '%s\n' "$out" | sed 's/^/       | /' >&2
fi
saw "WRONG: 2 of 3" "the live accusation returns the instant the runs are terminal — the replay is a difference, not a default"

section "(w1) run-keyed and CLOCK-FREE — one field moves the verdict"
# The strongest form available: the run IS on the page, its row IS in the crown,
# and the ONLY difference between the red and the green is the run's `status` at
# the moment the page was sampled. No clock, no flag, no window.
RUNS_W1_DEAD="$(runs_add runs-w1-dead "$RUNS_BASE" 3 "$SHA_C" completed cancelled "$IN2")"
RUNS_W1_LIVE="$(runs_add runs-w1-live "$RUNS_BASE" 3 "$SHA_C" in_progress null "$IN2")"
CROWN_W1="$(crown_json crown-w1 \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$TEAR_T1" 3)")"
# Run 3's legs are STATED as cancelled rather than left out of the fixture: an
# absent entry is a jobs read that did not answer, and this arm is about a run
# that WAS read and delivered nothing (task-a8bb36d8622be137).
JOBS_W1="$(jobs_json jobs-w1 "1:success" "2:success" "3:cancelled")"
run_cr 1 "run 3 is TERMINAL and cancelled — its row has a real orphan's shape" \
  --runs-fixture "$RUNS_W1_DEAD" --jobs-fixture "$JOBS_W1" --crown-fixture "$CROWN_W1" --health-fixture "$HEALTH_BASE"
saw "WRONG: 1 of 4" "a row whose run finished WITHOUT delivering is still accused"
not_saw "WRITTEN-IN-FLIGHT: " "a terminal run is never excused as in-flight"

run_cr 0 "the SAME row, and run 3 was still in_progress when the page was sampled" \
  --runs-fixture "$RUNS_W1_LIVE" --jobs-fixture "$JOBS_W1" --crown-fixture "$CROWN_W1" --health-fixture "$HEALTH_BASE"
saw "WRITTEN-IN-FLIGHT: 1 of 4" "the tear is EXCLUDED and printed with its own count, not graced into silence"
saw "no clock was consulted" "the run-keyed arm says out loud that it read the page, not a timestamp"
not_saw "WRONG:" "the reconciler stops accusing its own concurrent writer"
saw "written-in-flight=1/4" "the green carries the exclusion as a verdict field, so it cannot hide inside RECONCILED"

section "(w1b) THE EXCLUSION IS CAPPED — a HUNG run stops being an alibi"
# Arm (i) defers for as long as GitHub reports the run non-terminal, which is
# the unbounded shape dr-w34 already caught on the SERVING axis. The cap is the
# SAME measured constant, read back out of the script rather than re-typed here,
# so a later widening reds this probe instead of silently buying more amnesty.
CAP="$(sed -n 's/^SERVING_INFLIGHT_CAP_SECONDS=\([0-9]*\).*/\1/p' "$CR" | head -1)"
case "${CAP:-}" in
  ''|*[!0-9]*) bad "SERVING_INFLIGHT_CAP_SECONDS could not be read back out of the script — the probe below would be vacuous" ;;
  *) ok "the in-flight cap is derived from the script's own constant (${CAP}s), not re-typed" ;;
esac
# The row is 4h old — comfortably past the 3h cap — and its run has been
# in_progress that entire time. IN1 is 2h20m before NOW, so a row stamped at the
# window's own start (12h before NOW) is unambiguously expired.
HUNG_AT="2026-08-09T04:00:00Z"
RUNS_W1B="$(runs_add runs-w1b "$RUNS_BASE" 3 "$SHA_C" in_progress null "$HUNG_AT")"
CROWN_W1B="$(crown_json crown-w1b \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$HUNG_AT" 3)")"
run_cr 1 "run 3 has been in_progress for the whole 8h this row has existed" \
  --runs-fixture "$RUNS_W1B" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W1B" --health-fixture "$HEALTH_BASE"
saw "WRITTEN-IN-FLIGHT-EXPIRED: 1 crown row(s)" "a hung run is named and its deferral is ended, not renewed"
saw "WRONG: 1 of 4" "and the row is ACCUSED — the exclusion cannot be held open forever"
not_saw "WRITTEN-IN-FLIGHT: " "an expired row is never also reported as still deferred"

section "(w2) time-keyed — the SAME fixture, red without the gap and green with it"
# The run is not on the page AT ALL: id 9001 is above every id there, which is a
# statement about EXISTENCE, because Actions allocates run ids in creation order.
# `--runlist-at` is the harness telling the script when the run list was taken.
# WITHOUT it the watermark is `now`, nothing can be newer than now, and the
# script behaves exactly as it did before this fix — that red IS the pre-fix
# world, reproduced on the same bytes.
CROWN_W2="$(crown_json crown-w2 \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$TEAR_T1" 9001)")"
run_cr 1 "the gap is WIDE and the script is not told about it — the torn read, reproduced" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W2" --health-fixture "$HEALTH_BASE"
saw "run 9001, which is not a delivering run" "the pre-fix verdict names a run that is fine and a row that is fine"

run_cr 0 "the gap is STILL WIDE, and the script now knows the run list was sampled at $TEAR_T0" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W2" --health-fixture "$HEALTH_BASE" \
  --runlist-at "$TEAR_T0"
saw "WRITTEN-IN-FLIGHT: 1 of 4" "a consistent comparison excludes the row instead of accusing it"
saw "it did not exist when the run list was taken" "the time-keyed arm states BOTH halves of its case"
not_saw "WRONG:" "no tolerance was widened — the two sides were made consistent"

section "(w3) NEGATIVE ARM — a row written BEFORE the watermark is still WRONG"
# The same ghost run id, the same declared gap. Only the row's own write instant
# moves, from inside the gap to before it. A fix that traded a false positive for
# a false negative would go green here.
CROWN_W3="$(crown_json crown-w3 \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN1" 9001)")"
run_cr 1 "a genuinely orphaned row, written well before the run list was sampled" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W3" --health-fixture "$HEALTH_BASE" \
  --runlist-at "$TEAR_T0"
saw "WRONG: 1 of 4" "the instrument still loses on a real miss with the gap fully declared"
not_saw "WRITTEN-IN-FLIGHT: " "an old row is never excused by a watermark that postdates it"

section "(w4) NEGATIVE ARM — being RECENT is not on its own an excuse"
# The row is written inside the gap, but its run id (9) sits BELOW the page
# maximum (50), so the page could have carried that run and did not. Time alone
# must never excuse a row; the run-existence half is required and is missing.
RUNS_W4="$(runs_add runs-w4 "$RUNS_BASE" 50 "$SHA_D" in_progress null "$IN2")"
CROWN_W4="$(crown_json crown-w4 \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$TEAR_T1" 9)")"
run_cr 1 "a fresh row naming run 9, which the page's id range 1..50 says should have been there" \
  --runs-fixture "$RUNS_W4" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W4" --health-fixture "$HEALTH_BASE" \
  --runlist-at "$TEAR_T0"
saw "WRONG: 1 of 4" "recency without an existence signal is refused — the clock never excuses alone"

section "(w5) a row with NO run id — excluded after the watermark, WRONG before it"
# The legacy shape. It states no run, so the head-sha fallback judges it; but a
# row written after the run list was sampled has no alibi source either way, and
# the pair below is what keeps that exclusion from becoming a blanket one.
CROWN_W5_NEW="$(crown_json crown-w5-new \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$TEAR_T1" omit)")"
run_cr 0 "no run id, written inside the gap" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W5_NEW" --health-fixture "$HEALTH_BASE" \
  --runlist-at "$TEAR_T0"
saw "WRITTEN-IN-FLIGHT: 1 of 4" "a legacy row written inside the gap is excluded, not accused"

CROWN_W5_OLD="$(crown_json crown-w5-old \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN1" omit)")"
run_cr 1 "the same legacy row, written before the gap" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W5_OLD" --health-fixture "$HEALTH_BASE" \
  --runlist-at "$TEAR_T0"
saw "no delivering run id" "the head-sha fallback still loses on an old legacy row"

section "(w6) a TRUNCATED page must not manufacture a ghost"
# The run page is ONE page of 100 and the live reconciler regularly fills it
# without reaching the window start. A row naming a run BELOW the page minimum
# names a run that FELL OFF the page — indistinguishable from one that never
# existed. Accusing it is a false red the truncation itself produced.
RUNS_W6_FULL="$(runs_filled runs-w6-full 500 "$SHA_A:$IN1" "$SHA_B:$IN2" "$SHA_D" "$IN2")"
RUNS_W6_THIN="$(runs_json runs-w6-thin "$SHA_A:$IN1" "$SHA_B:$IN2")"
JOBS_W6="$(jobs_json jobs-w6 "500:success" "501:success" "1:success" "2:success")"
CROWN_W6="$(crown_json crown-w6 \
  "$(row "$SHA_A" cp false "$IN1" 500)" \
  "$(row "$SHA_A" instance false "$IN1" 500)" \
  "$(row "$SHA_B" instance false "$IN2" 501)" \
  "$(row "$SHA_C" cp false "$IN1" 400)")"
run_cr 2 "the page FILLED without reaching the window start, and the row names run 400 below its minimum" \
  --runs-fixture "$RUNS_W6_FULL" --jobs-fixture "$JOBS_W6" --crown-fixture "$CROWN_W6" --health-fixture "$HEALTH_BASE"
saw "TRUNCATED-UNJUDGEABLE: 1 crown row(s)" "a run that fell off a bounded page is named unjudgeable, not accused"
not_saw "WRONG:" "truncation cannot manufacture a ghost"
saw "TRUNCATION RESIDUAL" "the OTHER direction — a BEHIND run that fell off the page — is stated, not left to the plus sign"

# ONE DIFFERENCE: the same crown row, judged against a page that saw the whole
# window. Now run 400 really is absent rather than merely unseen.
CROWN_W6_THIN="$(crown_json crown-w6-thin \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" cp false "$IN1" 400)")"
run_cr 1 "the same row against a page that is NOT truncated" \
  --runs-fixture "$RUNS_W6_THIN" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_W6_THIN" --health-fixture "$HEALTH_BASE"
saw "WRONG: 1 of 4" "an unseen run and an absent run are told apart by whether the page was bounded"

section "(w7) the FIRST SIGHTING'S axis is untouched, and the gap dial is fixtures-only"
# The earlier sighting (task-7aa685d254609ad1) lives on SERVING-UNRECORDED. A fix
# on the torn-read axis must not move it, so the base fixture is re-read for all
# three of the counters that row recorded as clean.
run_cr 0 "the unmutated window, re-read after the watermark landed" $(base_args)
not_saw "SERVING-UNRECORDED" "the serving axis did not move"
not_saw "GRACED-UNRECORDED" "the graced axis did not move"
not_saw "BEHIND:" "the behind axis did not move"
not_saw "WRITTEN-IN-FLIGHT: " "a window with no tear reports no exclusions"
saw "written-in-flight=0/" "and the green states the exclusion count as ZERO rather than omitting the field"
saw "WATERMARK: the run list was sampled at" "every run states when its run side was frozen"

# The gap dial must never be reachable on a live run: an operator who could pin
# the watermark by hand would hold a tolerance, which is exactly what this fix
# refuses to be.
out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY PATH="$SANDBOX_PATH" \
  CROWN_STATE_FILE="$TMP/state-runlist-live.txt" \
  bash "$CR" --now "$NOW" --runlist-at "$TEAR_T0" 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "3" ]; then
  ok "--runlist-at on a live run is a CONFIGURATION fault (exit 3), not a dial"
else
  bad "--runlist-at was accepted on a live run (exit $rc) — the gap would be pinnable by hand"
fi
saw "FIXTURE-ONLY handle" "and it says why it refused"

section "(d) MUTATION: the window is empty — nothing compared is never a green"
RUNS_OLD="$(runs_json runs-old "$SHA_A:$OUT" "$SHA_B:$OUT")"
run_cr 2 "every successful run predates the window" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE"
saw "COULD NOT VERIFY: the population was EMPTY" "an empty population is refused, not rounded to reconciled"
not_saw "RECONCILED:" "it never claims reconciliation over zero runs"

section "(u) QUIET WINDOW: an empty window on a VERIFIED crown is a NAMED deferral"
# The live streak, in fixture form. A quiet repo empties the 24h window BY
# CONSTRUCTION, and the empty-population rc 2 paged SIX consecutive scheduled
# runs 2026-08-15T18:28Z..08-17 (#11217 at 41 comments) — all saying only that
# nothing happened. Quiescence may read green ONLY when all four conditions
# hold, and each condition is pinned below by the ONE fixture that fails it
# alone — so removing any single condition from the guard reds this section.
#
# (u1) all three conditions hold → rc 0, said with its own class name.
# The crown's rows are dated OUTSIDE the window: the serving sha's cp row
# exists (condition 1 — the sha lookup carries no window filter, exactly as in
# production, where the last deploy predates the quiet day), the seeded state
# file is PRESENT-EMPTY (condition 2), and zero rows sit INSIDE the window
# (condition 3).
CROWN_QUIET="$(crown_json crown-quiet \
  "$(row "$SHA_A" cp false "$OUT" 1)" \
  "$(row "$SHA_A" instance false "$OUT" 1)")"
run_cr 0 "empty window, serving sha recorded, list PRESENT-EMPTY, zero in-window rows" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE"
saw "QUIET WINDOW:" "the deferral is SAID, with its own class name"
saw "::warning::QUIET WINDOW" "and it carries its own ::warning annotation — a warning, never a silent green"
saw "quiescence-green does not imply the reverse direction was checked" "the reverse-direction no-alibi refusal prints INSIDE the deferral text"
not_saw "RECONCILED:" "quiescence is a deferral — it never claims reconciliation"
not_saw "COULD NOT VERIFY" "and the named deferral replaces the empty-population page, not merely precedes it"
not_saw "COULD NOT FULLY READ" "the tolerated structural refusal is not reported as a silence on the green path"

# (u2) CONDITION 1 ALONE: the serving check did not run, everything else quiet.
# No health fixture means no serving verification — and an unverified crown
# must not read green off an empty window. This is the ONLY fixture where
# condition 1 is the sole blocker (no reason() fires, no deferral fires), so a
# guard that drops SERVING_VERIFIED greens here and reds the harness.
run_cr 2 "the same empty window with the serving check NOT run is NOT quiescence" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET"
saw "COULD NOT VERIFY: the population was EMPTY" "an unverified crown stays a warning"
not_saw "QUIET WINDOW:" "no quiescence is asserted over a crown nobody verified"

# (u3) CONDITION 2 ALONE: the re-ask list is PRESENT with an entry that retires
# CLEANLY (its cp row exists, outside the window) — so no accusation fires, no
# reason() fires, and the ONLY blocker is that the list was not PRESENT-EMPTY.
# A graced deferral in the same run as an empty window must never be laundered
# by it, and a guard that drops the PRESENT-EMPTY clause greens here.
CROWN_QUIET_D="$(crown_json crown-quiet-d \
  "$(row "$SHA_A" cp false "$OUT" 1)" \
  "$(row "$SHA_A" instance false "$OUT" 1)" \
  "$(row "$SHA_D" cp true "$OUT" 1)")"
STATE_QP="$TMP/state-quiet-present.txt"; seed_state "$STATE_QP"
printf '%s %s\n' "$SHA_D" "$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s) - 600 ))" >> "$STATE_QP"
CR_STATE="$STATE_QP"
run_cr 2 "the same empty window with a PRESENT re-ask list is NOT quiescence" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET_D" --health-fixture "$HEALTH_BASE"
CR_STATE=""
saw "retired from the re-ask list" "the entry retired cleanly — the blocker is the list's state, not an accusation"
saw "COULD NOT VERIFY: the population was EMPTY" "a list that was not affirmatively empty stays a warning"
not_saw "QUIET WINDOW:" "PRESENT is not PRESENT-EMPTY — quiescence needs the affirmative statement that nothing is owed"

# (u4) CONDITION 3 ALONE: rows EXIST inside the window while no run does. A row
# with no run is an accusation source, not quiescence — it STAYS rc 2, and it
# is named. A guard that drops the zero-rows clause greens here.
CROWN_QUIET_ROWS="$(crown_json crown-quiet-rows \
  "$(row "$SHA_A" cp false "$OUT" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)")"
run_cr 2 "rows exist inside the window while NO delivering run does — not quiescence" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET_ROWS" --health-fixture "$HEALTH_BASE"
saw "ROWS WITHOUT RUNS: 1 crown row(s) sit inside the window" "the rows-exist-but-no-runs sub-case is its own named line"
saw "an accusation source, not quiescence" "and it says WHY rows without runs cannot read green"
saw "COULD NOT VERIFY: the population was EMPTY" "it stays the rc-2 warning"
not_saw "QUIET WINDOW:" "a window holding unexplained rows is never quiet"

# (u5) THE FLOOR: any OTHER silence still outranks quiescence. One in-window
# run whose job list cannot be read leaves DELIVERING=0 — but that run MIGHT
# have delivered, so the window is unreadable, not empty. Only the structural
# no-alibi refusal is tolerated on the green path; every other reason() blocks.
RUNS_QUIET_UNREAD="$(runs_json runs-quiet-unread "$SHA_A:$IN1")"
JOBS_ELSEWHERE="$(jobs_json jobs-elsewhere "9:success")"
run_cr 2 "a run whose job list could not be read is a SILENCE, and silence outranks quiescence" \
  --runs-fixture "$RUNS_QUIET_UNREAD" --jobs-fixture "$JOBS_ELSEWHERE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE"
saw "its job list could not be read" "the unreadable run is named"
not_saw "QUIET WINDOW:" "an unreadable window is never a quiet one"

# (u6) CONDITION 4 — THE TRIGGER IS ALIVE (dr-w35). BEHIND is RUN-derived, so a
# dead push trigger empties the window of delivering runs while merges continue:
# the stale serving sha keeps its cp row, the list stays PRESENT-EMPTY, zero
# rows sit in-window — the first three conditions all HOLD and quiescence read
# green while production fell behind main. The fixture below is that exact
# shape: a main commit inside the window touching deploy.yml's own on.push path
# filters, with zero deploy.yml runs of any status in-window. First the defect
# is the fixture; the guard makes it a named rc-2 refusal.
commits_json() { # <name> <sha=file,file,...>...
  local out="$TMP/$1.json"; shift
  {
    printf '['
    local first=1 spec sha files f f2
    for spec in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      sha="${spec%%=*}"; files="${spec#*=}"
      printf '{"sha":"%s","files":[' "$sha"
      f2=1
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f2" = 1 ] || printf ','
        f2=0
        printf '"%s"' "$f"
      done <<<"$(tr ',' '\n' <<<"$files")"
      printf ']}'
    done
    printf ']'
  } > "$out"
  fixture_ok "$out"
  echo "$out"
}

COMMITS_RELEVANT="$(commits_json commits-relevant "$SHA_C=cloud/lib/runtime.ex,docs/readme.md")"
run_cr 2 "a deploy-path commit in the window with ZERO deploy.yml runs is a DEAD TRIGGER, not quiescence" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE" \
  --commits-fixture "$COMMITS_RELEVANT"
saw "DEAD-TRIGGER SUSPECT: 1 file change(s)" "the refusal is its own named sentence, counting the deploy-path changes"
saw "the push trigger never fired for them" "and it says what died — the trigger, not the repo"
not_saw "QUIET WINDOW:" "a window production is falling behind is never quiet"

# (u6b) NON-VACUITY, docs side: the same window with only docs-file commits is
# still quiescence — the guard keys on deploy.yml's OWN path filters, so a
# guard hardened into always-refusing reds HERE.
COMMITS_DOCS="$(commits_json commits-docs "$SHA_C=docs/readme.md,MEMORY.md")"
run_cr 0 "docs-only commits in the window are still a quiet green" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE" \
  --commits-fixture "$COMMITS_DOCS"
saw "QUIET WINDOW:" "docs-only quiescence still reads green"
not_saw "DEAD-TRIGGER" "and no dead trigger is invented out of a docs merge deploy.yml never fires on"

# (u6c) NON-VACUITY, runs side: the same deploy-path commit WITH a deploy.yml
# run in the window (skipped legs — a run that delivered nothing) means the
# TRIGGER IS ALIVE, which is all condition 4 asserts. A guard that ignores the
# run count and keys only on commits reds HERE.
RUNS_ALIVE="$(runs_json runs-quiet-alive "$SHA_C:$IN2")"
JOBS_ALIVE="$(jobs_json jobs-quiet-alive "1:skipped")"
run_cr 0 "the same commit with a (non-delivering) deploy.yml run in-window: the trigger is alive" \
  --runs-fixture "$RUNS_ALIVE" --jobs-fixture "$JOBS_ALIVE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE" \
  --commits-fixture "$COMMITS_RELEVANT"
saw "QUIET WINDOW:" "a live trigger that delivered nothing is still quiescence"
not_saw "DEAD-TRIGGER" "condition 4 accuses the TRIGGER, never a run that fired and delivered nothing"

# (u6d) FAIL CLOSED: a commit list that cannot be read refuses quiescence with
# its own named reason — an unreadable dead-trigger check must never green.
run_cr 2 "an unreadable commit list refuses quiescence, fail-closed and named" \
  --runs-fixture "$RUNS_OLD" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_QUIET" --health-fixture "$HEALTH_BASE" \
  --commits-fixture "$TMP/no-such-commits.json"
saw "the main commit list for the window could not be read" "the unreadable check is named"
not_saw "QUIET WINDOW:" "and nothing greens off a check that did not run"

# The doctrine is STATED in the script, not only implemented — same contract as
# section (q): a rule that lives only in a guard expression is a rule the next
# reader has to reverse-engineer.
for phrase in "QUIET WINDOW" "PRESENT-EMPTY" "an accusation source, not quiescence" "scheduled-workflow auto-disable"; do
  if grep -qF "$phrase" "$CR"; then ok "the script states: $phrase"; else bad "the script never states '$phrase' — the quiescence boundary is undocumented"; fi
done

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

section "(r) A DEPLOY THAT IS STILL RUNNING IS NOT A CLOCK FAULT, AND NOT A PAGE"
# The two live stamps that bracket this whole arm: run 31332764821 reported the
# serving_since 3s ahead of now on an NTP-healthy plane (inter-host jitter), and
# run 31334953628 reported it 54s ahead because a deploy was genuinely IN FLIGHT.
# Before this, BOTH landed on the negative-age skew arm and paged.
FUTURE54="2026-08-09T12:00:54Z"   # 54s AHEAD of NOW — the measured in-flight stamp
FUTURE3="2026-08-09T12:00:03Z"    # 3s AHEAD of NOW — the measured jitter stamp
HEALTH_FUT54="$(health_json health-fut54 "$SHA_D" "$FUTURE54")"

# THE EPSILON IS A BAND, DERIVED OUT OF THE SCRIPT — never a literal re-typed
# here. Below 4 it re-swallows the measured 3s jitter; at 54 or above it swallows
# the in-flight case this section exists to route elsewhere. A later widening
# past either edge reds HERE rather than quietly muting the arm.
EPS="$(sed -n 's/^SERVING_SKEW_EPSILON_SECONDS=\([0-9][0-9]*\).*/\1/p' "$CR" | head -1)"
if [ -z "$EPS" ]; then
  bad "SERVING_SKEW_EPSILON_SECONDS is not derivable from $CR — an epsilon nobody can read back is not pinned by anything"
elif [ "$EPS" -ge 4 ] && [ "$EPS" -lt 54 ]; then
  ok "the skew epsilon (${EPS}s) is inside the measured band 4 <= EPS < 54 — above the 3s jitter, below the 54s in-flight stamp"
else
  bad "the skew epsilon is ${EPS}s, outside the measured band 4 <= EPS < 54 — it either re-pages on 3s jitter or swallows the 54s in-flight case"
fi

# (r1) IN FLIGHT: a deploy.yml run for the SERVED sha is still running.
RUNS_INFLIGHT_D="$(with_inflight runs-inflight-d "$SHA_D" "$IN2" "$SHA_A:$IN1" "$SHA_B:$IN2")"
run_cr 4 "a deploy for the served sha is STILL RUNNING — not yet due, not a page" \
  --runs-fixture "$RUNS_INFLIGHT_D" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FUT54"
saw "SERVING IN FLIGHT" "the in-flight arm is its own named deferral"
saw "9001" "and it NAMES the run that is still running, so the reader can go look at it"
not_saw "SERVING-CLOCK-SKEW" "a running deploy is no longer reported as a clock fault"
not_saw "SERVING-UNRECORDED" "and the row is not accused while the run that would write it is still going"
saw "NOT YET DUE" "it is a deferral — never a page, and never a green either"

# (r2) NON-VACUITY: the SAME future stamp with NOTHING in flight still accuses.
# Without this the arm above would be indistinguishable from a blanket amnesty.
run_cr 1 "the same 54s-ahead stamp with no run in flight is STILL a clock fault" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FUT54"
saw "SERVING-CLOCK-SKEW" "with nothing running, a future serving_since is still a fault"
saw "54s in the FUTURE" "and it still says how far ahead the reported instant is"
saw "SERVING-UNRECORDED" "and the missing row is still accused"
not_saw "SERVING IN FLIGHT" "no in-flight deferral is invented out of an empty run page"

# (r3) THE SHA MATCH: some OTHER deploy being busy is not an alibi for this sha.
RUNS_INFLIGHT_C="$(with_inflight runs-inflight-c "$SHA_C" "$IN2" "$SHA_A:$IN1" "$SHA_B:$IN2")"
run_cr 1 "a run in flight for a DIFFERENT sha does not excuse the served one" \
  --runs-fixture "$RUNS_INFLIGHT_C" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FUT54"
saw "SERVING-CLOCK-SKEW" "the accusation stands when the running run belongs to another commit"
not_saw "SERVING IN FLIGHT" "the arm keys on the SERVED sha, not on any run being busy"

# (r4) THE EPSILON: 3s of inter-host jitter is not a clock fault either, and it
# is still a DEFERRAL — the debt is written, nothing is forgiven.
HEALTH_FUT3="$(health_json health-fut3 "$SHA_D" "$FUTURE3")"
run_cr 4 "a serving_since 3s ahead is jitter, not a fault" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FUT3"
not_saw "SERVING-CLOCK-SKEW" "3s of inter-host jitter no longer pages"
saw "SERVING GRACE:" "it is the grace, named, and not a silent pass"
not_saw "RECONCILED:" "and a deferral is still not a green"

# (r5) The in-flight row does NOT enter the success population: the jq filter
# still asks for conclusion == success, so every count downstream is unmoved.
run_cr 4 "the in-flight run is not counted as a successful run" \
  --runs-fixture "$RUNS_INFLIGHT_D" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FUT54"
saw "POPULATION: 2 completed deploy.yml run(s)" "the population is bounded by construction — the in-flight row is fetched, never counted, because it is not COMPLETED"

# (r6) THE CAP: an in-flight run is an alibi WITH AN EXPIRY. Unbounded, the arm
# re-deferred for as long as GitHub reported the run in_progress, so a HUNG run
# bought amnesty bounded only by GitHub's ~6h default job timeout — a bound the
# script never stated (dr-w34-fu-inflight-deferral-is-unbounded). The pair (r1)
# + (r6) is the mutation proof in both directions: strip the cap condition and
# (r6) reds (rc 4, deferral, where 1 is pinned); zero the cap and (r1) reds.
CAP="$(sed -n 's/^SERVING_INFLIGHT_CAP_SECONDS=\([0-9][0-9]*\).*/\1/p' "$CR" | head -1)"
GRACE_S="$(sed -n 's/^SERVING_GRACE_SECONDS=\([0-9][0-9]*\).*/\1/p' "$CR" | head -1)"
if [ -z "$CAP" ]; then
  bad "SERVING_INFLIGHT_CAP_SECONDS is not derivable from $CR — an unbounded in-flight arm is the exact defect this section pins"
else
  # The BAND, both edges reasoned: at or below SERVING_GRACE_SECONDS the
  # in-flight arm would be a STRICTER deferral than the plain grace beside it
  # (an alibi worth less than no alibi); at or beyond 21600s it re-creates
  # GitHub's own default job timeout and caps nothing.
  if [ "$CAP" -gt "${GRACE_S:-1200}" ] && [ "$CAP" -lt 21600 ]; then
    ok "the in-flight cap (${CAP}s) sits inside the reasoned band GRACE < CAP < 21600"
  else
    bad "the in-flight cap is ${CAP}s, outside the band ${GRACE_S:-1200} < CAP < 21600 — it either outranks the plain grace or re-states GitHub's own timeout"
  fi
  NOW_S="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s)"
  CR_STATE="$TMP/state-inflight-expired.txt"
  printf '%s %s\n' "$SHA_D" "$((NOW_S - CAP - 60))" > "$CR_STATE"
  run_cr 1 "a run in_progress since beyond the cap no longer defers — the hung run is accused" \
    --runs-fixture "$RUNS_INFLIGHT_D" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
  saw "SERVING-INFLIGHT-EXPIRED" "the expiry is its own named sentence, not a generic red"
  saw "9001" "and it still NAMES the hung run, so the reader can go look at it"
  saw "past the ${CAP}s cap" "and it states the cap it charged against"
  saw "SERVING-UNRECORDED" "the missing row is accused, no longer excused"
  not_saw "SERVING IN FLIGHT:" "the deferral sentence is gone — this is not a deferral"
  not_saw "NOT YET DUE" "and rc 1 means accusation, never the rc-4 warning"
  CR_STATE=""

  # (r6b) ONE SECOND INSIDE the cap still defers: the boundary belongs to the
  # alibi, so a cap tightened by accident reds HERE and not in production.
  CR_STATE="$TMP/state-inflight-inside.txt"
  printf '%s %s\n' "$SHA_D" "$((NOW_S - CAP + 60))" > "$CR_STATE"
  run_cr 4 "the same run 60s inside the cap is still a named deferral" \
    --runs-fixture "$RUNS_INFLIGHT_D" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
  saw "SERVING IN FLIGHT" "inside the cap the alibi still holds"
  not_saw "SERVING-INFLIGHT-EXPIRED" "and no expiry is invented before its time"
  CR_STATE=""
fi

section "(h) a docs-only run delivered NOTHING and must not be counted BEHIND"
RUNS_DOCS="$(runs_json runs-docs "$SHA_A:$IN1" "$SHA_C:$IN2")"
JOBS_DOCS="$(jobs_json jobs-docs "1:success" "2:skipped")"
CROWN_DOCS="$(crown_json crown-docs \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)")"
run_cr 0 "run 2 skipped both legs and has no row — correctly" \
  --runs-fixture "$RUNS_DOCS" --jobs-fixture "$JOBS_DOCS" --crown-fixture "$CROWN_DOCS" --health-fixture "$HEALTH_BASE"
saw "1 delivered nothing (no leg concluded success" "it says how many runs delivered nothing, beside the population"
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

section "(v) A PARTIALLY-FAILED RUN THAT DELIVERED THROUGH ONE LEG IS DELIVERING"
# THE LIVE RED, IN THREE ARMS. crown-reconcile was NOT reconciled on every main
# push from 08:34Z 2026-09-03 with `wrong=7/100` — seven honest rows accused.
# Every one of them was written by a deploy.yml run whose `instance` leg concluded
# SUCCESS and whose `control-plane` leg FAILED (the owner's CP box), so the RUN's
# overall conclusion is `failure`. The population filtered on the RUN's conclusion
# before it ever looked at the legs, so that run was absent from the alibi set and
# the recorder's own true row was called a ghost (run 33816988316 / row b11be4f43,
# 2026-09-04). The population is now keyed on the LEGS, and these three arms hold
# both directions of that down.
RUNS_PARTIAL="$(runs_add runs-partial "$(runs_json runs-partial-a "$SHA_A:$IN1")" 2 "$SHA_B" completed failure "$IN2")"

# (v-a) the delivering direction: one leg succeeded, so the row naming that run is
# CORRECT and the window reconciles.
JOBS_PARTIAL="$(jobs_legs jobs-partial "1:success:success" "2:failure:success")"
run_cr 0 "run 2 concluded FAILURE but its instance leg delivered — its row is not a ghost" \
  --runs-fixture "$RUNS_PARTIAL" --jobs-fixture "$JOBS_PARTIAL" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
not_saw "WRONG:" "a row written by a run that delivered through one leg is NOT WRONG"
saw "WHATEVER the run's overall conclusion" "the POPULATION line states the leg rule in words"
saw "2 of them DELIVERED" "the partially-failed run is counted in the delivering population"
saw "1 of those delivered with the OTHER leg FAILED" "the population prints how many delivering runs had a failed other leg"

# (v-b) THE NON-VACUITY HALF: the same run, the same row, both legs failed. Nothing
# delivered, so the row IS a ghost and the axis can still lose.
JOBS_BOTH_FAILED="$(jobs_legs jobs-both-failed "1:success:success" "2:failure:failure")"
run_cr 1 "the same row when BOTH legs failed — nothing delivered, so it is still WRONG" \
  --runs-fixture "$RUNS_PARTIAL" --jobs-fixture "$JOBS_BOTH_FAILED" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
saw "WRONG:" "a run with no succeeding leg delivers nothing, and its row is a ghost"
saw "1 of them DELIVERED" "the both-failed run is NOT in the delivering population"

# (v-c) THE BEHIND DIRECTION: the partially-failed run really delivered $SHA_B, so a
# crown with no row for it is BEHIND. A run promoted into the population must be
# judged by it, not merely excused by it.
CROWN_PARTIAL_NOROW="$(crown_json crown-partial-norow \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)")"
run_cr 1 "run 2 delivered $SHA_B through its instance leg and the crown has no row" \
  --runs-fixture "$RUNS_PARTIAL" --jobs-fixture "$JOBS_PARTIAL" --crown-fixture "$CROWN_PARTIAL_NOROW" --health-fixture "$HEALTH_BASE"
saw "BEHIND: 1 of 2 delivering run(s)" "the promoted run is in the BEHIND denominator, not just in the alibi set"
saw "$SHA_B" "it names the sha the partially-failed run delivered and nothing recorded"

section "(x) AN ALIBI THAT COULD NOT BE READ IS NOT AN ALIBI THAT IS ABSENT"
# THE LIVE RED, AGAIN, AND IN THE OPPOSITE DIRECTION FROM (v). crown-reconcile
# was red on 6 of its last 24 scheduled main runs with `wrong=1/100` — one honest
# row each time. Run 34012723514 (2026-09-06T04:56Z) accused row 9a5145965f… of
# being written by run 33985744753, "which is not a delivering run in the
# window". That run is deploy.yml on main, instance=success control-plane=skipped,
# created 2026-09-05T18:59:45Z — inside the window and inside the page (ids
# 33955489300..34012723496). It DELIVERS by this script's own rule, and the same
# run's POPULATION line printed `0 unreadable`, so its FIRST jobs read (the
# examined loop) succeeded. The alibi set was built by a SECOND read of the very
# same run, and `if run_delivers "$id"` folded that read's failure into "does not
# deliver". Two changes hold this down: the second read is not made at all, and a
# row whose deliverer could not be read is DEFERRED (rc 2) instead of accused.
#
# Three arms, and the two non-vacuity ones come first so the deferral can never
# be mistaken for a tolerance that swallows the whole axis.

# (x-a) THE NON-VACUITY HALF, "does not deliver": run 2 is READ, and both its legs
# failed. Nothing delivered, so the row naming it is still a ghost.
JOBS_X_BOTH_FAILED="$(jobs_legs jobs-x-both-failed "1:success:success" "2:failure:failure")"
run_cr 1 "run 2 was READ and delivered nothing — its row is still WRONG" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_X_BOTH_FAILED" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
saw "WRONG:" "a run that was read and delivered nothing still produces a WRONG"
saw "$SHA_B" "the accused row is named"
not_saw "UNREADABLE-ALIBI:" "a run that WAS read is never excused as unreadable"

# (x-b) THE NON-VACUITY HALF, "delivers": run 2 is READ and delivered. Reconciled.
run_cr 0 "run 2 was READ and delivered — its row stays reconciled" $(base_args)
not_saw "WRONG:" "a row whose run delivers is not a ghost"
not_saw "UNREADABLE-ALIBI:" "nothing was unreadable, so nothing is deferred"

# (x-c) THE FIX. The SAME runs page and the SAME crown — one field moves: run 2's
# entry is absent from the jobs fixture, which is what a jobs-API call that did
# not answer looks like to this script. The row must be DEFERRED and NAMED, never
# reported WRONG, and the run exits 2 (SILENCE), not 1.
JOBS_X_UNREADABLE="$(jobs_json jobs-x-unreadable "1:success")"
run_cr 2 "run 2's job list could not be read — its row is deferred, not accused" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_X_UNREADABLE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
not_saw "WRONG:" "a row whose deliverer could not be read is NEVER reported WRONG"
saw "UNREADABLE-ALIBI:" "the deferred row gets its own printed class"
saw "(run 2)" "the deferred row names the run whose job list could not be read"
saw "ALIBI SET INCOMPLETE:" "the alibi set states that it is incomplete"
saw "run 2  (head $SHA_B)" "the unreadable alibi run is named by id and head sha"

# (x-d) THE DEFERRAL IS NOT A BLANKET. One window, both shapes at once: run 2's
# jobs read fails while run 3 is read and delivers nothing. The row naming run 3
# is still WRONG (exit 1 — an accusation outranks a silence), the row naming
# run 2 is NOT in the accusation, and the deferred row is SUBTRACTED from the
# WRONG denominator rather than counted in it.
RUNS_X3="$(runs_add runs-x3 "$RUNS_BASE" 3 "$SHA_C" completed success "$IN2")"
JOBS_X_MIX="$(jobs_legs jobs-x-mix "1:success:success" "3:failure:failure")"
CROWN_X_MIX="$(crown_json crown-x-mix \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_B" instance false "$IN2" 2)" \
  "$(row "$SHA_C" instance false "$IN2" 3)")"
run_cr 1 "one unreadable alibi and one real ghost in the same window" \
  --runs-fixture "$RUNS_X3" --jobs-fixture "$JOBS_X_MIX" --crown-fixture "$CROWN_X_MIX" --health-fixture "$HEALTH_BASE"
saw "$SHA_C — recorded as delivered by run 3" "the row whose run WAS read and delivered nothing is accused"
not_saw "$SHA_B — recorded as delivered by run 2" "the row whose run could not be read is NOT accused"
saw "unreadable-alibi=1" "the verdict line carries the deferred count"
saw "wrong=1/3" "the deferred row is subtracted from the WRONG denominator, not counted in it"

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

section "(o) WHICH READER ANSWERED is a verdict field, and a 401 is a VERDICT"
# The live shape, in effigy. A production run took the 401→postgres downgrade on
# every read and said so TEN times as a `note:` on stderr, behind a header that
# named only the TRANSPORT (`reader=ssh`). The transport is not the reader.
#
# PR #14979 admitted the WORKER principal to GET /v1/deliveries, so the detour's
# premise — "a 401 here is a TIER MISMATCH, not a broken box" — is now false, and
# the detour is deleted. These arms stand up a control plane in effigy (`gh`,
# `curl` and `ssh` are all fakes on PATH) and drive the SAME script down the SSH
# reader three ways:
#
#   200 + CR_VIA=route   → read by `route`, rc 0            (the normal path)
#   401 + CR_ERROR       → REFUSED: rc 2, and the verdict NAMES the code, the
#                          WORKER principal and #14979      (was: a silent green)
#   401 + CR_VIA=sql     → a body claiming the postgres container is REFUSED
#                          rather than counted               (was: rc 0, `read by
#                          postgres-container`)
#
# The fake NEVER supplies the refusal sentence: it emits only CR_HTTP + CR_ERROR,
# exactly the shape the script's own remote reader emits, so the naming asserted
# below is the SCRIPT's sentence and not the harness's.
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
# The control plane's remote reader, in effigy: it reports exactly the lines
# scripts/crown-reconcile.sh's own remote.sh emits. CR_FAKE_VIA empty means the
# refusal shape — a code and an error name, and NO body and NO sentence, so any
# naming downstream is the script's own.
echo "CR_HTTP=$CR_FAKE_HTTP"
if [ -n "${CR_FAKE_VIA:-}" ]; then
  echo "CR_VIA=$CR_FAKE_VIA"
  echo "CR_BODY={\"deliveries\":$(cat "$CR_FAKE_ROWS")}"
else
  echo "CR_ERROR=http_${CR_FAKE_HTTP}_worker_principal"
fi
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

# THE ROW THIS FIX EXISTS FOR. Pre-#14979 this same input exited 0 and said
# `read by postgres-container`. It must now be a read that DID NOT HAPPEN.
run_fake 2 "the route answers 401 to the WORKER principal — a VERDICT, not a detour" 401 ""
saw "COULD NOT FULLY READ" "a 401 to the WORKER principal is an unreadable condition, never a green"
saw "answered HTTP 401 to the WORKER principal" "the verdict names the CODE and the PRINCIPAL"
saw "WORKER_TOKEN" "…and the credential by name, so an operator knows which bearer was refused"
saw "#14979" "…and the PR that admitted that principal, so the refusal reads as the REGRESSION it is"
saw "refused-401/403=" "the refusal is a counted field beside the reader, not only a sentence"
not_saw "read by postgres-container" "no substitute reader answered in its place"
not_saw "RECONCILED:" "a run that could not read the crown never prints a green"

# THE SUBSTITUTE READER IS REFUSED, not counted. This is the OLD detour's own
# output shape, replayed: a body that claims it came from the postgres container.
# The detour is gone from the script, so a body claiming it can only come from a
# script that still detours — and it must not be able to buy a green.
run_fake 2 "a body claiming the postgres container is REFUSED, not counted as a read" 401 sql
saw "claiming reader 'sql'" "the substitute reader is named in the refusal"
saw "NO substitute reader" "the sentence states the rule it enforced"
not_saw "answered by postgres-container" "the deleted reader is not a name this script can print"
not_saw "read by postgres-container" "and it cannot ride a green sentence either"
not_saw "answered by route" "the transport did not decide the answer — the three runs report DIFFERENT outcomes"

section "(o2) THE REMOTE READER ITSELF — a 401 names the principal and NEVER reaches psql"
# (o) drives the script with `ssh` faked, so it proves what the LOCAL half does
# with a refusal. It cannot prove what the REMOTE half emits, because the remote
# half never runs there — and the remote half is where the psql detour lived.
#
# So this arm EXTRACTS the remote reader out of the script's own heredoc (never a
# copy typed here: a heredoc that drifts moves this test) and runs it against a
# control plane in effigy — `docker` and `curl` are fakes, and the fake `docker`
# answers the postgres container AND `psql` with rows. A script that still
# detours would therefore take the detour and print CR_VIA=sql. The assertions
# below are what makes that impossible: the 401 arm must NAME the refusal, and
# the fake docker's LOG must never have been asked for postgres at all.
RFAKE="$TMP/rfake"; mkdir -p "$RFAKE"
REMOTE_SH="$TMP/remote-extracted.sh"
awk '/<<.REMOTE.$/ { f = 1; next } f && /^REMOTE$/ { exit } f { print }' "$CR" > "$REMOTE_SH"
if [ -s "$REMOTE_SH" ]; then
  ok "the remote reader was extracted from the script's own heredoc ($(wc -l < "$REMOTE_SH" | tr -d ' ') lines)"
else
  bad "the remote reader heredoc could not be extracted from $CR — every assertion below would be vacuous"
fi

cat > "$RFAKE/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CR_DOCKER_LOG"
case "$*" in
  # THE STABLE KEY. The reader finds the control plane by its compose container
  # NAME PREFIX, not by `ancestor=<image>:<tag>` — see (o3) below for why. The
  # ancestor arm is kept and answered so this fake stays honest about BOTH keys:
  # these arms are about the 401/psql question, and must not red for want of a
  # container whichever key the reader uses.
  *"name=cloud-control_plane_"*)      echo "cp-container-in-effigy" ;;
  *"ancestor=cloud-control_plane"*)   echo "cp-container-in-effigy" ;;
  *"printenv WORKER_TOKEN"*)          echo "worker-token-in-effigy" ;;
  # The DETOUR's own dependencies, all answered generously ON PURPOSE: a script
  # that still detours gets everything it needs and prints CR_VIA=sql, so the
  # assertions below fail LOUDLY rather than for want of a fixture.
  *"ancestor=postgres"*)              echo "db-container-in-effigy" ;;
  *"printenv POSTGRES_USER"*)         echo "bp" ;;
  *"printenv POSTGRES_DB"*)           echo "bp_prod" ;;
  *psql*)                             echo '[{"sha":"detour","target":"cp"}]' ;;
esac
SH
cat > "$RFAKE/curl" <<'SH'
#!/usr/bin/env bash
# Prints the code and writes NOTHING: no arm below reads a body, and the reader's
# body path is an absolute path on the control plane, not a path this harness owns.
printf '%s' "$CR_FAKE_HTTP"
SH
chmod +x "$RFAKE/docker" "$RFAKE/curl"

remote_run() { # <http-code>
  CR_DOCKER_LOG="$TMP/docker-$1.log"; : > "$CR_DOCKER_LOG"
  PATH="$RFAKE:$SANDBOX_PATH" CR_FAKE_HTTP="$1" CR_DOCKER_LOG="$CR_DOCKER_LOG" \
    bash "$REMOTE_SH" "sha=$SHA_A" > "$TMP/last.out" 2>&1
  DOCKER_LOG="$CR_DOCKER_LOG"
}
no_detour() { # <label>
  if grep -qE 'postgres|psql' "$DOCKER_LOG"; then
    bad "$1 — docker was asked: $(tr '\n' ';' < "$DOCKER_LOG")"
  else
    ok "$1"
  fi
}

remote_run 401
saw "CR_HTTP=401" "the reader reports the code it got"
saw "CR_ERROR=http_401_worker_principal" "a 401 is an ERROR that names the PRINCIPAL, not a via"
saw "GET /v1/deliveries answered HTTP 401 to the WORKER principal" "the detail line names the ROUTE, the CODE and the PRINCIPAL"
saw "WORKER_TOKEN" "…and the credential by name"
saw "#14979" "…and the PR that admitted that principal, so a refusal reads as a REGRESSION"
not_saw "CR_VIA=sql" "the postgres detour does not fire"
not_saw "CR_BODY=" "and it produces no rows to be mistaken for a read"
no_detour "docker was NEVER asked for the postgres container, and psql was never run"

remote_run 403
saw "CR_ERROR=http_403_worker_principal" "a 403 takes the same named arm as a 401"
not_saw "CR_VIA=sql" "a 403 does not detour either"
no_detour "a 403 reaches no psql either"

# THE NON-401 ARM IS KEPT, and kept DISTINCT: a 500 is a broken box, not a
# refused principal, and calling it one would misname the next outage.
remote_run 500
saw "CR_ERROR=http_500" "a non-401/403 code keeps its plain CR_ERROR=http_N arm"
not_saw "_worker_principal" "a 500 is a broken box, not a refused principal — the two are not merged"
no_detour "a 500 reaches no psql either"

# The static half of the same claim: the detour is DELETED, not merely unreached.
# THE CODE, NOT THE WORD. The reader's own prose says what was removed and why —
# a bare grep would red on the explanation, which is the trap a fix's rationale
# comment always sets for the check that guards it. Comments are stripped first,
# and the strip is proven non-empty so this cannot pass by grepping nothing.
grep -v '^[[:space:]]*#' "$REMOTE_SH" > "$TMP/remote-code.sh"
if [ -s "$TMP/remote-code.sh" ]; then
  ok "the reader has code left after its comments are stripped — the check below is not vacuous"
else
  bad "stripping comments emptied the reader — the detour check below would pass on nothing"
fi
if grep -qE 'psql|platform_deliveries' "$TMP/remote-code.sh"; then
  bad "the remote reader still carries the psql detour — a branch that is unreached today is a branch that returns"
  grep -nE 'psql|platform_deliveries' "$TMP/remote-code.sh" >&2
else
  ok "no executable line of the remote reader mentions psql or platform_deliveries — the detour is deleted, not skipped"
fi

section "(o3) THE CONTAINER IS FOUND BY A STABLE IDENTITY, NOT A MOVING IMAGE TAG"
# THE OUTAGE THIS ARM OWNS. crown-reconcile.yml exited 2 SILENCE on main three
# times on 2026-09-06 (runs 34048569972, 34050639617, 34049400499), every one of
# them saying "the crown could not be read on the box for ?sha=…:
# no_control_plane_container", and every one of them coinciding with deploy.yml
# activity on the box. The reader had located the control plane with
#   docker ps -q --filter ancestor=cloud-control_plane:latest
# — an IMAGE key, and `latest` is the one thing about the control plane that
# MOVES. deploy/cp-deploy.sh:133 retags the serving image to `:rollback`,
# cp-deploy.sh:452 builds the new image onto `:latest`, and only at
# cp-deploy.sh:470 does the new slot boot. Between those the OLD container is
# still serving and the ancestor filter matches NOTHING. The reconciler refusing
# to call that a green was CORRECT; the KEY was wrong.
#
# The stable identity is the compose container NAME PREFIX — project + service,
# untouched by any rebuild: cloud/docker-compose.yml:196,202 define the services
# `control_plane_blue` / `control_plane_green`, and deploy/cp-deploy.sh:286
# builds the same string itself as
# "${COMPOSE_PROJECT_NAME:-cloud}-control_plane_${ACTIVE_SLOT}-1". The SLOT is
# left off the filter on purpose: both slots match, and either will do, because
# every live control plane carries the same WORKER_TOKEN.
#
# BOTH DIRECTIONS ARE PROVEN HERE, because a retry that only ever passes is a
# way of laundering an absence into a green:
#   (i)  tag moved, container up  → the read SUCCEEDS
#   (ii) no container at all      → still no_control_plane_container, still rc 2
SWAPF="$TMP/swapfake"; mkdir -p "$SWAPF"
# The curl in effigy for this section WRITES the body file the reader asked for
# (`-o <path>`), because unlike (o2) these arms drive the 200 path all the way to
# CR_BODY. It is the reader's own path and the reader removes it again.
cat > "$SWAPF/curl" <<'SH'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
[ -n "$out" ] && printf '%s' '{"deliveries":[]}' > "$out"
printf '%s' "$CR_FAKE_HTTP"
SH
# THE SWAP WINDOW IN EFFIGY. `latest` has ALREADY moved to the freshly built
# image, so an ancestor filter matches nothing — this fake answers it with
# SILENCE on purpose, which is exactly what the box did during those three runs.
# The old slot's container is still up, so a NAME lookup finds it.
cat > "$SWAPF/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CR_DOCKER_LOG"
case "$*" in
  *"ancestor=cloud-control_plane"*)   : ;;
  *"name=cloud-control_plane_"*)      echo "cp-container-in-effigy" ;;
  *"printenv WORKER_TOKEN"*)          echo "worker-token-in-effigy" ;;
esac
SH
# NOTHING IS RUNNING. Every docker query is answered with silence, so the only
# honest verdict is the absence — after the retries, not before them.
GONEF="$TMP/gonefake"; mkdir -p "$GONEF"
cp "$SWAPF/curl" "$GONEF/curl"
cat > "$GONEF/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CR_DOCKER_LOG"
SH
chmod +x "$SWAPF/docker" "$SWAPF/curl" "$GONEF/docker" "$GONEF/curl"

# CR_CP_ATTEMPTS/CR_CP_DELAY are the reader's own bounds, overridden here so the
# absence arm does not sleep through its own retry budget. The COUNT is what is
# asserted; the delay is not part of the contract.
swap_run() { # <fake-dir> <log> <http>
  CR_DOCKER_LOG="$TMP/docker-$2.log"; : > "$CR_DOCKER_LOG"
  PATH="$1:$SANDBOX_PATH" CR_FAKE_HTTP="$3" CR_DOCKER_LOG="$CR_DOCKER_LOG" \
    CR_CP_ATTEMPTS=3 CR_CP_DELAY=0 \
    bash "$REMOTE_SH" "sha=$SHA_A" > "$TMP/last.out" 2>&1
  DOCKER_LOG="$CR_DOCKER_LOG"
}

# (o3-a) THE TAG MOVED AND THE CONTAINER IS UP → THE READ SUCCEEDS.
# Against the pre-fix reader this arm is RED: the ancestor filter is answered
# with silence, so the reader printed CR_ERROR=no_control_plane_container and
# never reached the route at all.
swap_run "$SWAPF" swap 200
saw "CR_HTTP=200" "the tag moved mid-deploy and the read still reached the route"
saw "CR_VIA=route" "…answered by the route, the only reader this script has"
saw "CR_BODY=" "…and it came back with a body"
not_saw "CR_ERROR=no_control_plane_container" "a moved image tag is NOT an absent control plane"
if grep -q "name=cloud-control_plane_" "$DOCKER_LOG"; then
  ok "the container was looked up by its compose NAME prefix (deploy/cp-deploy.sh:286, cloud/docker-compose.yml:196,202)"
else
  bad "the reader never asked docker by name — it is still keyed on something that moves: $(tr '\n' ';' < "$DOCKER_LOG")"
fi
if grep -q "ancestor=cloud-control_plane" "$DOCKER_LOG"; then
  bad "the reader still asks by ancestor=<image>:<tag> — the key that fails for the whole swap window"
else
  ok "the reader never asks by ancestor=<image>:<tag> — the moving key is gone, not merely supplemented"
fi
if [ "$(grep -c "name=cloud-control_plane_" "$DOCKER_LOG")" = "1" ]; then
  ok "a container that is THERE is found on the first attempt — the retry costs nothing on the happy path"
else
  bad "the reader retried a lookup that already succeeded ($(grep -c "name=cloud-control_plane_" "$DOCKER_LOG") lookups)"
fi

# (o3-b) NO CONTAINER AT ALL → STILL THE NAMED ABSENCE. The retry must not be a
# way to turn a real absence into a pass, so the same reader, same bounds, with
# nothing running, has to reach exactly the verdict it reached before.
swap_run "$GONEF" gone 200
saw "CR_ERROR=no_control_plane_container" "a control plane that is REALLY absent is still the named absence"
not_saw "CR_HTTP=" "…and the route was never asked, so no code can be mistaken for a read"
not_saw "CR_BODY=" "…and no body exists to be counted as a read"
saw "CR_CP_ATTEMPTS=3" "the reader PRINTS how many times it looked before naming the absence"
saw "CR_CP_RETRY=1/3" "…and prints each attempt as it happens"
saw "CR_CP_RETRY=3/3" "…through to the last one, so the window it covered is legible"
if [ "$(grep -c "name=cloud-control_plane_" "$DOCKER_LOG")" = "3" ]; then
  ok "the retry is REAL and BOUNDED: exactly 3 lookups for a budget of 3, not 1 and not forever"
else
  bad "the budget of 3 produced $(grep -c "name=cloud-control_plane_" "$DOCKER_LOG") lookup(s) — the retry is vacuous or unbounded"
fi

# (o3-c) THE TWO ABSENCES STAY DISTINCT. A container that is there and hands back
# no token is a mis-provisioned control plane, not a swap window, and folding it
# into no_control_plane_container would misname the next outage.
NOTOKF="$TMP/notokfake"; mkdir -p "$NOTOKF"
cp "$SWAPF/curl" "$NOTOKF/curl"
cat > "$NOTOKF/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CR_DOCKER_LOG"
case "$*" in
  *"name=cloud-control_plane_"*)      echo "cp-container-in-effigy" ;;
esac
SH
chmod +x "$NOTOKF/docker" "$NOTOKF/curl"
swap_run "$NOTOKF" notok 200
saw "CR_ERROR=empty_worker_token" "a container that IS there with no token keeps its own name"
not_saw "CR_ERROR=no_control_plane_container" "…and is not laundered into the absence the retry exists for"

# (o3-d) THE VERDICT, END TO END. The arms above prove what the REMOTE half
# emits. This one drives the WHOLE script with that emission and pins the thing
# the row actually guards: a named absence is rc 2 SILENCE, never 0.
run_gone() { # <expected-rc> <label>
  local want="$1" label="$2" out rc state gonessh
  CR_N=$((CR_N + 1))
  state="$TMP/state-gone-$CR_N.txt"
  seed_state "$state"
  gonessh="$TMP/gonessh"; mkdir -p "$gonessh"
  # The remote half in effigy, emitting EXACTLY the two lines the reader above
  # was just observed to emit — no body, no code, the named absence and the
  # attempt count. Any sentence downstream is therefore the SCRIPT's own.
  cat > "$gonessh/ssh" <<'SH'
#!/usr/bin/env bash
echo "CR_CP_ATTEMPTS=6"
echo "CR_ERROR=no_control_plane_container"
SH
  cp "$FAKE/gh" "$gonessh/gh"
  cp "$FAKE/curl" "$gonessh/curl"
  chmod +x "$gonessh/ssh" "$gonessh/gh" "$gonessh/curl"
  out="$(env -u CROWN_API_TOKEN PATH="$gonessh:$SANDBOX_PATH" \
    CP_HOST=cp.example.invalid DEPLOY_SSH_KEY=not-a-key \
    CR_FAKE_RUNS="$RUNS_FAKE" CR_FAKE_JOBS="$TMP/jobs-fake.json" \
    CR_FAKE_HEALTH="$HEALTH_FAKE" CROWN_STATE_FILE="$state" \
    bash "$CR" --now "$NOW" --window-hours 24 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last.out"
  if [ "$rc" = "$want" ]; then ok "$label → exit $rc"; else bad "$label → exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/       | /' >&2; fi
}
run_gone 2 "a control plane that is absent after the retries is SILENCE, never a green"
saw "no_control_plane_container" "the verdict names the condition it could not read past"
saw "before the absence was named" "…and says how many times it looked, so the retry is auditable from the verdict"
not_saw "RECONCILED:" "an unreadable crown never prints a green"

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
# READ THE REQUIRED SET, never grep the whole file (2026-09-06). This was
# `grep -q "crown-reconcile" "$SPEC"`, which cannot tell a REQUIRED context from
# an EXCLUSION row — and an exclusion row is the exact OPPOSITE of the thing the
# assertion forbids. The every-rendered-name census gave `Crown reconcile` and
# `Crown reconcile harness` written S4 rows whose reasons quote this workflow's
# own "must never become a required context" header; the substring `crown-
# reconcile` then appeared in the file as prose and this clause reddened on the
# ledger entry that AGREES with it. Ask jq for the contexts instead.
if [ ! -f "$SPEC" ]; then
  ok "crown-reconcile is not in the required-check spec (no spec file to read)"
elif jq -e '[.protection.required_status_checks.checks[]?.context]
            | map(ascii_downcase)
            | any(test("crown[ -]?reconcile"))' "$SPEC" >/dev/null 2>&1; then
  bad "a crown-reconcile context is REQUIRED in .github/required-checks.json — this workflow must never be a required context: $(jq -r '[.protection.required_status_checks.checks[]?.context] | join(", ")' "$SPEC")"
else
  ok "no crown-reconcile context is in the required set ($(jq -r '.protection.required_status_checks.checks | length' "$SPEC") required context(s) read with jq, not grepped)"
fi
# …and the mirror, so the clause above cannot be satisfied by a spec that simply
# forgot the name: a rendered check with NO status is the defect the census
# clause in required-checks-verify.sh exists for, so assert the row is there.
if jq -e '[.exclusions[]?.context] | index("Crown reconcile")' "$SPEC" >/dev/null 2>&1; then
  ok "…and it carries an EXCLUSION row, so the name is accounted rather than merely absent"
else
  bad "\`Crown reconcile\` has no exclusion row in $SPEC — an unaccounted rendered name reds the census clause"
fi

# THE SILENCE STOPS EXITING 0. The rc=2 arm's own text has always said it is not
# a green; run 31321844876 exited rc=2 and published a run conclusion of SUCCESS.
RC2_ARM="$(grep '^            2)' "$WF" | head -1)"
if [ -z "$RC2_ARM" ]; then
  bad "there is no rc=2 case arm to check — this assertion would be vacuous, so it fails instead"
elif grep -q 'exit 0' <<<"$RC2_ARM"; then
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
  if grep -q 'exit 0' <<<"$RC4_ARM"; then
    ok "the rc=4 NOT-YET-DUE arm exits 0 — a benign in-flight grace does not page"
  else
    bad "the rc=4 arm does not exit 0 — the deferral still pages, and five of the last six rc=2 firings were exactly this"
  fi
  if grep -q '::warning::' <<<"$RC4_ARM"; then
    ok "and it is a ::warning — the deferral is still SAID, not swallowed into a clean green"
  else
    bad "the rc=4 arm is silent or an error; a deferral must be announced as a warning"
  fi
  if grep -q '::error::' <<<"$RC4_ARM"; then
    bad "the rc=4 arm is an ::error — that is the page this split exists to stop"
  else
    ok "the rc=4 arm does not raise an error annotation"
  fi
fi
# …AND NEITHER DOES THE QUIET WINDOW. The empty-population page (8 consecutive
# scheduled reds on a quiet repo, #11217 at 41 comments) is the same lesson as
# rc 4, and the case table must SAY so — the named case, the rationale, and the
# rows-exist boundary — or the next reader of the yml re-derives the page.
if grep -qF "QUIET WINDOW" "$WF"; then
  ok "the case table documents the QUIET WINDOW named case"
else
  bad "$WF never names the QUIET WINDOW case — an rc-0 deferral the table does not document reads as a plain green"
fi
if grep -qF "the rc-4 precedent, dr-w31-s2" "$WF"; then
  ok "and it carries the rc-4 precedent rationale — paging on the benign case is what mutes the alarm for the real one"
else
  bad "$WF documents the quiet case without the rc-4 precedent rationale that justifies an empty window ever reading green"
fi
if grep -qF "STAYS rc 2" "$WF"; then
  ok "and it states that rows-exist-but-no-runs STAYS rc 2 — the boundary of the tolerance is written down"
else
  bad "$WF never states the rows-exist boundary — a reader cannot tell what the quiet tolerance does NOT cover"
fi
if grep -qF "scheduled-workflow auto-disable" "$WF"; then
  ok "the 60-day scheduled-workflow auto-disable is a STATED residual beside the case it sharpens"
else
  bad "$WF's case table never states the 60-day auto-disable residual — a quiescence-green schedule can go dark unnoticed and unstated"
fi
RC0_ARM="$(grep '^            0)' "$WF" | head -1)"
if [ -z "$RC0_ARM" ]; then
  bad "there is no rc=0 case arm to check — this assertion would be vacuous, so it fails instead"
elif printf '%s' "$RC0_ARM" | grep -q 'QUIET'; then
  ok "the rc-0 arm's own message admits rc 0 carries two shapes — a QUIET WINDOW is not relabelled as a reconciliation"
else
  bad "the rc-0 arm still claims only 'the crown reconciles' — a QUIET WINDOW landing there is silently relabelled as a full reconciliation"
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
#
# MENTION IS NOT EXECUTION — the doctrine shell-harnesses.yml itself states, and
# the one this assertion used to violate. The predicate was a bare
# `grep -q crown-reconcile`, which tested MENTION where its own message claimed
# EXECUTION: it fired on the PROSE COMMENT #11703 (188e226f0a) added at
# shell-harnesses.yml:84, where zero `run:` lines and zero paths entries name
# crown-reconcile and the harness is executed by exactly one workflow (this
# file's two if:-mutually-exclusive jobs). Because this harness is the FIRST
# step of crown-reconcile.yml's product job, that false red skipped the actual
# reconcile step on every push and every ~6h schedule from 2026-08-17T08:30Z —
# the crown-vs-production reconciler, the only instrument that can see
# production serving a sha the platform has no row for, was DARK for ~36h while
# the failure filed to a human named the wrong defect.
#
# The predicate now counts only NON-COMMENT occurrences — deliberately
# conservative (line-oriented, so it can over-red but never under-red) — and it
# earns that tightening in the same breath: the same predicate is re-run against
# a TEMP COPY carrying a PLANTED real wiring, and must still catch it. Without
# that mutation case the tightening would just be the next vacuous guard.
wiring_hits() { grep -vE '^[[:space:]]*#' "$1" | grep -c "crown-reconcile" || true; }
HARNESSES="$REPO_ROOT/.github/workflows/shell-harnesses.yml"
PLANTED="$TMP/shell-harnesses-planted.yml"
if [ ! -f "$HARNESSES" ]; then
  bad "missing $HARNESSES — this assertion would be vacuous, so it fails instead"
else
  { cat "$HARNESSES"; printf '      - "scripts/crown-reconcile.test.sh"\n'; } >"$PLANTED"
  if [ "$(wiring_hits "$HARNESSES")" != "0" ]; then
    bad "crown-reconcile is WIRED in shell-harnesses.yml (a non-comment occurrence) as well as in its own workflow — the harness would run TWICE"
  elif [ "$(wiring_hits "$PLANTED")" = "0" ]; then
    bad "the double-run predicate did not catch the wiring planted in $PLANTED — it can no longer fail, so it fails now"
  else
    ok "crown-reconcile rides its own harness job only — no non-comment occurrence in shell-harnesses.yml, and a planted wiring still trips the predicate"
  fi
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

# ── the script-mutation helper, used by (y) and (z) below ────────────────────
# A copy of crown-reconcile.sh with ONE literal replaced. The copy lives beside a
# symlinked .github so `$REPO_ROOT/.github/workflows/deploy.yml` still resolves —
# a mutation must fail for the reason it names, not because it moved house.
#
# THE MUTATION IS ASSERTED TO HAVE APPLIED, twice over: the anchor must match
# EXACTLY ONE line (an anchor that matched nothing would produce a "red" that is
# really an unchanged script passing an assertion it was always going to pass),
# and the copy must actually DIFFER from the original.
MUTREPO="$TMP/mutrepo"; mkdir -p "$MUTREPO/scripts"
ln -sfn "$REPO_ROOT/.github" "$MUTREPO/.github" 2>/dev/null || true
# Sets MUT_OUT to the copy's path. It does NOT print it: ok()/bad() write to
# stdout, so a `$(mutate_cr …)` would swallow its own verdicts into the path.
MUT_OUT=""
mutate_cr() { # <name> <literal-anchor> <literal-replacement> -> sets MUT_OUT
  local out="$MUTREPO/scripts/cr-$1.sh" n
  n="$(grep -cF -- "$2" "$CR")"
  if [ "$n" = "1" ]; then
    ok "the $1 mutation anchor matches EXACTLY ONE line of the script"
  else
    bad "the $1 mutation anchor matched $n line(s), not 1 — the red it is meant to produce would be a default, not a difference"
  fi
  awk -v a="$2" -v b="$3" '{ i = index($0, a); if (i > 0) { $0 = substr($0, 1, i - 1) b substr($0, i + length(a)) } print }' "$CR" > "$out"
  if cmp -s "$CR" "$out"; then
    bad "the $1 mutation changed NOTHING — the copy is byte-identical to the script"
  else
    ok "the $1 mutation APPLIED — the copy differs from the script"
  fi
  MUT_OUT="$out"
}

section "(n4) THE DEFERRED RE-READ RE-ASKS THE IN-FLIGHT ALIBI THE SERVING ARM GRANTS"
# THE LIVE DEFECT, in fixture form. The SERVING arm defers while
# `serving_run_in_flight` names a non-terminal run for that exact sha; the
# deferred re-read did NOT re-ask it, and skipped only $GRACED_THIS_RUN. So the
# instant the box moved to a newer sha, a graced sha whose own deploy run was
# STILL RUNNING lost its alibi and was accused: 373df8e7a, graced 09:58:01, its
# run 34025636906 in_progress since 09:47:30, fired GRACED-UNRECORDED at
# 11:00:18 — a red at a deploy nobody had finished.
#
# Run 3 is the in-flight deploy for the graced sha. ONE FIELD separates the two
# run pages below (status/conclusion), so the verdict change is that field's and
# nothing else's.
RUNS_N4_FLIGHT="$(runs_add runs-n4-flight "$RUNS_BASE" 3 "$SHA_D" in_progress null "$IN2")"
RUNS_N4_DONE="$(runs_add runs-n4-done "$RUNS_BASE" 3 "$SHA_D" completed failure "$IN2")"
JOBS_N4="$(jobs_legs jobs-n4 "1:success:success" "2:success:success" "3:failure:failure")"
CR_STATE="$TMP/state-reask-inflight.txt"; rm -f "$CR_STATE"
run_cr 4 "run N: $SHA_D is served and unrecorded while its own run 3 is in flight — graced" \
  --runs-fixture "$RUNS_N4_FLIGHT" --jobs-fixture "$JOBS_N4" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
if grep -q "^$SHA_D " "$CR_STATE" 2>/dev/null; then
  ok "the graced sha reached the re-ask list, so the next run has something to re-ask"
else
  bad "the graced sha never reached the re-ask list at $CR_STATE — every arm below would be vacuous"
  [ -f "$CR_STATE" ] && sed 's/^/       | /' "$CR_STATE" >&2
fi

# THE ARM ITSELF: the box has moved on to $SHA_A, so $SHA_D is no longer
# $GRACED_THIS_RUN and reaches the deferred re-read — with its run STILL
# in_progress. It must be HELD (rc 4), not accused.
run_cr 4 "run N+1: the box now serves $SHA_A, and run 3 for the graced $SHA_D is STILL RUNNING" \
  --runs-fixture "$RUNS_N4_FLIGHT" --jobs-fixture "$JOBS_N4" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
not_saw "GRACED-UNRECORDED:" "a deploy nobody has finished is not accused of failing to record"
saw "GRACE HELD" "the deferral is NAMED, not silent"
saw "deploy.yml run 3 for that exact sha is STILL RUNNING" "it names the run that is the alibi"
saw "NOT YET DUE" "and the run exits 4 — not yet due, rather than a page"
if grep -q "^$SHA_D " "$CR_STATE" 2>/dev/null; then
  ok "the held sha STAYS on the re-ask list — a deferral is a debt, not a dismissal"
else
  bad "the held sha was dropped from the re-ask list — the accusation became unmakeable"
fi

# MUTATION: remove the re-ask. The identical fixture must then produce the live
# red, which is what makes the arm above a DIFFERENCE and not a default.
# shellcheck disable=SC2016  # the anchor is a LITERAL of the script's own text; expansion here would aim it at nothing
mutate_cr drop-reask-inflight \
  'if [ -n "$gflight" ] && [ "$gage" -lt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then # MUT:G-REASK-INFLIGHT' \
  'if [ -n "" ] && [ "$gage" -lt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then # MUT:G-REASK-INFLIGHT'
CR_ALT="$MUT_OUT"
run_cr 1 "the SAME in-flight fixture, against a script whose deferred re-read never re-asks" \
  --runs-fixture "$RUNS_N4_FLIGHT" --jobs-fixture "$JOBS_N4" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
CR_ALT=""
saw "GRACED-UNRECORDED: 1 sha(s)" "without the re-ask the in-flight deploy is accused — the live 373df8e7a red, reproduced"
not_saw "GRACE HELD" "…and nothing holds it"

# THE OTHER DIRECTION: the alibi must EXPIRE. Same sha, same list, same crown —
# run 3 is now completed and recorded nothing, so the accusation fires.
run_cr 1 "run N+2: run 3 has finished and $SHA_D still has no cp row" \
  --runs-fixture "$RUNS_N4_DONE" --jobs-fixture "$JOBS_N4" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_BASE"
saw "GRACED-UNRECORDED: 1 sha(s)" "a finished run is no alibi — the deferred accusation fires"
saw "$SHA_D" "it names the sha the earlier runs held"
not_saw "GRACE HELD" "and nothing is held any more"
CR_STATE=""

section "(y) the POPULATION names CANCELLED runs in BOTH directions"
# A cancelled run was never omitted from this population — run_delivers does not
# consult the run's own conclusion — but it was counted ANONYMOUSLY, under a
# parenthetical claiming "delivered nothing" means a docs-only merge. Most of
# that class is a SUPERSEDED PUSH. And the other direction is the dangerous one:
# a run whose leg concluded success and which was then cancelled DELIVERED, with
# its record-delivery job cancelled alongside it — the shape SERVING-UNRECORDED
# came from. One fixture holds one run of each kind, beside an ordinary one.
RUNS_Y="$(runs_json runs-y "$SHA_A:$IN1")"
RUNS_Y="$(runs_add runs-y-cn "$RUNS_Y" 2 "$SHA_B" completed cancelled "$IN2")"
RUNS_Y="$(runs_add runs-y-cd "$RUNS_Y" 3 "$SHA_C" completed cancelled "$IN2")"
# run 2: cancelled before either leg concluded — CANCELLED_NONDELIVERING.
# run 3: the instance leg concluded success and the run was cancelled anyway —
#        CANCELLED_DELIVERING, a delivery whose recorder died with the cancel.
JOBS_Y="$(jobs_legs jobs-y "1:success:success" "2:cancelled:cancelled" "3:cancelled:success")"
CROWN_Y="$(crown_json crown-y \
  "$(row "$SHA_A" cp false "$IN1" 1)" \
  "$(row "$SHA_A" instance false "$IN1" 1)" \
  "$(row "$SHA_C" instance false "$IN2" 3)")"
run_cr 0 "one ordinary run, one cancelled-nondelivering, one cancelled-delivering" \
  --runs-fixture "$RUNS_Y" --jobs-fixture "$JOBS_Y" --crown-fixture "$CROWN_Y" --health-fixture "$HEALTH_BASE"
# THE EXISTING TOTALS ARE UNCHANGED BY THE SPLIT — this is the half that keeps
# the new clause from being paid for with a moved denominator.
saw "POPULATION: 3 completed deploy.yml run(s)" "all three runs are still in the population"
saw "2 of them DELIVERED" "the cancelled-but-delivering run is still counted as DELIVERING"
saw "1 delivered nothing" "the cancelled-before-any-leg run is still counted as NONDELIVERING"
saw "1 were CANCELLED_NONDELIVERING" "the superseded push is named, not pooled under 'a docs-only merge'"
saw "1 of the 2 that DELIVERED are CANCELLED_DELIVERING" "the delivered-then-cancelled run is named in the OTHER direction too"

# NON-VACUITY: an ordinary window with NO cancelled run prints the clause with
# zeroes, so the two counts above are a measurement and not a constant.
run_cr 0 "the base window, where nothing was cancelled" $(base_args)
saw "0 were CANCELLED_NONDELIVERING" "with nothing cancelled the count is 0, so the arm above measured something"
saw "0 of the 2 that DELIVERED are CANCELLED_DELIVERING" "…in both directions"

# MUTATION: drop the split. The clause is the only place these two classes are
# ever said, so silencing its `say` is exactly "the split was dropped".
# shellcheck disable=SC2016  # the anchor is a LITERAL of the script's own text; expansion here would aim it at nothing
mutate_cr drop-cancelled-split \
  'say "  CANCELLED, NAMED IN BOTH DIRECTIONS:' \
  ': "  CANCELLED, NAMED IN BOTH DIRECTIONS:'
CR_ALT="$MUT_OUT"
run_cr 0 "the same fixture, against a script whose split was dropped" \
  --runs-fixture "$RUNS_Y" --jobs-fixture "$JOBS_Y" --crown-fixture "$CROWN_Y" --health-fixture "$HEALTH_BASE"
CR_ALT=""
not_saw "CANCELLED_NONDELIVERING" "without the split the superseded push is anonymous again — the assertions above are differences, not defaults"
not_saw "CANCELLED_DELIVERING" "…and so is the delivered-then-cancelled run"

section "(z) the run listing PAGES to the window start — 101 rows is a COUNT, not a floor"
# `per_page=100` with no `page=` was ONE page read as if it were the 24h window,
# and it was short on 7 of 24 active days in the 30-day sample (2026-09-02: 246
# runs). fetch_runs now pages. A fixture is one file and cannot page, so it
# states for itself whether the listing it stands for reached the window start:
# WITHOUT `"truncated": true` a 101-row fixture is the WHOLE listing.
runs_bulk() { # <name> <first-id> <count> <sha:created> <filler-sha> <filler-created> <truncated:true|false>
  local out="$TMP/$1.json" base="$2" count="$3" fsha="$5" fcreated="$6" trunc="$7"
  local a="${4%%:*}" acr="${4#*:}"
  {
    printf '{'
    [ "$trunc" = "true" ] && printf '"truncated":true,'
    printf '"workflow_runs":['
    printf '{"id":%d,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"}' "$base" "$a" "$acr"
    local i=1
    while [ "$i" -lt "$count" ]; do
      printf ',{"id":%d,"head_sha":"%s","conclusion":null,"status":"in_progress","created_at":"%s"}' \
        "$((base + i))" "$fsha" "$fcreated"
      i=$((i + 1))
    done
    printf ']}'
  } > "$out"
  fixture_ok "$out"
  echo "$out"
}
# 101 runs, every one of them created INSIDE the window, oldest still newer than
# the cutoff — the exact shape that used to print `+` on row count alone.
RUNS_Z_WHOLE="$(runs_bulk runs-z-whole 700 101 "$SHA_A:$IN1" "$SHA_D" "$IN2" false)"
RUNS_Z_SHORT="$(runs_bulk runs-z-short 700 101 "$SHA_A:$IN1" "$SHA_D" "$IN2" true)"
JOBS_Z="$(jobs_json jobs-z "700:success")"
CROWN_Z="$(crown_json crown-z \
  "$(row "$SHA_A" cp false "$IN1" 700)" \
  "$(row "$SHA_A" instance false "$IN1" 700)")"
if [ "$(jq '.workflow_runs | length' "$RUNS_Z_WHOLE")" -ge 101 ]; then
  ok "the fixture really holds 101+ runs inside the window — more than one page"
else
  bad "the (z) fixture holds fewer than 101 runs, so it cannot exercise the page boundary at all"
fi
run_cr 0 "101 runs in the window, listing complete" \
  --runs-fixture "$RUNS_Z_WHOLE" --jobs-fixture "$JOBS_Z" --crown-fixture "$CROWN_Z" --health-fixture "$HEALTH_BASE"
not_saw "TRUNCATION RESIDUAL" "a listing that reached the window start states no residual"
not_saw "is a FLOOR" "…and does not call its population a floor"
saw "POPULATION: 1 completed deploy.yml run(s)" "the population is a COUNT — no plus sign on 101 rows"

# ONE DIFFERENCE: the same 101 rows, from a listing that stopped SHORT. The floor
# language is not deleted, it is confined to the case that really is one.
run_cr 0 "the same 101 runs, from a listing that stopped short of the window start" \
  --runs-fixture "$RUNS_Z_SHORT" --jobs-fixture "$JOBS_Z" --crown-fixture "$CROWN_Z" --health-fixture "$HEALTH_BASE"
saw "POPULATION: 1+ completed deploy.yml run(s)" "a listing that stopped short still prints its population as N+"
saw "TRUNCATION RESIDUAL" "…and still states the residual, naming the oldest run id it examined"
saw "the BEHIND denominator above is a floor" "…and still labels the BEHIND denominator a floor"

# MUTATION: key the floor on row count again, the way one page did. The COMPLETE
# listing then lies about itself.
# shellcheck disable=SC2016  # the anchor is a LITERAL of the script's own text; expansion here would aim it at nothing
mutate_cr floor-on-row-count \
  '[ "${RUNS_LIST_COMPLETE:-1}" != "1" ]' \
  '[ "${PAGE_ROWS:-0}" -ge 100 ]'
CR_ALT="$MUT_OUT"
run_cr 0 "the COMPLETE 101-run listing, against a script that keys the floor on row count" \
  --runs-fixture "$RUNS_Z_WHOLE" --jobs-fixture "$JOBS_Z" --crown-fixture "$CROWN_Z" --health-fixture "$HEALTH_BASE"
CR_ALT=""
saw "POPULATION: 1+ completed deploy.yml run(s)" "row-count keying calls a whole listing a floor — which is the bug, and proves the arm above is a difference"

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

section "(q2) the WATERMARK is STATED in the script, not only implemented"
# The exclusion above is the only place this verdict declines to judge a row it
# can see. A rule like that must be readable without reverse-engineering a
# while-loop, and it must not be quietly relaxed into a tolerance later.
for phrase in "THE TWO SIDES ARE SAMPLED APART IN TIME" "A TOLERANCE WAS THE WRONG FIX" \
              "WRITTEN-IN-FLIGHT" "clock-free" "MAX_RUN_ID" \
              "THE OTHER SIDE IS ALREADY CONSISTENT" \
              "TRUNCATION CANNOT BE ALLOWED TO MANUFACTURE A GHOST" \
              "A HUNG RUN IS NOT AN ALIBI, AND THE EXCLUSION IS CAPPED"; do
  if grep -qF "$phrase" "$CR"; then ok "the header states: $phrase"; else bad "the header never states '$phrase' — the watermark would be undocumented"; fi
done
# The two live sightings are the evidence for the diagnosis, and a header that
# loses them loses the reason this class is excluded at all.
for evid in "31339252774" "32726853411" "32726835915" "32726853417"; do
  if grep -qF "$evid" "$CR"; then ok "the header keeps the measured run id $evid"; else bad "the header dropped run $evid — the diagnosis loses its evidence"; fi
done
# The gap dial must be reachable ONLY from a fixture run. A live caller that
# could pin the watermark holds a tolerance, which is what this fix refuses.
if grep -qF 'RUNLIST_AT_OVERRIDE" ] && [ "$FIXTURE_MODE" != "1" ]' "$CR"; then
  ok "--runlist-at is guarded to fixture mode in the script itself"
else
  bad "--runlist-at is no longer fenced to fixture mode — a live run could pin its own watermark"
fi
# The watermark must be taken FROM THE RUN LIST'S OWN INSTANT, not from `now`
# further down: an assignment that drifted below the jobs-API leg would restore
# the tear while every probe above still passed.
if [ "$(awk '/^fetch_runs$/ {f=NR} /^RUNLIST_ISO=/ {print NR - f; exit}' "$CR")" -lt 20 ]; then
  ok "the watermark is taken within a few lines of fetch_runs, where the run side is actually frozen"
else
  bad "the watermark assignment drifted away from fetch_runs — it would no longer name the instant the run list was sampled"
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
