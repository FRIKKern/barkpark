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
# Captured verbatim from two runs on 2026-09-02 (PRs #14899 and #14892) and
# twice more on 2026-09-13 (the api and studio lanes). It IS a real refusal —
# the merge did not land — and it is also TRANSIENT: on 2026-09-13 a by-hand
# retry merged first try in BOTH cases, because the base simply moved between
# GitHub's mergeability snapshot and its write. This row previously asserted
# UNRECOGNISED, and that was the right SHAPE with the wrong COVERAGE: it made
# every lane resolve a named, safe-to-retry-once condition by hand. Rows 52-58
# drive the bounded retry end to end. Changing this row is the deliberate edit
# the old comment asked for.
check "38 'Base branch was modified' is NAMED BASE_MODIFIED, not UNRECOGNISED (measured 2026-09-13)" BASE_MODIFIED \
  'GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'
# THE NEEDLE IS NOT WIDENED. The retry is a WRITE; any other "was modified"
# message is an unmeasured shape and must keep refusing, or the arm becomes a
# message-shaped guess about which writes are safe to repeat.
check "38a a different 'was modified' message is NOT the retry arm" UNRECOGNISED \
  'GraphQL: The head ref was modified since the last review. (mergePullRequest)'
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

# A pipeline into `grep -q` is the 141 hazard this repo scans for: grep exits on
# the FIRST match, the producer takes SIGPIPE, and under `set -o pipefail` a TRUE
# assertion comes back FAILED — precisely under the load that makes the output
# long, which is the refusal blocks below. `case` reads the whole string with no
# pipe at all. (scripts/pipefail-sigpipe-scan.sh names the shape.)
out_has() { # haystack needle
  case "$1" in
    *"$2"*) return 0 ;;
    *)      return 1 ;;
  esac
}

# ── 43-51. THE DIRTY / CONFLICTING SHAPE (measured 2026-09-11, PR #17612) ────
# pr-required.sh printed MERGEABLE: 4/4 at 03:56Z. #17614, a sibling touching a
# file this head also touched, merged at 03:5xZ. By 04:05Z the head CONFLICTED
# with the base, gh refused with the string below, and the table answered
# UNRECOGNISED — the correct fail-closed answer, and useless advice: it sends
# the reader to re-run the merge by hand, which refuses identically forever.
DIRTY_FIXTURE='X Pull request FRIKKern/barkpark#17612 is not mergeable: the merge commit cannot be cleanly created. To have the pull request merged after all the requirements have been met, add the --auto flag. Run the following to resolve the merge conflicts locally: gh pr checkout 17612 && git fetch origin main && git merge origin/main'
check "43 the DIRTY refusal is NAMED, not UNRECOGNISED (measured 2026-09-11, #17612)" DIRTY \
  "$DIRTY_FIXTURE"
# THE TRAP, kept as a live control rather than a comment. 'is not mergeable'
# ALSO prefixes the CLIENT_BLOCK message, so an arm keyed on that substring
# alone relabels every client-side block — the DOMINANT arm under protection
# (D79) — as a merge conflict, and sends its reader to rebase a branch that has
# nothing wrong with it. Row 9 above asserts the same thing from the other side;
# this row exists so a future widening of the DIRTY needle reds HERE by name.
check "43b …and the CLIENT_BLOCK message, which ALSO says 'is not mergeable', is untouched" CLIENT_BLOCK \
  'X Pull request FRIKKern/barkpark#6414 is not mergeable: the base branch policy prohibits the merge.'
# BOTH needles are required. A 'not mergeable' that names no reason is not a
# measured shape and must keep refusing.
check "43c a bare 'is not mergeable' with no reason still REFUSES" UNRECOGNISED \
  'X Pull request FRIKKern/barkpark#17612 is not mergeable.'
# And the second needle alone, with no gh preamble, is still the conflict.
check "43d the conflict sentence alone is still DIRTY" DIRTY \
  'is not mergeable: the merge commit cannot be cleanly created.'

advice_contains "44 DIRTY advice says the required contexts are a SEPARATE question" \
                DIRTY 'NOT a finding about the required contexts'
advice_contains "44a …and says waiting never clears it"          DIRTY 'Waiting will never clear it'
advice_contains "44b …and names the rebase, in the branch OWN worktree" DIRTY 'rebase origin/main'
advice_contains "44c …and names the re-push form"                DIRTY 'push --force-with-lease'
advice_contains "44d …and says to wait for the contexts on the NEW head" DIRTY 'run this again'
# NEVER the queue. bp-merge.test.sh already ratchets the flag out of every
# executable line of bp-merge.sh (rows 22/23), so the advice argues against
# gh's suggestion WITHOUT spelling it — asserted on the sentence, not the flag.
advice_contains "44e …and tells the reader NOT to take gh's queue-the-merge offer (D53)" \
                DIRTY 'keeps unattended merging switched OFF'

# The counter-line must fire on THIS message too. gh appends a second
# suggestion here — queue the merge for after the requirements are met — and a
# refusal that quotes it verbatim without countering it teaches the abolished
# verb in gh's voice, exactly as D78 found for the admin override.
out="$(counter_line "$DIRTY_FIXTURE")"
if out_has "$out" 'DEAD'; then
  pass=$((pass + 1)); echo "  ok   45 counter_line answers gh's QUEUE-the-merge suggestion on the DIRTY message"
else
  fail=$((fail + 1)); echo "  FAIL the DIRTY refusal quotes gh's queue suggestion with nothing beneath it" >&2
fi
if [ -z "$(counter_line 'GraphQL: Required status check "Elixir gate" is in progress.')" ]; then
  pass=$((pass + 1)); echo "  ok   45a …and still stays SILENT on a message that suggested nothing"
else
  fail=$((fail + 1)); echo "  FAIL the queue counter-line fires on a message that made no suggestion" >&2
fi

# ── 46. THE EXIT CODE IS DISTINCT, and it is DRIVEN, not grepped ─────────────
# Every other refusal exits 1, which a caller may sensibly retry or wait on. A
# conflict never clears by waiting, so DIRTY exits 4. refuse() is driven for
# real here — it only reads globals, so setting them is the whole setup.
drive_refuse() { # state message -> prints rc
  local st="$1" msg="$2" rc=0
  (
    PR_STATE_READ="OPEN"; PR_STATE_ERROR=""
    PR_NUMBER=123; PR_URL="https://github.com/FRIKKern/barkpark/pull/123"; HEAD_SHA=deadbeef
    refuse "$st" "$msg"
  ) >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
rc_dirty="$(drive_refuse DIRTY "$DIRTY_FIXTURE")"
rc_wait="$(drive_refuse WAIT 'GraphQL: Required status check "Elixir gate" is in progress.')"
if [ "$rc_dirty" = "4" ]; then
  pass=$((pass + 1)); echo "  ok   46 refuse() exits 4 on DIRTY — a code a retry-on-1 caller must not retry"
else
  fail=$((fail + 1)); echo "  FAIL refuse() exited $rc_dirty on DIRTY, not the documented 4" >&2
fi
if [ "$rc_wait" = "1" ]; then
  pass=$((pass + 1)); echo "  ok   46a …and every other refusal still exits 1 (control: WAIT)"
else
  fail=$((fail + 1)); echo "  FAIL the new exit code leaked onto other states (WAIT exited $rc_wait)" >&2
fi

# ── 47-51. THE PRE-FLIGHT READ, driven end-to-end through main() with a STUBBED
# gh. Not a re-implementation of main's ordering: main() itself is called, so
# resolve_pr → preflight → preflight_mergeable → merge_loop is the REAL order,
# and the assertion "zero merge calls" is made against a LOG of every gh argv
# the run produced. A test that asserted "the read happens first" by grepping
# the source would stay green if someone moved the call after merge_loop.
BPM_TMP="$(mktemp -d)"
trap 'rm -rf "$BPM_TMP"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' > "$BPM_TMP/verify.sh"
chmod +x "$BPM_TMP/verify.sh"
GH_ARGV_LOG="$BPM_TMP/gh-argv.log"
GH_MERGEABLE_STATE="clean"
GH_MERGEABLE_RC=0
# The label set main()'s PR-label hold arm reads. It defaults to a NON-hold
# label rather than `[]`: an empty array would let a classifier that passes
# everything look correct here, and every row below would be measuring nothing.
GH_LABELS='["needs-review"]'
gh() {
  printf '%s\n' "$*" >> "$GH_ARGV_LOG"
  case "$1" in
    pr)
      case "${2:-}" in
        view)
          case "$*" in
            *"--json state"*) printf 'OPEN\n' ;;
            *"--json labels"*) printf '%s\n' "$GH_LABELS" ;;
            *) printf '{"number":123,"url":"https://github.com/FRIKKern/barkpark/pull/123","headRefOid":"deadbeef","state":"OPEN","isDraft":false}\n' ;;
          esac ;;
        merge) printf 'Merged pull request #123 (stub)\n' ;;
        *) return 1 ;;
      esac ;;
    api)
      if [ "$GH_MERGEABLE_RC" -ne 0 ]; then
        printf '%s\n' "$GH_MERGEABLE_STATE" >&2
        return "$GH_MERGEABLE_RC"
      fi
      printf '%s\n' "$GH_MERGEABLE_STATE" ;;
    *) return 1 ;;
  esac
}
# The re-poll is real; only its CLOCK is neutralised, so the unknown arm does
# not spend 12 wall seconds in CI.
MERGEABLE_POLLS=3
MERGEABLE_POLL_SECONDS=0

