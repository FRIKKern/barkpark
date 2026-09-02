#!/usr/bin/env bash
# bp-merge.test.sh — the refusal-string table, driven over CAPTURED fixtures.
#
# NO LIVE GITHUB. Every string below was captured verbatim on a freshly
# protected throwaway base (honest-gates D17, D38, D54) and is quoted here as a
# fixture. The harness sources scripts/bp-merge.sh with BP_MERGE_LIB=1, which
# stops before resolve_pr(), so nothing in this file can reach the network — a
# harness that needs credentials is a harness CI will eventually skip.
#
# WHY A HARNESS AT ALL (D26): a harness nobody runs is not a ratchet, and a
# classifier is exactly the shape that silently rots — GitHub owns these
# strings, and the day one of them changes the table must red HERE, loudly,
# rather than mis-classify a red PR as green in a builder's terminal.
#
# THE CASE THIS FILE EXISTS FOR is the last one: an UNRECOGNISED string must
# REFUSE. A parser that assumes green on an unknown message is the vacuous pass
# this whole epic exists to abolish.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
BP_MERGE_LIB=1 . "$ROOT/scripts/bp-merge.sh"

pass=0; fail=0

check() { # label expected_state fixture
  local label="$1" want="$2" fixture="$3" got
  got="$(classify_refusal "$fixture")"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "  ok   $label -> $got"
  else
    fail=$((fail + 1))
    echo "  FAIL $label: expected $want, got $got" >&2
    printf '       fixture: %s\n' "$fixture" >&2
  fi
}

advice_contains() { # label state needle [run_id]
  local label="$1" state="$2" needle="$3" out
  out="$(refusal_advice "$state" 123 deadbeef "${4:-}")"
  case "$out" in
    *"$needle"*) pass=$((pass + 1)); echo "  ok   $label" ;;
    *) fail=$((fail + 1))
       echo "  FAIL $label: advice for $state does not contain '$needle'" >&2
       printf '%s\n' "$out" | sed 's/^/       /' >&2 ;;
  esac
}

echo "── bp-merge refusal table: captured fixtures, no live GitHub ──"

# ── the six measured arms ────────────────────────────────────────────────────

# D17, captured verbatim: gh surfaces the GraphQL error text for a RED required
# context under enforce_admins:true.
check "1  singular RED (D17 verbatim)" RED \
  'GraphQL: Required status check "probe-will-fail" is failing.'

# D38 row 1. Under strict:false this is unambiguous: the context never rendered.
check "2  singular UNREPORTED = DEADLOCK (D38)" DEADLOCK \
  'GraphQL: Required status check "Elixir gate" is expected.'

# D38's third conclusion — blocks with neither "is failing." nor "is expected."
check "3  singular CANCELLED = RE-RUN (D38)" RERUN \
  'GraphQL: Required status check "PR references an active task" is cancelled.'

# D54's seventh shape, ABSENT from D38 and the single most common real state.
# A parser derived from D38 alone classifies this UNRECOGNISED; this row is the
# reason the table was re-measured.
check "4  singular IN PROGRESS = WAIT (D54; absent from D38)" WAIT \
  'GraphQL: Required status check "Elixir gate" is in progress.'

# D38 plural forms. Counts and CATEGORIES, never names.
check "5  plural both unreported (D38)" PLURAL \
  'GraphQL: 2 of 2 required status checks are expected.'
check "6  plural both red — must NOT be read as singular RED (D38)" PLURAL \
  'GraphQL: 2 of 2 required status checks are failing.'
check "7  plural mixed (D38)" PLURAL \
  'GraphQL: 2 of 2 required status checks have not succeeded: 1 expected and 1 failing.'

# D54 row 7: the categories DO NOT SUM. `total - named == 0` mis-handles this.
check "8  plural whose categories DO NOT SUM (D54)" PLURAL \
  'GraphQL: 2 of 2 required status checks have not succeeded: 1 expected.'

