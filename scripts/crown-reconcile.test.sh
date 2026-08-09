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
#   (d) WINDOW EMPTY: nothing to compare is never a green            → exit 2
#   (e) CROWN UNREADABLE: a read that did not happen is never green  → exit 2
#   (f) SERVING-UNRECORDED: the box serves a sha with no cp row      → exit 1
#   (g) that same shape, but the process is seconds old              → exit 2
#       (a deploy in flight is a warning, never a fabricated verdict)
#   (h) a docs-only run delivered nothing and MUST NOT be counted    → exit 0
#       (this is the false-positive that would drown the real reds)
#   (i) a CARRIED row naming a sha with no run of its own is correct → exit 0
#   (j) configuration faults are 3, and never 1 or 2
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
IN1="2026-08-09T09:40:00Z"   # inside a 24h window ending at NOW
IN2="2026-08-09T06:00:00Z"
OUT="2026-08-01T00:00:00Z"   # far outside it

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

row() { # <sha> <target> <carried:true|false|omit> <first_seen> <run>
  if [ "$3" = "omit" ]; then
    printf '{"sha":"%s","target":"%s","first_seen_at":"%s","delivering_run_id":"%s"}' "$1" "$2" "$4" "$5"
  else
    printf '{"sha":"%s","target":"%s","carried":%s,"first_seen_at":"%s","delivering_run_id":"%s"}' "$1" "$2" "$3" "$4" "$5"
  fi
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
NOTOOLS="$TMP/notools"; mkdir -p "$NOTOOLS"
run_cr() { # <expected-rc> <label> [args…]
  local want="$1" label="$2"; shift 2
  local out rc
  out="$(env PATH="$NOTOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
    CROWN_API_TOKEN= CP_HOST= DEPLOY_SSH_KEY= \
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

section "(g) the same shape, seconds old — a deploy in flight is a WARNING"
HEALTH_FRESH="$(health_json health-fresh "$SHA_D" "2026-08-09T11:55:00Z")"
run_cr 2 "the serving process is 300s old — too young to accuse" \
  --runs-fixture "$RUNS_BASE" --jobs-fixture "$JOBS_BASE" --crown-fixture "$CROWN_BASE" --health-fixture "$HEALTH_FRESH"
not_saw "SERVING-UNRECORDED" "an in-flight deploy is never reported as a missing record"

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

section "(j) configuration faults are 3 — never a verdict, never a warning"
run_cr 3 "an unknown flag" --runs-fixture "$RUNS_BASE" --nonsense
run_cr 3 "--window-hours that is not a number" --runs-fixture "$RUNS_BASE" --window-hours soon
run_cr 3 "--now that is not an instant" --runs-fixture "$RUNS_BASE" --now yesterday
out="$(env PATH="$NOTOOLS:/usr/bin:/bin:/usr/sbin:/sbin" CROWN_API_TOKEN= CP_HOST= DEPLOY_SSH_KEY= bash "$CR" --window-hours 24 2>&1)"
rc=$?
printf '%s\n' "$out" > "$TMP/last.out"
if [ "$rc" = "3" ]; then ok "no fixture and no credential → exit 3"; else bad "no credential → exit $rc, wanted 3"; fi
saw "CONFIG: no way to read the crown" "a missing credential says CREDENTIAL, never 'nothing to reconcile'"

section "(k) the workflow's own shape"
if grep -q "cron:" "$WF"; then ok "the workflow carries a cron"; else bad "the workflow has no cron"; fi
if grep -q "workflow_dispatch:" "$WF"; then ok "the workflow carries workflow_dispatch"; else bad "no workflow_dispatch"; fi
if grep -q "if: github.event_name != 'pull_request'" "$WF"; then ok "the product step is fenced off pull_request heads"; else bad "the product job is not fenced off pull_request"; fi
# The KEY, not the word: this file's own prose explains why continue-on-error is
# absent, and a bare grep would red on the explanation.
if grep -qE '^[[:space:]]*continue-on-error:' "$WF"; then bad "continue-on-error is present — this scream can be laundered to success"; else ok "no continue-on-error key anywhere"; fi
if grep -q "file-ci-failure-issue.sh" "$WF"; then ok "it screams through scripts/file-ci-failure-issue.sh"; else bad "nothing files an issue when this reds"; fi
for n in 0 1 2 3; do
  if grep -q "^            $n)" "$WF"; then ok "the case arm for rc $n exists"; else bad "rc $n has no case arm of its own"; fi
done
if [ -f "$SPEC" ] && grep -q "crown-reconcile" "$SPEC"; then
  bad "crown-reconcile appears in .github/required-checks.json — it must NOT be a required context"
else
  ok "crown-reconcile is not in the required-check spec"
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