drive_main() { # state rc_of_the_api_read -> sets DM_RC, DM_OUT, DM_MERGE_CALLS, DM_API_CALLS
  GH_MERGEABLE_STATE="$1"; GH_MERGEABLE_RC="${2:-0}"
  : > "$GH_ARGV_LOG"
  DM_RC=0
  DM_OUT="$( VERIFY="$BPM_TMP/verify.sh" main 2>&1 )" || DM_RC=$?
  DM_MERGE_CALLS="$(grep -c '^pr merge' "$GH_ARGV_LOG" || true)"
  DM_API_CALLS="$(grep -c '^api ' "$GH_ARGV_LOG" || true)"
}

# 47. dirty: refused BY NAME, exit 4, and the merge call was never spent.
drive_main dirty
if [ "$DM_RC" = "4" ] && [ "$DM_MERGE_CALLS" -eq 0 ] \
   && out_has "$DM_OUT" 'REFUSED — DIRTY'; then
  pass=$((pass + 1)); echo "  ok   47 mergeable_state=dirty refuses by NAME before the merge call (rc=$DM_RC, merge calls=$DM_MERGE_CALLS)"
else
  fail=$((fail + 1))
  echo "  FAIL dirty was not refused pre-merge (rc=$DM_RC merge_calls=$DM_MERGE_CALLS)" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi
if out_has "$DM_OUT" 'push --force-with-lease'; then
  pass=$((pass + 1)); echo "  ok   47a …and prints the rebase remedy, not just the verdict"
else
  fail=$((fail + 1)); echo "  FAIL the dirty pre-flight refusal names no resolving command" >&2
fi

# 47b. THE WHOLE VERB, END TO END. Rows 77-83 drive preflight_label_hold
# directly; this one drives main(), the entry point every lane actually calls,
# and proves the arm is REACHED there and that the merge call is never spent.
# #18497 merged through main() under a live `hold` label.
GH_LABELS='["hold"]'
drive_main clean
if [ "$DM_RC" = "7" ] && [ "$DM_MERGE_CALLS" -eq 0 ] && out_has "$DM_OUT" 'REFUSED — PR-LABEL HOLD'; then
  pass=$((pass + 1)); echo "  ok   47b main() itself refuses a 'hold'-labelled PR on exit 7, merge call never spent"
else
  fail=$((fail + 1))
  echo "  FAIL main() did not refuse a held PR (rc=$DM_RC merge_calls=$DM_MERGE_CALLS)" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi
# 47c. CONTROL, SAME PATH: with the hold removed the identical run MERGES. The
# `gh pr edit --remove-label hold` door, exercised. Without this row 47b proves
# only that main() can refuse, not that the LABEL is what refused it.
GH_LABELS='["needs-review"]'
drive_main clean
if [ "$DM_RC" = "0" ] && [ "$DM_MERGE_CALLS" -ge 1 ]; then
  pass=$((pass + 1)); echo "  ok   47c CONTROL: removing the label lets the SAME run merge (rc=$DM_RC, merge calls=$DM_MERGE_CALLS)"
else
  fail=$((fail + 1))
  echo "  FAIL the unlabelled control did not merge (rc=$DM_RC merge_calls=$DM_MERGE_CALLS) — 47b may be refusing for another reason" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi

# 48. unknown: GitHub has not computed it. Re-read, then REFUSE — never merge.
drive_main unknown
if [ "$DM_RC" = "1" ] && [ "$DM_MERGE_CALLS" -eq 0 ] && [ "$DM_API_CALLS" -eq 3 ] \
   && out_has "$DM_OUT" "STILL 'unknown'"; then
  pass=$((pass + 1)); echo "  ok   48 mergeable_state=unknown re-polls ($DM_API_CALLS reads) and then REFUSES — never a green"
else
  fail=$((fail + 1))
  echo "  FAIL unknown was mishandled (rc=$DM_RC merge_calls=$DM_MERGE_CALLS api_calls=$DM_API_CALLS)" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi

# 49. THE POSITIVE CONTROL. Without it every row above passes on a script that
# refuses unconditionally, which is the vacuous pass in the other direction.
drive_main clean
if [ "$DM_RC" = "0" ] && [ "$DM_MERGE_CALLS" -eq 1 ] \
   && out_has "$DM_OUT" 'MERGED #123'; then
  pass=$((pass + 1)); echo "  ok   49 CONTROL: mergeable_state=clean reaches the merge call and merges (merge calls=$DM_MERGE_CALLS)"
else
  fail=$((fail + 1))
  echo "  FAIL the clean control did not merge (rc=$DM_RC merge_calls=$DM_MERGE_CALLS)" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi
# `unstable` is a NON-required check being red. The branch policy allows it, so
# the pre-flight must not invent a refusal the server would not make.
drive_main unstable
if [ "$DM_RC" = "0" ] && [ "$DM_MERGE_CALLS" -eq 1 ]; then
  pass=$((pass + 1)); echo "  ok   49a CONTROL: 'unstable' (a non-required check is red) is NOT a conflict and still merges"
else
  fail=$((fail + 1)); echo "  FAIL the pre-flight refused 'unstable', which the branch policy allows (rc=$DM_RC)" >&2
fi

# 50. AN UNREADABLE READ IS A REFUSAL, never a skip — and it must SAY it
# measured nothing, or the refusal sounds like a finding about the PR.
drive_main 'GraphQL: API rate limit already exceeded for user ID 32601161.' 1
if [ "$DM_RC" = "1" ] && [ "$DM_MERGE_CALLS" -eq 0 ] \
   && out_has "$DM_OUT" 'could not READ mergeable_state' \
   && out_has "$DM_OUT" 'rate limit already exceeded' \
   && out_has "$DM_OUT" 'NOTHING was measured'; then
  pass=$((pass + 1)); echo "  ok   50 a FAILED mergeable_state read refuses, quotes the API, and claims nothing about the PR"
else
  fail=$((fail + 1))
  echo "  FAIL an unreadable pre-flight did not refuse honestly (rc=$DM_RC merge_calls=$DM_MERGE_CALLS)" >&2
  printf '%s\n' "$DM_OUT" | sed 's/^/       /' >&2
fi
unset -f gh drive_main drive_refuse out_has
rm -rf "$BPM_TMP"
trap - EXIT

# 51. The read is the one the task specifies — REST .mergeable_state — and not a
# re-derivation from a check rollup, which cannot see the diff at all.
if grep -qF -- 'gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER" --jq' "$ROOT/scripts/bp-merge.sh" \
   && grep -qF -- ".mergeable_state" "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   51 the pre-flight reads .mergeable_state over REST, the same read pr-required makes"
else
  fail=$((fail + 1)); echo "  FAIL the mergeable_state read is not a REST .mergeable_state read" >&2
fi
# And it is WIRED into main between the deadlock pre-flight and the merge loop.
# Rows 47-50 drive this for real; this row exists so a deletion reds with a
# sentence that names the cause rather than only a wrong exit code.
if awk '/^  preflight_mergeable$/ {seen=1} /^  merge_loop$/ {print (seen ? "OK" : "LATE"); exit}' \
     "$ROOT/scripts/bp-merge.sh" | grep -q OK; then
  pass=$((pass + 1)); echo "  ok   51a …and main() runs it BEFORE merge_loop"
else
  fail=$((fail + 1)); echo "  FAIL preflight_mergeable is not called before merge_loop in main()" >&2
fi

# ── 52-58. THE BOUNDED RETRY ON 'Base branch was modified' ──────────────────
# DRIVEN THROUGH main(), NOT GREPPED. `gh` is stubbed, so resolve_pr →
# preflight → preflight_mergeable → merge_loop is the REAL order and the merge
# ATTEMPT COUNT is read out of the stub's own counter file rather than asserted
# from the source. Both directions run in THIS ONE run:
#   A transient-then-success  exits 0 after exactly TWO attempts
#   B always-transient        exits 1 refusing after exactly TWO attempts
# Without B, a script that retried forever would pass A. Without A, a script
# that never retried at all would pass B.
#
# THE STUB HAS THREE EXPLICIT MODES, and refuses an unknown one rather than
# defaulting to anything: `transient-then-success` answers the captured sentence
# on attempt 1 only, `always-transient` answers it on every attempt, and
# `never-transient` merges first try (row 57's control, which proves the stub is
# actually reached and that the new arm is inert off its own message).
#
# THE STUB IS EXPLICIT: `pr merge` bumps a counter FILE (main() runs inside a
# command substitution, so a shell counter would die in the subshell), then
# answers the captured GitHub sentence on attempt 1 — and, in mode B, on every
# attempt. `api` answers whatever BM_STATE says, which is how the re-read gate
# is driven. Every argv is logged, and row 55 reads that log to prove the
# re-read happened BETWEEN the two merge calls.
BM_TMP="$(mktemp -d)"
trap 'rm -rf "$BM_TMP"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' > "$BM_TMP/verify.sh"
chmod +x "$BM_TMP/verify.sh"
BM_FIXTURE='GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'
BM_LOG="$BM_TMP/gh-argv.log"
BM_COUNT="$BM_TMP/merge-attempts"
BM_MODE="transient-then-success"
BM_STATE="clean"
: > "$BM_LOG"; printf '0\n' > "$BM_COUNT"