# gh's own client-side block: the merge API was never called.
check "9  gh CLIENT-side block (D54)" CLIENT_BLOCK \
  'X Pull request FRIKKern/barkpark#6414 is not mergeable: the base branch policy prohibits the merge.'

# ── the default arm: the whole point ─────────────────────────────────────────
check "10 an UNKNOWN string REFUSES, never assumes green" UNRECOGNISED \
  'GraphQL: Required status check "Elixir gate" is in some state GitHub invented last Tuesday.'
check "11 an EMPTY message REFUSES" UNRECOGNISED ''
check "12 an unrelated gh error REFUSES" UNRECOGNISED \
  'failed to run git: exit status 128'

# A green merge prints a SUCCESS line, and the classifier must never be handed
# one — but if it ever is, the honest answer is still "I do not recognise this".
check "13 a success line is NOT silently treated as mergeable" UNRECOGNISED \
  'Merged pull request #6414 (fix(papers): preserve list semantics)'

# ── each arm names exactly one resolving command ─────────────────────────────
advice_contains "14 DEADLOCK advice names the detector"      DEADLOCK     'required-checks-verify.sh --deadlock'
advice_contains "15 PLURAL advice falls through to the detector (D38: the only way to get a NAME)" \
                                                             PLURAL       'required-checks-verify.sh --deadlock'
advice_contains "16 RED advice says RE-RUN FIRST before reading code (D57)" RED 'RE-RUN FIRST, BEFORE reading any code'
advice_contains "17 RED advice cites the laundering decision"  RED         'D57'
advice_contains "18 RERUN advice names a re-run command"       RERUN       'gh run rerun'
advice_contains "19 WAIT advice names a watch command"         WAIT        'gh pr checks'
advice_contains "20 UNRECOGNISED advice refuses LOUDLY"        UNRECOGNISED 'refuses to guess'
advice_contains "21 CLIENT_BLOCK advice says the API was never reached" CLIENT_BLOCK 'never called'
# D79. CLIENT_BLOCK is the DOMINANT arm the moment protection lands — gh refuses
# locally on `mergeStateStatus: BLOCKED` and never calls the merge API — and it
# used to offer a JSON dump instead of a resolving command. A rollup lists every
# check on the head, advisory ones included, and cannot tell you which of them
# the BRANCH requires; only the set difference against the committed spec can.
advice_contains "21b CLIENT_BLOCK advice names the RESOLVING command, like every other arm (D79)" \
                                                             CLIENT_BLOCK 'required-checks-verify.sh --deadlock'

# ── hgw4: the RED/RERUN advice interpolates a REAL run id when the caller
# resolved one, and degrades to the placeholder + lookup command when it could
# not. refusal_advice() itself stays pure — the id arrives as $4, resolved by
# refuse() via gh; an empty $4 must never render a wrong id.
advice_contains "22 RED advice interpolates a supplied run id"    RED   'gh run rerun --failed 987654321' 987654321
advice_contains "23 RERUN advice interpolates a supplied run id"  RERUN 'gh run rerun --failed --repo FRIKKern/barkpark 987654321' 987654321
advice_contains "24 RED advice without an id keeps the placeholder + lookup" RED   'gh run rerun --failed <run-id>'
advice_contains "25 RED placeholder path names where to look the id up"      RED   'gh pr checks 123  prints the run links'
advice_contains "26 RERUN advice without an id keeps the placeholder"        RERUN 'gh run rerun --failed --repo FRIKKern/barkpark <run-id>'

