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
#   (g) that same shape, but the process is seconds old              → exit 2
#       (a deploy in flight is a warning, never a fabricated verdict)
#   (h) a docs-only run delivered nothing and MUST NOT be counted    → exit 0
#       (this is the false-positive that would drown the real reds)
#   (i) a CARRIED row naming a sha with no run of its own is correct → exit 0
#   (j) configuration faults are 3, and never 1 or 2
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