gh() {
  printf '%s\n' "$*" >> "$BM_LOG"
  case "$1" in
    pr)
      case "${2:-}" in
        view)
          case "$*" in
            *"--json state"*) printf 'OPEN\n' ;;
            *) printf '{"number":123,"url":"https://github.com/FRIKKern/barkpark/pull/123","headRefOid":"deadbeef","state":"OPEN","isDraft":false}\n' ;;
          esac ;;
        merge)
          local n
          n=$(( $(cat "$BM_COUNT") + 1 ))
          printf '%s\n' "$n" > "$BM_COUNT"
          case "$BM_MODE" in
            always-transient) printf '%s\n' "$BM_FIXTURE" >&2; return 1 ;;
            transient-then-success)
              if [ "$n" -eq 1 ]; then printf '%s\n' "$BM_FIXTURE" >&2; return 1; fi ;;
            never-transient) : ;;
            *) printf 'bm stub: unknown mode %s\n' "$BM_MODE" >&2; return 1 ;;
          esac
          printf 'Merged pull request #123 (stub)\n' ;;
        *) return 1 ;;
      esac ;;
    api) printf '%s\n' "$BM_STATE" ;;
    *) return 1 ;;
  esac
}
bm_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

MERGEABLE_POLLS=3
MERGEABLE_POLL_SECONDS=0
BASE_MODIFIED_RETRY_SLEEP=0

drive_bm() { # mode recheck_state -> BM_RC, BM_OUT, BM_ATTEMPTS
  BM_MODE="$1"; BM_STATE="${2:-clean}"
  : > "$BM_LOG"; printf '0\n' > "$BM_COUNT"
  BM_RC=0
  BM_OUT="$( VERIFY="$BM_TMP/verify.sh" merge_loop 2>&1 )" || BM_RC=$?
  BM_ATTEMPTS="$(cat "$BM_COUNT")"
}
PR_NUMBER=123
PR_URL="https://github.com/FRIKKern/barkpark/pull/123"
HEAD_SHA=deadbeef
PR_STATE_READ="OPEN"; PR_STATE_ERROR=""
BUDGET_SECONDS=60
POLL_SECONDS=0

# 52. DIRECTION A — transient, then it merges. Exactly two attempts.
drive_bm transient-then-success clean
if [ "$BM_RC" = "0" ] && [ "$BM_ATTEMPTS" = "2" ] && bm_has "$BM_OUT" 'MERGED #123'; then
  pass=$((pass + 1)); echo "  ok   52 transient-then-success MERGES after exactly $BM_ATTEMPTS merge attempts (rc=$BM_RC)"
else
  fail=$((fail + 1))
  echo "  FAIL the transient refusal was not retried into a merge (rc=$BM_RC attempts=$BM_ATTEMPTS)" >&2
  printf '%s\n' "$BM_OUT" | sed 's/^/       /' >&2
fi
if bm_has "$BM_OUT" 'the base moved under the merge call'; then
  pass=$((pass + 1)); echo "  ok   52a …and says WHY it retried, in a line naming the condition"
else
  fail=$((fail + 1)); echo "  FAIL the retry is silent — a retried write must announce itself" >&2
fi

# 53/54. DIRECTION B — always transient. It must REFUSE, and it must have
# stopped at TWO attempts. This is the bound, PROVED: the count comes from the
# stub, not from reading the source.
drive_bm always-transient clean
if [ "$BM_RC" = "1" ] && [ "$BM_ATTEMPTS" = "2" ]; then
  pass=$((pass + 1)); echo "  ok   53 always-transient REFUSES (rc=$BM_RC) after exactly $BM_ATTEMPTS merge attempts — the retry is BOUNDED"
else
  fail=$((fail + 1))
  echo "  FAIL the bound did not hold (rc=$BM_RC attempts=$BM_ATTEMPTS; expected rc=1 attempts=2)" >&2
  printf '%s\n' "$BM_OUT" | sed 's/^/       /' >&2
fi
if bm_has "$BM_OUT" 'REFUSED — BASE_MODIFIED' \
   && bm_has "$BM_OUT" 'AGAIN after 2 merge attempts'; then
  pass=$((pass + 1)); echo "  ok   54 …and the refusal NAMES the state and quotes the attempt count"
else
  fail=$((fail + 1)); echo "  FAIL the bounded refusal does not name BASE_MODIFIED or its attempt count" >&2
  printf '%s\n' "$BM_OUT" | sed 's/^/       /' >&2
fi

# 55. THE RE-READ HAPPENS BETWEEN THE TWO MERGE CALLS. Asserted off the argv
# LOG, so moving the re-read after the retry (or deleting it) reds here even
# though both attempt counts would be unchanged.
drive_bm transient-then-success clean
if awk '/^pr merge/ {m++; next} /^api / {if (m==1) between=1} END {exit !(m==2 && between)}' "$BM_LOG"; then
  pass=$((pass + 1)); echo "  ok   55 a mergeable_state re-read sits BETWEEN the two merge calls (never a retry off the stale read)"
else
  fail=$((fail + 1)); echo "  FAIL no fresh mergeable_state read between the two merge attempts" >&2
  sed 's/^/       /' "$BM_LOG" >&2
fi

# 56. THE RE-READ IS A GATE, NOT A FORMALITY. Same transient message, but the
# fresh read now says DIRTY — the sibling that moved the base took this head
# conflicting with it. One attempt, then refuse. A retry here would be the arm
# swallowing a genuine conflict.
drive_bm transient-then-success dirty
if [ "$BM_RC" != "0" ] && [ "$BM_ATTEMPTS" = "1" ] && bm_has "$BM_OUT" 'the re-read says DIRTY'; then
  pass=$((pass + 1)); echo "  ok   56 a re-read of DIRTY spends NO retry (attempts=$BM_ATTEMPTS, rc=$BM_RC) — a conflict is never retried"
else
  fail=$((fail + 1))
  echo "  FAIL the retry ignored a DIRTY re-read (rc=$BM_RC attempts=$BM_ATTEMPTS)" >&2
  printf '%s\n' "$BM_OUT" | sed 's/^/       /' >&2
fi
# 56a. Same shape for 'unknown': GitHub has not recomputed mergeability since
# the base moved, and unknown is never a green anywhere else in this file.
drive_bm transient-then-success unknown
if [ "$BM_RC" != "0" ] && [ "$BM_ATTEMPTS" = "1" ]; then
  pass=$((pass + 1)); echo "  ok   56a …and an 'unknown' re-read spends no retry either (attempts=$BM_ATTEMPTS)"
else
  fail=$((fail + 1)); echo "  FAIL an 'unknown' re-read still spent the retry (attempts=$BM_ATTEMPTS)" >&2
fi

# 57. CONTROL: THE STUB IS REACHED. Every row above is a claim about attempt
# COUNTS, and a fixture that never reached the code under test would report
# zero and look like a bound. A clean, non-transient run must reach the stub
# exactly ONCE and merge — which also proves the new arm changed nothing for
# every other message.
drive_bm never-transient clean
if [ "$BM_RC" = "0" ] && [ "$BM_ATTEMPTS" = "1" ] && bm_has "$BM_OUT" 'MERGED #123'; then
  pass=$((pass + 1)); echo "  ok   57 CONTROL: a non-transient merge still takes exactly ONE attempt (the arm is inert off its message)"
else
  fail=$((fail + 1))
  echo "  FAIL the control run is wrong (rc=$BM_RC attempts=$BM_ATTEMPTS) — the counts above may be vacuous" >&2
fi

# 58. THE BOUND IS A LITERAL, NOT AN ENV KNOB. Every other budget in this file
# is overridable; this one governs how many times a WRITE is repeated, and an
# env-tunable retry count is an unbounded loop one variable away.
if grep -qE '^BASE_MODIFIED_RETRY_BUDGET=1$' "$ROOT/scripts/bp-merge.sh"; then
  pass=$((pass + 1)); echo "  ok   58 the retry bound is a literal 1, unreachable from the environment"
else
  fail=$((fail + 1)); echo "  FAIL the retry bound is not a literal — it can be widened from the environment" >&2
fi
advice_contains "58a BASE_MODIFIED advice says the condition is transient" BASE_MODIFIED 'TRANSIENT'
advice_contains "58b …and names a resolving command like every other arm"  BASE_MODIFIED 'scripts/bp-merge.sh'
advice_contains "58c …and says it is NOT a finding about the checks"       BASE_MODIFIED 'NOT a finding about the checks'