# ── the counter-line: bp-merge's own refusal must not re-teach the dead verb ──
# D78. gh quotes its own suggestion to override the branch policy whenever
# viewerCanAdminister is true, which is every agent in this fleet. The verbatim
# quote stays — it is the wrapper's whole promise — so the correction has to sit
# beneath it, or the evidence artifact this epic produces teaches the abolished
# verb in gh's voice.
CB_FIXTURE='X Pull request FRIKKern/barkpark#6414 is not mergeable: the base branch policy prohibits the merge.
Try running: gh pr merge --squash --admin  # add the --admin flag to override and merge now'
out="$(counter_line "$CB_FIXTURE")"
if printf '%s' "$out" | grep -q 'DEAD'; then
  pass=$((pass + 1)); echo "  ok   21c refuse() prints a counter-line when gh suggests the admin override (D78)"
else
  fail=$((fail + 1)); echo "  FAIL no counter-line for a gh message carrying the admin-override hint" >&2
fi
if printf '%s' "$out" | grep -q "merge verb is this script"; then
  pass=$((pass + 1)); echo "  ok   21d …and it POINTS somewhere (the artifact), rather than only saying no"
else
  fail=$((fail + 1)); echo "  FAIL the counter-line does not point at the replacement verb" >&2
fi
# A message that never mentioned an override gets no lecture — a wrapper that
# argues with things gh did not say is noise, and noise is how a real refusal
# gets skimmed past.
if [ -z "$(counter_line 'GraphQL: Required status check "Elixir gate" is in progress.')" ]; then
  pass=$((pass + 1)); echo "  ok   21e …and stays SILENT on a message that never suggested an override"
else
  fail=$((fail + 1)); echo "  FAIL the counter-line fires on a message that mentioned no override" >&2
fi
# And it must be reachable from refuse(): a counter-line nothing calls is a
# comment. Asserted structurally, because refuse() exits and cannot be driven
# from this harness.
if grep -q 'counter_line "\$msg"' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   21f refuse() actually calls counter_line (not a dead helper)"
else
  fail=$((fail + 1)); echo "  FAIL counter_line is defined but refuse() never calls it" >&2
fi
# The verbatim quote is NOT filtered. If refuse() ever starts editing gh's
# message, the wrapper is lying about what GitHub said.
if grep -q "gh said, verbatim" "$ROOT/scripts/bp-merge.sh" \
   && ! grep -qE 'msg.*\|.*(sed .*s/--admin|grep -v)' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   21g gh's message is still quoted VERBATIM — countered beneath, never edited"
else
  fail=$((fail + 1)); echo "  FAIL refuse() filters gh's message instead of countering it" >&2
fi

# ── the merge that LANDED and still exited non-zero ──────────────────────────
# Measured on this script's own first live merge (PR #6924, mergedAt
# 2026-07-28T22:54:25Z): `gh pr merge --squash --delete-branch` merged
# server-side and then exited 1 because `--delete-branch` tries to check the
# base branch out locally, and `main` is permanently checked out by the primary
# worktree in this fleet. The classifier answered UNRECOGNISED — the honest
# answer for an unmeasured string, and still a FALSE STALL that would fire on
# every successful merge here. The table is deliberately NOT extended with this
# string: whether a merge landed is a question for the API, not for a grep.
check "28 gh's local post-merge failure is UNRECOGNISED, not a silent green" UNRECOGNISED \
  "failed to run git: fatal: 'main' is already checked out at '/Volumes/SATECHI/github/barkpark'"
# 34-39. THE SECOND POST-MERGE LOCAL SHAPE, measured twice on this fleet on
# 2026-09-02. gh runs its branch-delete AFTER the merge call returned, so this
# string can only ever be emitted about a merge that already went to the server.
# It is git refusing to delete a branch some OTHER worktree has checked out —
# the normal resting state of a fleet where every agent works in its own
# worktree. Row 28's sibling arrives when the CHECKOUT step fails; this one
# arrives when the checkout is not needed and the DELETE is the failing step.
#
# Row 28 keeps UNRECOGNISED deliberately and stays exactly as it is. What earns
# this shape a token is the ADVICE: UNRECOGNISED tells the reader to run
# `gh pr merge --squash --delete-branch` by hand, and on this shape that is an
# instruction to re-merge a PR that is already merged.
#
# Captured by the reporting lead; the path is elided exactly as they quoted it.
check "34 gh's local BRANCH-DELETE failure is a POST-MERGE shape, not an unknown refusal" LOCAL_POST_MERGE \
  "failed to delete local branch gates/reland-extractor: failed to run git: error: Cannot delete branch 'gates/reland-extractor' checked out at '/…/orchestrate/wt/gates-reland-extractor'"