unset -f gh bm_has drive_bm
rm -rf "$BM_TMP"
trap - EXIT

# ── 59-73. THE MAIN-RED HOLD PRE-FLIGHT ─────────────────────────────────────
#
# DRIVEN THROUGH THE REAL preflight_hold() AGAINST THE REAL
# scripts/main-red-hold.sh, over REGISTRY FIXTURES written here. Nothing is
# grepped out of the source and no GitHub is touched: `gh` is stubbed so
# read_pr_files returns a file list this file chooses, and the registry is
# selected with BP_MERGE_HOLD_REGISTRY (an ABSOLUTE path, because
# main-red-hold.sh resolves a relative --registry against ITS OWN root).
#
# BOTH DIRECTIONS RUN AGAINST THE SAME REGISTRY IN THIS ONE RUN. Rows 60 and 61
# judge the identical file (`$HOLD_REG`); only the PR's file list differs. A
# check that refused everything would pass 60 and fail 61; a check that refused
# nothing would pass 61 and fail 60. Neither arm is evidence without the other,
# and running them against two different registries would prove only that two
# files differ.
#
# preflight_hold exits rather than returning, so every row runs it in a
# SUBSHELL and reads the exit code on the very next line.
HOLD_TMP="$(mktemp -d)"
HOLD_REG="$HOLD_TMP/holds.json"
HOLD_FILES=""
HOLD_COMMENT_RC=0
HOLD_COMMENT_LOG="$HOLD_TMP/gh-comment.log"
: > "$HOLD_COMMENT_LOG"

cat > "$HOLD_REG" <<'HOLDREG'
{
  "version": 1,
  "holds": [
    {
      "id": "st-taskboard-drift",
      "owner": "lane:cli",
      "task": "task-deadbeefcafe0001",
      "trees": ["internal/taskboard"],
      "repro": "CGO_ENABLED=0 go test ./internal/taskboard/",
      "opened_on_sha": "1111111111111111111111111111111111111111",
      "opened_exit": 1,
      "opened_at": "2026-09-13T00:00:00Z"
    }
  ]
}
HOLDREG

gh() {
  case "$1" in
    pr)
      case "${2:-}" in
        view)    printf '%s\n' "$HOLD_FILES" ;;
        comment) printf '%s\n' "$*" >> "$HOLD_COMMENT_LOG"
                 if [ "$HOLD_COMMENT_RC" != "0" ]; then
                   printf 'HTTP 403: Resource not accessible by integration\n' >&2
                   return "$HOLD_COMMENT_RC"
                 fi
                 printf 'https://github.com/FRIKKern/barkpark/pull/123#issuecomment-1\n' ;;
        *)       printf 'hold stub: unexpected `gh pr %s`\n' "${2:-}" >&2; return 1 ;;
      esac ;;
    *) printf 'hold stub: unexpected `gh %s`\n' "$1" >&2; return 1 ;;
  esac
}

PR_NUMBER=123
REPO_ROOT="$ROOT"
HOLD_SCRIPT="$ROOT/scripts/main-red-hold.sh"

drive_hold() { # files registry -> HOLD_RC, HOLD_OUT
  HOLD_FILES="$1"
  HOLD_RC=0
  HOLD_OUT="$( HOLD_REGISTRY="$2" preflight_hold 2>&1 )" || HOLD_RC=$?
}
hold_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

hold_row() { # label want_rc needle... ; uses HOLD_RC/HOLD_OUT
  local label="$1" want="$2"; shift 2
  local bad="" n
  [ "$HOLD_RC" = "$want" ] || bad="exit $HOLD_RC (wanted $want)"
  for n in "$@"; do
    hold_has "$HOLD_OUT" "$n" || bad="$bad; missing '$n'"
  done
  if [ -z "$bad" ]; then
    pass=$((pass + 1)); echo "  ok   $label (exit $HOLD_RC)"
  else
    fail=$((fail + 1)); echo "  FAIL $label: $bad" >&2
    printf '%s\n' "$HOLD_OUT" | sed 's/^/       /' >&2
  fi
}

echo
echo "── main-red hold pre-flight: real main-red-hold.sh, fixture registry, no live GitHub ──"

# 59. CONTROL FIRST: the fixture registry is the one being judged, and it holds
# exactly one hold. Without this row every "not held" verdict below could be a
# verdict about an empty file.
if [ "$(jq -r '.holds | length' "$HOLD_REG")" = "1" ] \
   && [ "$(jq -r '.holds[0].id' "$HOLD_REG")" = "st-taskboard-drift" ]; then
  pass=$((pass + 1)); echo "  ok   59 CONTROL: the fixture registry carries exactly one hold, id st-taskboard-drift"
else
  fail=$((fail + 1)); echo "  FAIL the fixture registry is not the shape every row below assumes" >&2
fi

# 60. DIRECTION A — HELD. The file list is quoted in the verdict, and the
# refusal carries the TREE, the OWNER and the TASK ID off the registry.
drive_hold 'internal/taskboard/golden.go
docs/INDEX.md' "$HOLD_REG"
hold_row "60 a PR touching internal/taskboard/golden.go is HELD" 5 \
  "REFUSED — MAIN-RED HOLD" "HELD: st-taskboard-drift" \
  "internal/taskboard" "lane:cli" "task-deadbeefcafe0001" \
  "internal/taskboard/golden.go"
echo "       file list that decided 60: internal/taskboard/golden.go, docs/INDEX.md"

# 60a. THE REFUSAL IS DISTINGUISHABLE FROM EVERY OTHER REFUSAL THIS SCRIPT
# EMITS. Asserted POSITIVELY and derived, not eyeballed: the banner is counted
# across the whole script and must appear on exactly the arms that mean HOLD.
HOLD_BANNERS="$(grep -c 'REFUSED — MAIN-RED HOLD' "$ROOT/scripts/bp-merge.sh" || true)"
HOLD_OTHER="$(grep -c 'bp-merge: REFUSED — ' "$ROOT/scripts/bp-merge.sh" || true)"
if [ "$HOLD_BANNERS" -ge 1 ] && [ "$HOLD_OTHER" -gt "$HOLD_BANNERS" ]; then
  pass=$((pass + 1))
  echo "  ok   60a the HOLD banner is its own string ($HOLD_BANNERS hold arm(s) among $HOLD_OTHER 'REFUSED — ' arms)"
else
  fail=$((fail + 1))
  echo "  FAIL CANNOT READ: banner census came back $HOLD_BANNERS/$HOLD_OTHER — below the floor of 1 hold arm strictly inside a larger refusal set" >&2
fi

# 61. DIRECTION B — CLEAR, SAME REGISTRY, SAME RUN. A PR touching nothing held
# passes the pre-flight and says so.
drive_hold 'docs/INDEX.md
scripts/doctor.sh' "$HOLD_REG"
hold_row "61 a PR touching NOTHING held is CLEAR and unaffected" 0 \
  "hold pre-flight ok" "CLEAR" "not held: st-taskboard-drift"
echo "       file list that decided 61: docs/INDEX.md, scripts/doctor.sh"

# 61a. AND THE VERDICTS DIFFER. Two rows that printed the same thing would be
# one row twice.
if hold_has "$HOLD_OUT" "CLEAR" && ! hold_has "$HOLD_OUT" "REFUSED — MAIN-RED HOLD"; then
  pass=$((pass + 1)); echo "  ok   61a …and the CLEAR verdict carries no HOLD refusal (the two arms are not one arm twice)"
else
  fail=$((fail + 1)); echo "  FAIL the CLEAR run still printed a HOLD refusal" >&2
fi

# 62-64. FAIL CLOSED. Three unreadable shapes, each exit 6 with the distinct
# CANNOT READ line — never 0, never byte-identical to CLEAR.
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/does-not-exist.json"
hold_row "62 a MISSING registry is CANNOT READ, never CLEAR" 6 "HOLD CHECK CANNOT READ"

: > "$HOLD_TMP/empty.json"
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/empty.json"
hold_row "63 an EMPTY registry is CANNOT READ, never CLEAR" 6 "HOLD CHECK CANNOT READ"

printf '{ "holds": [ {,,, \n' > "$HOLD_TMP/garbage.json"
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/garbage.json"
hold_row "64 an UNPARSEABLE registry is CANNOT READ, never CLEAR" 6 "HOLD CHECK CANNOT READ"

# 65. AN EMPTY FILE LIST IS A FAILED READ, NOT A CLEAN PR. This is the shape
# that would otherwise sail through every hold on earth.
drive_hold '' "$HOLD_REG"
hold_row "65 a ZERO-file PR is CANNOT READ, never CLEAR" 6 "HOLD CHECK CANNOT READ" "ZERO changed files"