# The same shape with a full path: git's half reproduced verbatim in a worktree
# of this repo, wrapped in gh's own `failed to delete local branch %s: %w`
# format — read out of the gh 2.87.2 binary, so the wrapper text is not a guess.
check "35 …and with a full worktree path" LOCAL_POST_MERGE \
  "failed to delete local branch gates/bp-merge-shape: failed to run git: error: Cannot delete branch 'gates/bp-merge-shape' checked out at '/Volumes/SATECHI/dev-caches/tmp/scratchpad/orchestrate/wt/gates-bp-merge-shape'"
# THE MATCH IS NARROW ON PURPOSE: it needs BOTH needles. A branch-delete that
# failed for any other reason is not a worktree collision and must keep
# refusing. Widening this to every `failed to run git` would make the arm the
# message-shaped guess about whether a merge landed that this script refuses.
check "36 a branch-delete failure that is NOT a worktree collision still REFUSES" UNRECOGNISED \
  "failed to delete local branch gates/gone: failed to run git: error: branch 'gates/gone' not found."
check "37 …and a bare git failure still REFUSES" UNRECOGNISED \
  'failed to run git: exit status 129'
# Captured verbatim from two runs on 2026-09-02 (PRs #14899 and #14892). A REAL
# refusal — the merge did NOT land, main moved under the head — pinned here so
# the shape is on the record and any future arm for it is a deliberate edit
# rather than a silent reclassification.
check "38 'Base branch was modified' is a REAL refusal and stays UNRECOGNISED" UNRECOGNISED \
  'GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'
advice_contains "39 LOCAL_POST_MERGE advice names the CONFIRM command, never a re-merge" \
                LOCAL_POST_MERGE 'gh pr view 123 --json state,mergedAt'
advice_contains "39b …and says the local step ran after the merge call" \
                LOCAL_POST_MERGE 'AFTER the merge call returned'
advice_contains "39c …and says NOT to re-merge on this message alone" \
                LOCAL_POST_MERGE 'do NOT re-merge'

# 40-42. THE LANDED-CHECK CAN GO BLIND, and a blind read must not read as "not
# merged". `gh pr view --json state` fails outright under a rate limit —
# measured on this fleet on 2026-09-02, "API rate limit already exceeded for
# user ID …" — and pr_state() then answers UNKNOWN, which merged_despite_error
# treats exactly like OPEN. That is the false stall returning through the
# instrument rather than through the table, so the refusal must SAY the read
# failed instead of sounding as confident as a read one.
# DRIVEN, not grepped: gh is STUBBED here, so the reader runs for real without a
# network. A failing read must answer UNKNOWN and KEEP what the API said.
gh() { echo "GraphQL: API rate limit already exceeded for user ID 32601161." >&2; return 1; }
# shellcheck disable=SC2034  # read by pr_state(), which is sourced from bp-merge.sh
PR_NUMBER=123
PR_STATE_READ=""; PR_STATE_ERROR=""
pr_state
blind_ok=0
case "$PR_STATE_ERROR" in *"rate limit already exceeded"*) blind_ok=1 ;; esac
if [ "$PR_STATE_READ" = "UNKNOWN" ] && [ "$blind_ok" -eq 1 ]; then
  pass=$((pass + 1)); echo "  ok   40 a FAILED state read answers UNKNOWN and keeps what the API said"
else
  fail=$((fail + 1))
  echo "  FAIL a failed state read lost the error (state='$PR_STATE_READ' err='$PR_STATE_ERROR')" >&2
fi
# And a read that WORKS must answer the state and clear any stale error.
gh() { printf 'MERGED\n'; }
pr_state
if [ "$PR_STATE_READ" = "MERGED" ] && [ -z "$PR_STATE_ERROR" ]; then
  pass=$((pass + 1)); echo "  ok   40a …and a successful read answers the state and clears the error"
else
  fail=$((fail + 1))
  echo "  FAIL a successful state read is wrong (state='$PR_STATE_READ' err='$PR_STATE_ERROR')" >&2
fi
unset -f gh
unset PR_NUMBER
# THE SUBSHELL TRAP, asserted structurally because it cannot be observed from
# outside: `X="$(pr_state)"` runs the reader in a SUBSHELL, so PR_STATE_ERROR
# would be assigned and then thrown away — the refusal would silently go back to
# sounding as confident as a read one, with every row above still green.
# Read over EXECUTABLE lines only, and matched with `case` rather than a pipe
# into `grep -q`: the comment right above the call site names the very form it
# forbids, and a gate that reds on its own explanation teaches people to delete
# the explanation.
bpm_code="$(grep -vE '^[[:space:]]*#' "$ROOT/scripts/bp-merge.sh")"
case "$bpm_code" in
  *'$(pr_state)'*)
    fail=$((fail + 1))
    echo "  FAIL pr_state is called in a command substitution — PR_STATE_ERROR dies in the subshell" >&2 ;;
  *)
    pass=$((pass + 1))
    echo "  ok   40b the reader is never called in a command substitution, which would discard its globals" ;;
esac
if grep -q 'PR_STATE_READ" = "UNKNOWN"' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   41 refuse() checks whether the landed-check could read the state at all"
else
  fail=$((fail + 1)); echo "  FAIL refuse() cannot tell a CONFIRMED-open PR from an unreadable one" >&2
fi
if grep -q 'the landed-check could NOT read the PR state' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   42 …and says so, quoting what the API answered instead"
else
  fail=$((fail + 1)); echo "  FAIL a blind landed-check is silent — the refusal looks as confident as a read one" >&2
fi

if grep -q 'merged_despite_error "\$out"' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   29 merge_loop asks the API whether the PR MERGED before classifying any string"
else
  fail=$((fail + 1)); echo "  FAIL merge_loop classifies the message without first reading the PR state" >&2
fi
# And the state check must run BEFORE classify_refusal, or the false stall
# survives: the string would be classified and refuse() would exit 1 first.
if awk '/merged_despite_error "\$out"/ {seen=1} /state="\$\(classify_refusal/ {print (seen ? "OK" : "LATE"); exit}' \
     "$ROOT/scripts/bp-merge.sh" | grep -q OK; then
  pass=$((pass + 1)); echo "  ok   30 …and it does so BEFORE classify_refusal, or the refusal would exit first"
else
  fail=$((fail + 1)); echo "  FAIL the state read happens after classification — the false stall survives" >&2
fi
# The comparison moved from an inlined `$(pr_state)` to the RECORDED read (rows
# 40-42: a read that failed must be distinguishable from a PR the API said is
# OPEN), so all three halves are asserted — the reader exists, it asks the API
# for `state`, and the landed-decision is made against what it answered.
if grep -q 'pr_state() {' "$ROOT/scripts/bp-merge.sh" \
   && grep -qF -- 'gh pr view "$PR_NUMBER" --json state' "$ROOT/scripts/bp-merge.sh" \
   && grep -q '\[ "\$PR_STATE_READ" = "MERGED" \]' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   31 the landed-check reads STATE from the API, never a message shape"
else
  fail=$((fail + 1)); echo "  FAIL the landed-check is not a state read" >&2