# 66. THE CANNOT READ VERDICT IS NOT THE CLEAR VERDICT AND NOT THE HELD ONE.
#
# THE SENTINELS ARE THE VERDICT LINES, NOT THE WORD "CLEAR". This row first
# probed for the bare substring `CLEAR` and FAILED on a correct refusal: the
# CANNOT READ text itself says "refusing to report CLEAR off a file that is not
# there", so the probe matched its own counter-example. A negative probe cannot
# live in a file that contains the word it is hunting. What actually
# distinguishes the three verdicts is the line each one ends on, so those are
# what this asserts.
HOLD_V_CLEAR="bp-merge: hold pre-flight ok"
HOLD_V_HELD="bp-merge: REFUSED — MAIN-RED HOLD"
HOLD_V_CANT="bp-merge: HOLD CHECK CANNOT READ"
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/does-not-exist.json"
if hold_has "$HOLD_OUT" "$HOLD_V_CANT" \
   && ! hold_has "$HOLD_OUT" "$HOLD_V_CLEAR" && ! hold_has "$HOLD_OUT" "$HOLD_V_HELD"; then
  pass=$((pass + 1)); echo "  ok   66 the CANNOT READ verdict line is neither the CLEAR one nor the HELD one — it claims neither"
else
  fail=$((fail + 1)); echo "  FAIL the CANNOT READ verdict is confusable with a CLEAR or a HELD one" >&2
  printf '%s\n' "$HOLD_OUT" | sed 's/^/       /' >&2
fi

# 66a. CONTROL FOR 66: the three sentinels are not vacuous strings that never
# appear. Each one is shown to fire on its OWN case in this same run. A row
# asserting three absences proves nothing until each string is shown findable.
drive_hold 'docs/INDEX.md' "$HOLD_REG"
hold_has "$HOLD_OUT" "$HOLD_V_CLEAR" && HOLD_S1=1 || HOLD_S1=0
drive_hold 'internal/taskboard/golden.go' "$HOLD_REG"
hold_has "$HOLD_OUT" "$HOLD_V_HELD" && HOLD_S2=1 || HOLD_S2=0
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/does-not-exist.json"
hold_has "$HOLD_OUT" "$HOLD_V_CANT" && HOLD_S3=1 || HOLD_S3=0
if [ "$HOLD_S1$HOLD_S2$HOLD_S3" = "111" ]; then
  pass=$((pass + 1)); echo "  ok   66a CONTROL: all three verdict sentinels fire on their own case (clear/held/cannot-read = $HOLD_S1$HOLD_S2$HOLD_S3)"
else
  fail=$((fail + 1)); echo "  FAIL CANNOT READ: sentinel control came back $HOLD_S1$HOLD_S2$HOLD_S3, not 111 — row 66's absences assert nothing" >&2
fi

# 67-70. THE OVERRIDE. Explicit, three-part, and the RECORD IS A PRECONDITION.
drive_hold_ov() { # id who why files registry
  HOLD_FILES="$4"
  HOLD_RC=0
  HOLD_OUT="$( BP_MERGE_HOLD_OVERRIDE_ID="$1" BP_MERGE_HOLD_OVERRIDE_WHO="$2" \
               BP_MERGE_HOLD_OVERRIDE_WHY="$3" HOLD_REGISTRY="$5" preflight_hold 2>&1 )" || HOLD_RC=$?
}

: > "$HOLD_COMMENT_LOG"
HOLD_COMMENT_RC=0
drive_hold_ov st-taskboard-drift 'lead-cli' 'carries the fix for this very red' \
  'internal/taskboard/golden.go' "$HOLD_REG"
hold_row "67 a COMPLETE override releases the hold" 0 \
  "OVERRIDDEN by lead-cli" "authorisation recorded on the PR"
if grep -q 'AUTHORISED BY: lead-cli' "$HOLD_COMMENT_LOG" \
   && grep -q 'REASON: carries the fix for this very red' "$HOLD_COMMENT_LOG" \
   && grep -q 'st-taskboard-drift' "$HOLD_COMMENT_LOG"; then
  pass=$((pass + 1)); echo "  ok   67a …and the WHO and the WHY landed in a PR COMMENT, not only in stdout"
else
  fail=$((fail + 1)); echo "  FAIL the override left no durable record: gh pr comment was not called with who/why/id" >&2
  sed 's/^/       /' "$HOLD_COMMENT_LOG" >&2
fi

drive_hold_ov st-taskboard-drift 'lead-cli' '' 'internal/taskboard/golden.go' "$HOLD_REG"
hold_row "68 a PARTIAL override is refused and names what is missing" 5 \
  "OVERRIDE INCOMPLETE" "BP_MERGE_HOLD_OVERRIDE_WHY"

drive_hold_ov some-other-hold 'lead-cli' 'because' 'internal/taskboard/golden.go' "$HOLD_REG"
hold_row "69 an override naming a hold this PR is NOT held by is refused" 5 \
  "OVERRIDE NAMES THE WRONG HOLD"

: > "$HOLD_COMMENT_LOG"
HOLD_COMMENT_RC=1
drive_hold_ov st-taskboard-drift 'lead-cli' 'carries the fix' 'internal/taskboard/golden.go' "$HOLD_REG"
hold_row "70 an override whose RECORD could not be posted refuses — the hold stands" 5 \
  "OVERRIDE COULD NOT BE RECORDED"
HOLD_COMMENT_RC=0

# 71. EXIT 6 HAS NO DOOR. A complete, correct-looking override against an
# UNREADABLE registry must still be exit 6 — you cannot authorise past a
# judgement that never happened.
drive_hold_ov st-taskboard-drift 'lead-cli' 'because' 'internal/taskboard/golden.go' "$HOLD_TMP/does-not-exist.json"
hold_row "71 an override CANNOT open the unreadable-registry door" 6 "HOLD CHECK CANNOT READ"

# 72. CONTROL: the override is INERT on a CLEAR PR. A door that also changed
# the cleared path would mean rows 61 and 67 were measuring the same thing.
: > "$HOLD_COMMENT_LOG"
drive_hold_ov st-taskboard-drift 'lead-cli' 'because' 'docs/INDEX.md' "$HOLD_REG"
if [ "$HOLD_RC" = "0" ] && hold_has "$HOLD_OUT" "CLEAR" && [ ! -s "$HOLD_COMMENT_LOG" ]; then
  pass=$((pass + 1)); echo "  ok   72 CONTROL: the override is inert on a CLEAR PR and posts nothing"
else
  fail=$((fail + 1)); echo "  FAIL the override changed the CLEAR path (rc=$HOLD_RC, comment log $(wc -c < "$HOLD_COMMENT_LOG") bytes)" >&2
fi

# 73. MUTATION, BOTH DIRECTIONS AND ASYMMETRIC. The fail-closed arm is the one
# criterion that matters most, so it is proved by BREAKING it in a scratch copy
# rather than by reading it. The mutation is ANCHORED TO THE LINE the census
# below locates — a bare substring replace landed 311 lines off target in this
# campaign and the test still went green — and the row ASSERTS THE MUTATION
# LANDED before it draws any conclusion.
#
# ASYMMETRY IS THE POINT: the mutant must go GREEN-on-unreadable (it merges
# through a registry it could not read — the exact defect) while STILL refusing
# the HELD case. Two arms that red together may be one arm twice; these two do
# not move together.
HOLD_MUT="$HOLD_TMP/bp-merge-mutant.sh"
cp "$ROOT/scripts/bp-merge.sh" "$HOLD_MUT"
HOLD_MUT_LINE="$(grep -n '^hold_cannot_read() { # \$1 = what could not be read$' "$HOLD_MUT" | cut -d: -f1)"
if [ -z "$HOLD_MUT_LINE" ]; then
  fail=$((fail + 1)); echo "  FAIL 73 CANNOT READ: could not locate hold_cannot_read()'s definition line — the mutation has no anchor and nothing below was measured" >&2