fi
# 32/33. THE ONLY WRITE THIS SCRIPT PERFORMS is the remote head-branch delete on
# the landed-despite-error path, and `headRefName` is a bare branch name that
# carries no repository. Addressed to the BASE repo, a fork PR's head name
# resolves to a DIFFERENT branch here — so the delete must be fenced on
# `isCrossRepository == false` and must never target the base branch. Asserted
# structurally because the path needs a real merged PR to drive.
# The field name is anchored on a NON-IDENTIFIER boundary: a bare
# `grep -q isCrossRepository` also matches `isCrossRepositoryX`, so renaming the
# field to something gh does not serve would have left this assertion green —
# the vacuous pass this harness exists to refuse.
if grep -qE -- '--json isCrossRepository( |$)' "$ROOT/scripts/bp-merge.sh" \
   && grep -qE -- "--jq '\.isCrossRepository'" "$ROOT/scripts/bp-merge.sh" \
   && grep -q '\[ "\$cross" != "false" \]' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   32 the head-branch delete is fenced on isCrossRepository (a fork's head name is another branch here)"
else
  fail=$((fail + 1)); echo "  FAIL the head-branch delete is unfenced — a fork PR would delete a same-named branch in THIS repo" >&2
fi
if grep -q '\[ "\$head" = "\$base" \]' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   33 …and it refuses when head and base are the same branch"
else
  fail=$((fail + 1)); echo "  FAIL nothing stops the delete from targeting the base branch" >&2
fi

# ── the two flags this repo's merge protocol must stop using ─────────────────
# Comments may DISCUSS them; no executable line may emit them. `--admin` bypasses
# the protection this epic installs, and `--auto` merges unattended while
# allow_auto_merge stays FALSE (D53).
code_only() { grep -vE '^[[:space:]]*#' "$ROOT/scripts/bp-merge.sh"; }
for flag in "--admin" "--auto"; do
  n="$(code_only | grep -c -- "$flag" || true)"
  if [ "$n" -eq 0 ]; then
    pass=$((pass + 1)); echo "  ok   22/23 no executable line in bp-merge.sh emits $flag"
  else
    fail=$((fail + 1)); echo "  FAIL bp-merge.sh has $n executable line(s) carrying $flag" >&2
    code_only | grep -n -- "$flag" >&2
  fi
done

# ── the artifact is a WRAPPER, and says so ───────────────────────────────────
for needle in "THIN WRAPPER AND NEVER A REQUIRED DEPENDENCY" "gh pr merge --squash"; do
  if grep -qF "$needle" "$ROOT/scripts/bp-merge.sh"; then
    pass=$((pass + 1)); echo "  ok   24 header states the graceful-degradation contract ($needle)"
  else
    fail=$((fail + 1)); echo "  FAIL header is missing '$needle' (D55)" >&2
  fi
done

# ── the pre-flight is DELEGATED, never reimplemented (D14) ───────────────────
if grep -qE '"\$VERIFY" --deadlock' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   25 pre-flight CALLS required-checks-verify.sh --deadlock"
else
  fail=$((fail + 1)); echo "  FAIL pre-flight does not shell out to the existing detector (D14)" >&2
fi
if bash -n "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   26 bp-merge.sh parses"
else
  fail=$((fail + 1)); echo "  FAIL bp-merge.sh does not parse" >&2
fi
# Argument-free: any argument other than --help is refused.
out="$(bash "$ROOT/scripts/bp-merge.sh" 6414 2>&1)" && rc=0 || rc=$?
if [ "${rc:-0}" -ne 0 ] && printf '%s' "$out" | grep -q 'takes NO arguments'; then
  pass=$((pass + 1)); echo "  ok   27 the command is argument-free and says so"
else
  fail=$((fail + 1)); echo "  FAIL passing an argument was not refused (rc=${rc:-0}): $out" >&2
fi

echo
echo "bp-merge harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "HARNESS OK — every arm of the refusal table is exercised, and an unknown string refuses."