else
  # Replace the BODY's exit with a `return 0`, anchored at the located line.
  # The defect being simulated is the one the criterion names: the unreadable
  # case falls THROUGH to the merge instead of refusing.
  awk -v L="$HOLD_MUT_LINE" 'NR==L {print "hold_cannot_read() { echo \"bp-merge: (mutant) ignoring unreadable registry: $1\"; return 0; }"; print "hold_cannot_read_dead() {"; next} {print}' \
    "$HOLD_MUT" > "$HOLD_MUT.tmp" && mv "$HOLD_MUT.tmp" "$HOLD_MUT"
  if sed -n "${HOLD_MUT_LINE}p" "$HOLD_MUT" | grep -q '(mutant) ignoring unreadable registry'; then
    pass=$((pass + 1)); echo "  ok   73a the mutation landed on line $HOLD_MUT_LINE, the line hold_cannot_read() is defined on"

    HOLD_MUT_RC=0
    HOLD_MUT_OUT="$(
      BP_MERGE_LIB=1 . "$HOLD_MUT"
      PR_NUMBER=123; REPO_ROOT="$ROOT"; HOLD_SCRIPT="$ROOT/scripts/main-red-hold.sh"
      gh() { printf 'internal/taskboard/golden.go\n'; }
      HOLD_REGISTRY="$HOLD_TMP/does-not-exist.json" preflight_hold 2>&1
    )" || HOLD_MUT_RC=$?
    if [ "$HOLD_MUT_RC" = "0" ]; then
      pass=$((pass + 1)); echo "  ok   73b the MUTANT falls open on an unreadable registry (exit 0) — the guard is load-bearing"
    else
      fail=$((fail + 1)); echo "  FAIL 73b the mutant still refused (exit $HOLD_MUT_RC) — row 62-65 would pass with the guard gutted, so they assert nothing" >&2
      printf '%s\n' "$HOLD_MUT_OUT" | sed 's/^/       /' >&2
    fi

    HOLD_MUT_HELD_RC=0
    HOLD_MUT_HELD_OUT="$(
      BP_MERGE_LIB=1 . "$HOLD_MUT"
      PR_NUMBER=123; REPO_ROOT="$ROOT"; HOLD_SCRIPT="$ROOT/scripts/main-red-hold.sh"
      gh() { printf 'internal/taskboard/golden.go\n'; }
      HOLD_REGISTRY="$HOLD_REG" preflight_hold 2>&1
    )" || HOLD_MUT_HELD_RC=$?
    if [ "$HOLD_MUT_HELD_RC" = "5" ]; then
      pass=$((pass + 1)); echo "  ok   73c ASYMMETRY: the same mutant STILL refuses the HELD case (exit 5) — 62-65 and 60 are different arms"
    else
      fail=$((fail + 1)); echo "  FAIL 73c the mutation moved the HELD arm too (exit $HOLD_MUT_HELD_RC); the two arms are not independent" >&2
      printf '%s\n' "$HOLD_MUT_HELD_OUT" | sed 's/^/       /' >&2
    fi
  else
    fail=$((fail + 1)); echo "  FAIL 73a CANNOT READ: the mutation did NOT land on line $HOLD_MUT_LINE; nothing below it was measured" >&2
  fi
fi

# 74. AND THE ORIGINAL STILL REFUSES — the restore direction. Without it, 73
# proves only that a broken copy is broken.
drive_hold 'internal/taskboard/golden.go' "$HOLD_TMP/does-not-exist.json"
hold_row "74 the ORIGINAL still refuses the same input the mutant merged" 6 "HOLD CHECK CANNOT READ"

# 75. WIRED INTO main(), AND BEFORE THE PRE-FLIGHT THAT SPENDS API READS.
if awk '/^  preflight_hold$/ {seen=1} /^  preflight$/ {print (seen ? "OK" : "LATE"); exit}' \
     "$ROOT/scripts/bp-merge.sh" | grep -q OK; then
  pass=$((pass + 1)); echo "  ok   75 main() runs preflight_hold BEFORE preflight"
else
  fail=$((fail + 1)); echo "  FAIL preflight_hold is not called before preflight in main()" >&2
fi

echo
echo "── PR-label hold pre-flight: real read_pr_labels + label_hold_classify, stubbed gh ──"

# The PR-label hold is a DIFFERENT CLAIM from the main-red registry above, on a
# different exit code (7/8 vs 5/6), and these rows drive the REAL functions.
# #18497 carried `hold` from 2026-09-16T08:51:19Z and merged through this script
# at 06:41Z on 09-17: nothing here read the PR's labels at all.
PR_NUMBER=18497

drive_label() { # raw-gh-output gh-rc -> LBL_RC, LBL_OUT
  LBL_STUB_OUT="$1"; LBL_STUB_RC="$2"
  gh() { printf '%s' "$LBL_STUB_OUT"; return "$LBL_STUB_RC"; }
  LBL_RC=0
  LBL_OUT="$( preflight_label_hold 2>&1 )" || LBL_RC=$?
  unset -f gh
}

label_row() { # label want_rc needle...
  local label="$1" want="$2"; shift 2
  local bad="" n
  [ "$LBL_RC" = "$want" ] || bad="exit $LBL_RC (wanted $want)"
  for n in "$@"; do
    hold_has "$LBL_OUT" "$n" || bad="$bad; missing '$n'"
  done
  if [ -z "$bad" ]; then
    pass=$((pass + 1)); echo "  ok   $label (exit $LBL_RC)"
  else
    fail=$((fail + 1)); echo "  FAIL $label: $bad" >&2
    printf '%s\n' "$LBL_OUT" | sed 's/^/       /' >&2
  fi
}

# 76. THE REAL SHAPE. This is the byte-exact object `gh pr view 18705 --json
# labels` emitted on 2026-09-17, run through the byte-exact jq program
# read_pr_labels runs. A harness whose fixtures encode a shape the system never
# emits gives a uniform verdict and measures nothing, so the fixture is the
# SERVER'S object and the projection is the SCRIPT'S.
LBL_GH_HELD='{"labels":[{"id":"LA_kwDOSAgT9M8AAAAC1x0Gkg","name":"hold","description":"Lane-settable merge hold: the orchestrator merge sweep skips this PR","color":"B60205"}]}'
LBL_GH_CLEAR='{"labels":[]}'
LBL_RAW_HELD="$(printf '%s' "$LBL_GH_HELD"  | jq -r '[.labels[].name]|@json')"
LBL_RAW_CLEAR="$(printf '%s' "$LBL_GH_CLEAR" | jq -r '[.labels[].name]|@json')"
if [ "$LBL_RAW_HELD" = '["hold"]' ] && [ "$LBL_RAW_CLEAR" = '[]' ]; then
  pass=$((pass + 1)); echo "  ok   76 CONTROL: the live jq projection over a REAL gh object yields ${LBL_RAW_HELD} / ${LBL_RAW_CLEAR}"
else
  fail=$((fail + 1)); echo "  FAIL 76 the projection over a real gh object yielded [$LBL_RAW_HELD] / [$LBL_RAW_CLEAR]" >&2
fi

# 77. DIRECTION A — HELD refuses, on 7, and names the door.
drive_label "$LBL_RAW_HELD" 0
label_row "77 a PR carrying 'hold' is REFUSED on exit 7" 7 \
  "REFUSED — PR-LABEL HOLD" "labels: [hold]" "--remove-label hold" "no override flag"

# 78. DIRECTION B — the CONTROL. An unlabelled PR must PROCEED, or the arm is a
# deadlock rather than a hold. Same function, same reader, opposite input.
drive_label "$LBL_RAW_CLEAR" 0
label_row "78 CONTROL an unlabelled PR proceeds" 0 "label pre-flight ok" "CLEAR" "(none)"

# 79. EXACT MEMBERSHIP, NOT A SUBSTRING. merge-check's `*hold*` glob matched
# `holdover`, `withhold` and `stakeholder`; those are not holds.
drive_label '["holdover","withhold","stakeholder"]' 0
label_row "79 hold-lookalike labels do NOT hold" 0 "label pre-flight ok" "CLEAR"

# 80. A hold ALONGSIDE other labels is still a hold, and case does not excuse it.
drive_label '["needs-review","Hold","area/gates"]' 0
label_row "80 'Hold' among other labels still holds" 7 "REFUSED — PR-LABEL HOLD"

# 81. CANNOT READ — gh itself failed. Exit 8, never folded into 0, never into 7.
drive_label 'GraphQL: API rate limit already exceeded for user ID 32601161.' 1
label_row "81 gh failing is CANNOT READ on 8, not 'no hold'" 8 \
  "PR-LABEL HOLD CANNOT READ" "no claim that your PR is held, and none that it is clear"

# 82. CANNOT READ — gh exited 0 and produced NOTHING. THE #18497 SHAPE: an empty
# read must not render as an empty label set. The retired merge-check arm read
# `join(",")`, which renders BOTH as "", and published "not held".
drive_label '' 0
label_row "82 an EMPTY read at exit 0 is CANNOT READ, not 'not held'" 8 \
  "PR-LABEL HOLD CANNOT READ" "an empty read is not an empty label set"

# 83. CANNOT READ — output that is not a JSON array of names.
drive_label 'no pull requests found for branch "x"' 0
label_row "83 an unparseable read is CANNOT READ" 8 "did not parse as a JSON array"

# 84. CONTROL FOR 82: the retired join(",") reader really does collapse the two
# cases, or row 82 pins nothing. Both inputs yield the SAME empty string, and the
# retired glob then reports "not held" for both.
_j_empty="$(printf '%s' '{"labels":[]}' | jq -r '[.labels[].name]|join(",")')"
_j_none=""
if [ "$_j_empty" = "$_j_none" ]; then
  case "$_j_empty" in
    *hold*) fail=$((fail + 1)); echo "  FAIL 84 CONTROL: the retired glob matched an empty string" >&2 ;;
    *) pass=$((pass + 1)); echo "  ok   84 CONTROL the retired join(\",\") reader renders 'no labels' and 'no read' identically, and its glob calls both 'not held'" ;;
  esac
else
  fail=$((fail + 1)); echo "  FAIL 84 CONTROL: join(\",\") did not collapse the two cases — row 82 pins nothing" >&2
fi

# 85. WIRED INTO main(), and FIRST — before preflight_hold and before the
# pre-flight that spends API reads. A hold is the cheapest possible refusal and
# must not be reached only after the expensive ones agree.
if awk '/^  preflight_label_hold$/ {seen=1} /^  preflight_hold$/ {print (seen ? "OK" : "LATE"); exit}' \
     "$ROOT/scripts/bp-merge.sh" | grep -q OK; then
  pass=$((pass + 1)); echo "  ok   85 main() runs preflight_label_hold BEFORE preflight_hold"
else
  fail=$((fail + 1)); echo "  FAIL preflight_label_hold is not called before preflight_hold in main()" >&2
fi

# 86. THE TWO HOLDS STAY ON DIFFERENT CODES. Row 77 says 7 and row 60 says 5; if
# a later edit folds them, an operator cannot tell which claim they answered.
if [ "$(grep -c 'exit 7' "$ROOT/scripts/bp-merge.sh")" -ge 1 ] \
   && [ "$(grep -c 'exit 8' "$ROOT/scripts/bp-merge.sh")" -ge 1 ] \
   && [ "$(grep -c 'exit 5' "$ROOT/scripts/bp-merge.sh")" -ge 1 ] \
   && [ "$(grep -c 'exit 6' "$ROOT/scripts/bp-merge.sh")" -ge 1 ]; then
  pass=$((pass + 1)); echo "  ok   86 label hold (7/8) and main-red hold (5/6) are separate codes"
else
  fail=$((fail + 1)); echo "  FAIL the two hold claims no longer carry distinct exit codes" >&2
fi

# 87. AND THE EXIT-CODE DOC BLOCK MATCHES THE CODE. A documented contract that
# drifts from the implementation is how a caller learns the wrong thing.
_doc="$(bash "$ROOT/scripts/bp-merge.sh" --help 2>&1)"
if hold_has "$_doc" "7 PR-LABEL HOLD" && hold_has "$_doc" "8 PR-LABEL HOLD CANNOT READ"; then
  pass=$((pass + 1)); echo "  ok   87 --help documents exit 7 and exit 8"
else
  fail=$((fail + 1)); echo "  FAIL --help does not document the new exit codes" >&2
fi

unset -f drive_label label_row
unset PR_NUMBER

# ── 88-100. THE pipefail SIGPIPE SCAN PRE-FLIGHT ────────────────────────────
#
# DRIVEN THROUGH THE REAL preflight_sigpipe(). `gh` is stubbed so both of its
# reads — the PR's file list and the head's check runs — return what this file
# chooses, and NOTHING here touches the network.
#
# EVERY ARM BELOW HAS ITS OPPOSITE IN THIS SAME RUN. A guard that refused
# everything would pass the RED rows and fail the CLEAR ones; a guard that
# refused nothing would pass the CLEAR rows and fail the RED ones. Neither
# direction is evidence without the other, and that is the whole reason the
# NOT-APPLICABLE and success rows are here at all.
#
# preflight_sigpipe exits rather than returning, so every row runs it in a
# SUBSHELL and reads the exit code on the very next line.
SIG_TMP="$(mktemp -d)"
SIG_FILES=""
SIG_CHECKS=""

gh() {
  case "$1" in
    pr)  case "${2:-}" in
           view) printf '%s\n' "$SIG_FILES" ;;
           *)    printf 'sigpipe stub: unexpected `gh pr %s`\n' "${2:-}" >&2; return 1 ;;
         esac ;;
    api) printf '%s' "$SIG_CHECKS" ;;
    *)   printf 'sigpipe stub: unexpected `gh %s`\n' "$1" >&2; return 1 ;;
  esac
}

PR_NUMBER=321
HEAD_SHA=cafebabecafebabecafebabecafebabecafebabe
REPO_ROOT="$ROOT"
SIGPIPE_SCRIPT="$ROOT/scripts/pipefail-sigpipe-scan.sh"

sig_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

drive_sig() { # files checks -> SIG_RC, SIG_OUT
  SIG_FILES="$1"; SIG_CHECKS="$2"; SIG_RC=0
  SIG_OUT="$( preflight_sigpipe 2>&1 )" || SIG_RC=$?
}

sig_row() { # label want_rc needle...
  local label="$1" want="$2"; shift 2
  local bad="" n
  [ "$SIG_RC" = "$want" ] || bad="exit $SIG_RC (wanted $want)"
  for n in "$@"; do
    sig_has "$SIG_OUT" "$n" || bad="$bad; missing '$n'"
  done
  if [ -z "$bad" ]; then
    pass=$((pass + 1)); echo "  ok   $label (exit $SIG_RC)"
  else
    fail=$((fail + 1)); echo "  FAIL $label: $bad" >&2
    printf '%s\n' "$SIG_OUT" | sed 's/^/       /' >&2
  fi
}

# A check-run row is completed_at \t status \t conclusion \t url, exactly the
# shape read_sigpipe_check's --jq emits.
sig_check() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-https://example/run/1}"; }
# TWO rows under the SAME name, joined by a REAL newline. `$(a)$(b)` glues
# them into one line, because $() strips the trailing newline — and a glued
# fixture makes the ordering rows below pass while measuring nothing. That is
# not hypothetical: it happened to row 99c on the first run of this section.
sig_pair() { printf '%s\n%s\n' "$(sig_check "$1" "$2" "$3")" "$(sig_check "$4" "$5" "$6")"; }

echo
echo "── 88-100. pipefail SIGPIPE scan pre-flight ──"

# 88. THE ROOTS ARE DERIVED FROM THE SCANNER, NOT ENUMERATED HERE. This is the
# arm a hard-coded `scripts|.github|deploy` list CANNOT pass: the fixture
# scanner declares a FOURTH root that exists nowhere in this repo, and the
# reader must follow it. Its opposite is row 89b, where the same reader must
# still say NO to a path under none of them.
cat > "$SIG_TMP/fake-scan.sh" <<'FAKE'
#!/usr/bin/env bash
targets=("$ROOT/scripts" "$ROOT/.github" "$ROOT/deploy" "$ROOT/zzz-fourth")
FAKE
_got="$( SIGPIPE_SCRIPT="$SIG_TMP/fake-scan.sh" sigpipe_roots | tr '\n' ' ' )"
if [ "$_got" = "scripts .github deploy zzz-fourth " ]; then
  pass=$((pass + 1)); echo "  ok   88 the scanned roots are DERIVED from the scanner (followed a 4th root)"
else
  fail=$((fail + 1)); echo "  FAIL 88 sigpipe_roots did not follow the scanner: got '$_got'" >&2
fi

# 88b. AND AN UNPARSEABLE SCANNER IS 2, NEVER 1. "I could not find the roots"
# must never be folded into "this PR touches none of them" — that fold is the
# fail-open door this whole block exists to close.
_rc=0; SIGPIPE_SCRIPT=/dev/null sigpipe_touches "scripts/x.sh" || _rc=$?
SIGPIPE_SCRIPT="$ROOT/scripts/pipefail-sigpipe-scan.sh"
if [ "$_rc" = "2" ]; then
  pass=$((pass + 1)); echo "  ok   88b an underivable root set is 2 (unanswered), never 1 (not applicable)"
else
  fail=$((fail + 1)); echo "  FAIL 88b underivable roots returned $_rc, wanted 2" >&2
fi

# 89. NOT APPLICABLE — a PR under none of the roots passes without ever reading
# a check run. The stub would ERROR on `gh api`, so this row also proves the
# reader is not consulted.
drive_sig "api/lib/barkpark/x.ex
web/app/page.tsx" "SHOULD-NOT-BE-READ"
sig_row "89 a PR touching no scanned root is NOT APPLICABLE" 0 "NOT APPLICABLE"

# 89b. AND THE DOT IS ESCAPED. `.githubfoo/` is not `.github/`; an unescaped
# regex dot makes the guard claim a PR touches a root it does not.
drive_sig ".githubfoo/x.yml" "SHOULD-NOT-BE-READ"
sig_row "89b .githubfoo/ is NOT .github/ (the dot is escaped)" 0 "NOT APPLICABLE"

# 90. GREEN — a touching PR whose scan succeeded merges. Without this row the
# refusal rows below prove only that something always refuses.
drive_sig "scripts/bp-merge.sh" "$(sig_check 2026-09-22T10:00:00Z completed success)"
sig_row "90 a touching PR with a SUCCESS verdict passes" 0 "concluded success"

# 91. RED — and it NAMES THE FILE AND THE LINE. The path fed in is not a
# literal: it is read from a LIVE scan of this repo, so the row cannot go
# vacuous the day that site is repaired, and it cannot pass on a refusal that
# merely says "the ratchet broke".
# The candidate list is read into an ARRAY, never `grep -rl … | head`: this
# harness must not host the defect it tests, and a truncating reader here would
# be flagged by the very scanner it drives. Each candidate is confirmed with a
# SINGLE-FILE scan (0.1s) rather than a whole-tree one (36.9s measured).
_sitepath=""; _sitefile=""
_cands=()
while IFS= read -r _c; do [ -n "$_c" ] && _cands+=("$_c"); done < <(
  grep -rlE '\|[[:space:]]*head[[:space:]]' "$ROOT/scripts" 2>/dev/null || true )
for _c in "${_cands[@]}"; do
  _o="$(bash "$ROOT/scripts/pipefail-sigpipe-scan.sh" --min-confidence high "$_c" 2>/dev/null || true)"
  _sitepath="$(grep -m1 -oE "^$ROOT/[^:]+:[0-9]+:" <<<"$_o" || true)"
  [ -n "$_sitepath" ] && break
done
_sitefile="${_sitepath#$ROOT/}"; _sitefile="${_sitefile%%:*}"
if [ -z "$_sitefile" ]; then
  fail=$((fail + 1)); echo "  FAIL 91 PRECONDITION: a live scan of this repo reported NO high finding, so the naming arm would measure nothing" >&2
else
  drive_sig "$_sitefile" "$(sig_check 2026-09-22T10:00:00Z completed failure https://example/run/red)"
  sig_row "91 a RED verdict refuses and names the site in this PR's own files" 9 \
    "SIGPIPE SCAN RED" "HIGH-confidence site(s)" "${_sitepath%:}" "https://example/run/red" "grep -m1"
fi

# 92. RED with NO site in this PR's own files — the honest wording. The ratchet
# is a whole-tree count, so this red may be inherited; the refusal must say so
# rather than accuse the author of a line they did not write.
drive_sig ".github/workflows/nonexistent-for-this-test.yml" "$(sig_check 2026-09-22T10:00:00Z completed failure)"
sig_row "92 a RED with no site in the PR's own files says it may be INHERITED" 9 \
  "SIGPIPE SCAN RED" "may be INHERITED from main" "--verify-against-origin-main"

# 93. THE DOOR OPENS ONLY WITH BOTH HALVES, and it prints them.
SIG_FILES="scripts/bp-merge.sh"; SIG_CHECKS="$(sig_check 2026-09-22T10:00:00Z completed failure)"
SIG_RC=0
SIG_OUT="$( BP_MERGE_SIGPIPE_OVERRIDE_WHO="lead-infra-r21o" BP_MERGE_SIGPIPE_OVERRIDE_WHY="inherited from main, see #1" \
            preflight_sigpipe 2>&1 )" || SIG_RC=$?
sig_row "93 a COMPLETE override merges and records who and why" 0 \
  "SIGPIPE SCAN OVERRIDE" "lead-infra-r21o" "inherited from main, see #1"

# 93b. AND HALF A DOOR IS NO DOOR. A single variable is a shrug; the pair is a
# sentence someone wrote.
SIG_RC=0
SIG_OUT="$( BP_MERGE_SIGPIPE_OVERRIDE_WHO="lead-infra-r21o" preflight_sigpipe 2>&1 )" || SIG_RC=$?
sig_row "93b a PARTIAL override refuses and names the missing half" 9 \
  "OVERRIDE INCOMPLETE" "BP_MERGE_SIGPIPE_OVERRIDE_WHY" "MISSING"

# 94. NOT CONCLUDED is not green. An advisory still running has measured
# nothing yet, and merging on it is merging on an absence.
#
# AND IT MUST NAME THE STATUS IT READ. This row used to assert only the words
# "NOT CONCLUDED" and exit 9, and it PASSED over a two-field shift that made
# the refusal quote a URL where it meant to quote a status — caught only by a
# live run against head dd6d77d10, never by this harness. The reassuring word
# was the true one; the field beside it was the false one. So the row now pins
# the field: the reader emits "-" for a value GitHub did not send, and a queued
# row must still come back as the STATUS.
drive_sig "scripts/bp-merge.sh" "$(sig_check - in_progress -)"
sig_row "94 an UNCONCLUDED verdict refuses (an absence is not a pass)" 9 \
  "NOT CONCLUDED" "is 'in_progress'"

# 94b. THE SAME ROW WITH THE QUEUED SHAPE, and a url that must NOT be read as a
# status. This is the exact specimen that shifted.
drive_sig "scripts/bp-merge.sh" "$(sig_check - queued - https://example/run/queued)"
sig_row "94b a QUEUED row names the status, never the url" 9 \
  "is 'queued'" "RUN: https://example/run/queued"

# 95. CANCELLED measured nothing — 10, not 9 and never 0. A superseded run is
# neither a red nor a green, and folding it into either is a lie in one
# direction or the other.
drive_sig "scripts/bp-merge.sh" "$(sig_check 2026-09-22T10:00:00Z completed cancelled)"
sig_row "95 a CANCELLED verdict is CANNOT READ (10), not a pass and not a red" 10 "CANNOT READ" "MEASURED NOTHING"

# 96. AN UNKNOWN CONCLUSION IS NEVER FOLDED INTO A PASS. This is the row the
# whole file exists for, one class down: a parser that assumes green on a
# string it does not know is the vacuous pass this epic abolishes.
drive_sig "scripts/bp-merge.sh" "$(sig_check 2026-09-22T10:00:00Z completed some_future_conclusion)"
sig_row "96 an UNKNOWN conclusion refuses, never passes" 10 "not a conclusion this block classifies"

# 97. ABSENT is not clean. The workflow carries no workflow-level `paths:`, so
# on a touching head the name MUST render; nothing rendering means the read
# failed or the wiring broke, and either way nothing was measured.
drive_sig "scripts/bp-merge.sh" ""
sig_row "97 an ABSENT check run on a touching head is CANNOT READ, not clean" 10 "ABSENT verdict is not a clean one"

# 98. A ZERO-FILE PR IS A FAILED READ. `gh pr view --json files` returning
# nothing is not a PR that changed nothing; NOT APPLICABLE off zero paths
# asserts nothing at all.
drive_sig "" ""
sig_row "98 a ZERO-file PR is a failed read, never NOT APPLICABLE" 10 "ZERO changed files"

# 99. LATEST-BY-completed_at, BOTH DIRECTIONS, over the SAME two rows. A re-run
# publishes a second row under the same name; a reader that takes the first row
# it sees, or orders by started_at, gets this backwards. Only the pair proves
# the ordering — one direction alone passes on a reader that always takes row 1
# or always takes row 2.
drive_sig "scripts/bp-merge.sh" "$(sig_pair 2026-09-22T09:00:00Z completed failure 2026-09-22T11:00:00Z completed success)"
sig_row "99 old RED then new GREEN -> the GREEN wins" 0 "concluded success"
drive_sig "scripts/bp-merge.sh" "$(sig_pair 2026-09-22T09:00:00Z completed success 2026-09-22T11:00:00Z completed failure)"
sig_row "99b old GREEN then new RED -> the RED wins" 9 "SIGPIPE SCAN RED"

# 99c. AND THE ORDER THE API HAPPENS TO RETURN THEM IN MUST NOT MATTER. Same
# two rows as 99, emitted newest-first: a reader that trusted arrival order
# would flip here and nowhere else.
drive_sig "scripts/bp-merge.sh" "$(sig_pair 2026-09-22T11:00:00Z completed success 2026-09-22T09:00:00Z completed failure)"
sig_row "99c arrival order does not decide it — completed_at does" 0 "concluded success"

# 100. WIRED INTO main(), AFTER the two holds (which are free) and BEFORE the
# pre-flight that spends API reads on the required set. A guard that runs only
# after the expensive checks agree is a guard that usually does not run.
if awk '/^  preflight_hold$/ {seen=1} /^  preflight_sigpipe$/ {print (seen ? "OK" : "EARLY"); exit}' \
     "$ROOT/scripts/bp-merge.sh" | grep -q OK \
   && awk '/^  preflight_sigpipe$/ {seen=1} /^  preflight$/ {print (seen ? "OK" : "LATE"); exit}' \
        "$ROOT/scripts/bp-merge.sh" | grep -q OK; then
  pass=$((pass + 1)); echo "  ok   100 main() runs preflight_sigpipe after the holds and before preflight"
else
  fail=$((fail + 1)); echo "  FAIL 100 preflight_sigpipe is not wired between preflight_hold and preflight" >&2
fi

# 100b. THE EXIT CODES ARE DISTINCT FROM EVERY OTHER CLAIM, and --help says so.
# Folding this onto 1 or 5 means the operator cannot tell which claim they just
# answered — the same rule rows 86 and 87 hold for the two holds.
_sigdoc="$(bash "$ROOT/scripts/bp-merge.sh" --help 2>&1)"
if sig_has "$_sigdoc" "9 SIGPIPE SCAN RED" && sig_has "$_sigdoc" "10 SIGPIPE SCAN CANNOT READ"; then
  pass=$((pass + 1)); echo "  ok   100b --help documents exit 9 and exit 10"
else
  fail=$((fail + 1)); echo "  FAIL 100b --help does not document the sigpipe exit codes" >&2
fi

unset -f sig_has sig_row drive_sig sig_check sig_pair
unset SIG_FILES SIG_CHECKS SIG_RC SIG_OUT
rm -rf "$SIG_TMP"

unset -f gh hold_has hold_row drive_hold drive_hold_ov
rm -rf "$HOLD_TMP"

echo
echo "bp-merge harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "HARNESS OK — every arm of the refusal table is exercised, and an unknown string refuses."
