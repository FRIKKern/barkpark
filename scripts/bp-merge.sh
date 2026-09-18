#!/usr/bin/env bash
# bp-merge.sh — the fleet's merge verb, as one argument-free command.
#
# THIS IS A THIN WRAPPER AND NEVER A REQUIRED DEPENDENCY (honest-gates D55).
#
#   With the required context green, plain `gh pr merge --squash` — no flags at
#   all — merges under `enforce_admins: true`, exit 0 (measured 2026-07-28,
#   mergedAt 12:40:57Z). An agent that never learns this script exists still
#   merges correctly and still respects protection. Nothing here is load-bearing
#   for correctness; it adds a pre-flight and a bounded wait, nothing else. If
#   this file is broken, missing, or you simply do not trust it, run
#   `gh pr merge --squash --delete-branch` by hand and read what gh tells you —
#   gh prints both escape hatches itself when it blocks.
#
# WHAT IT ADDS
#
#   1. DEADLOCK PRE-FLIGHT, FIRST. It calls scripts/required-checks-verify.sh
#      --deadlock (it does NOT reimplement it — D14) before spending a single
#      minute waiting. A head that can never satisfy the required set is named
#      up front instead of after twenty minutes of polling.
#   1b. A mergeable_state PRE-FLIGHT (one REST read, the same one pr-required.sh
#      makes). A 4/4-green PR goes CONFLICTING the moment a sibling lands on a
#      file it touches, and on this fleet that happens several times an hour.
#      Reading it here names DIRTY before the merge call is spent, and treats
#      `unknown` as "GitHub has not computed it yet", never as clean.
#   2. A bounded wait, then a merge on green.
#   3. Over budget: it prints the PR URL and the re-run command and exits
#      non-zero. It does NOT hand off to auto-merge. `allow_auto_merge` stays
#      FALSE (D53: gh forwards `expectedHeadOid` to the enable mutation and
#      GitHub accepts-and-ignores it, so the pin is a placebo, and the flag is
#      unreadable afterwards — write-only safety is not safety).
#   4. Red: it refuses and QUOTES gh's own refusal verbatim.
#
#   It never passes the admin bypass and never queues the merge; the two flags
#   this repo's merge protocol must stop using appear nowhere below except in
#   these comments. The merge is a plain `gh pr merge --squash --delete-branch`.
#
# THE EXIT TABLE IS KEYED ON THE REFUSAL STRING, NEVER THE EXIT CODE (D54)
#
#   Measured on a freshly protected throwaway base: EVERY refusal shape exits 1
#   — deadlock, red, cancelled, pending, plural and gh's own client-side block.
#   The exit code carries no information at all, so the classifier below reads
#   the message. NINE named arms plus an explicit UNRECOGNISED default that
#   refuses (count derived 2026-09-13:
#     awk '/^classify_refusal\(\) \{/,/^\}/' scripts/bp-merge.sh | grep -cE "printf '[A-Z_]+"
#   answers 10 — the nine below plus the default. The old header said 'Six',
#   which had been stale since LOCAL_POST_MERGE and DIRTY landed):
#
#     "base branch policy prohibits"      CLIENT_BLOCK  gh blocked locally; the API was never reached
#     "N of M required status checks…"    PLURAL        carries counts and CATEGORIES, never names, and
#                                                       the categories DO NOT SUM ("2 of 2 … : 1 expected."),
#                                                       so it falls through to the set-difference detector
#     "… is expected."                    DEADLOCK      the context never rendered on this head
#     "… is failing."                     RED           RE-RUN FIRST, then investigate (D57)
#     "… is cancelled."                   RERUN         a superseded run, not a code defect
#     "… is in progress."                 WAIT          ABSENT from D38, and the most common real state
#     "failed to delete local branch …
#      … checked out at …"                LOCAL_POST_MERGE  NOT a merge refusal at all: gh's own local
#                                                       branch-delete, which runs only AFTER the merge
#                                                       call returned. See merged_despite_error.
#     "is not mergeable: the merge
#      commit cannot be cleanly created"  DIRTY         MEASURED 2026-09-11 on PR #17612: pr-required.sh
#                                                       printed 4/4 at 03:56Z, a sibling merged, and by
#                                                       04:05Z the head CONFLICTED with main. Nothing is
#                                                       wrong with the checks; the branch needs a rebase.
#                                                       BOTH needles are required — "is not mergeable:"
#                                                       ALSO prefixes the CLIENT_BLOCK message, so the
#                                                       first needle alone would swallow that arm.
#     "Base branch was modified. Review
#      and try the merge again."          BASE_MODIFIED TRANSIENT. MEASURED twice on 2026-09-13 (the api
#                                                       and studio lanes): GitHub raced our merge against
#                                                       another landing on the same base, and a by-hand
#                                                       retry merged FIRST TRY in both cases. The ONLY arm
#                                                       here that retries, and it retries AT MOST ONCE,
#                                                       after RE-READING mergeable_state — never off the
#                                                       stale read that produced the error. A second
#                                                       failure, or a re-read that no longer reports the
#                                                       head mergeable, takes the ordinary refusal path.
#     anything else                       UNRECOGNISED  refuse loudly — NEVER assume green
#
#   The `is failing.` row advises a re-run before any code investigation because
#   `Elixir gate` LAUNDERS cancellation into failure (D57): elixir.yml's
#   aggregator is `if: always()` and its decide() has no `cancelled` arm, so five
#   cancelled upstream jobs conclude `failure` and GitHub refuses the merge with
#   `… is failing.` On a fleet that force-pushes stacked branches daily, a
#   superseded run is indistinguishable from a real bug at the required-context
#   level. Re-run first. It is thirty seconds and it is right most of the time.
#
# EXIT CODES (this script's own; unrelated to gh's, which is always 1)
#   0 merged (INCLUDING the case where gh exited non-zero on its own local
#     post-merge step after the server-side merge landed — the state is read
#     back from the API, never inferred from the exit code; see merge_loop)
#   1 refused (see the quoted message) · 2 over budget
#   4 CONFLICTING/DIRTY: the head cannot be merged into the base without a
#     conflict. Either the mergeable_state pre-flight read `dirty` (and the
#     merge call was never spent) or gh's own refusal carried the DIRTY string.
#     Distinct from 1 on purpose: 1 says "the checks are not right yet" and a
#     caller may sensibly wait; 4 says WAITING WILL NEVER HELP — a human or an
#     agent must rebase the branch. Distinct from 3, which is the DETECTOR's
#     verdict about the required-context set, not about the diff.
#   3 the PRE-FLIGHT or the set-difference detector refused: this head can never
#     go green as it stands (DEADLOCK, or a required context concluded in a
#     state nothing re-reports). Precise scope, stated because it is easy to
#     misread: a DEADLOCK or RERUN learned from GH's OWN refusal string mid-loop
#     exits 1 like every other quoted refusal — 3 means the DETECTOR said so.
#   5 MAIN-RED HOLD: this PR changes a file under a tree recorded in
#     .github/main-red-holds.json as RED ON MAIN with a reproduction and an
#     owner. Distinct from 1 and from 3 because it is not a finding about the
#     PR's checks at all — the PR may be 4/4 green. It releases when the hold
#     lifts (`scripts/main-red-hold.sh lift --id <id>`, which re-measures) or
#     when it is OVERRIDDEN ON THE RECORD by the three
#     BP_MERGE_HOLD_OVERRIDE_* variables, which post the authorisation to the
#     PR before merging. An incomplete override, an override naming a hold this
#     PR is not held by, and an override whose record could not be posted all
#     exit 5 too: the hold stood in every one of those cases.
#   6 HOLD CHECK CANNOT READ: the hold registry, or this PR's file list, could
#     not be read — so NOTHING was measured about holds. Never folded into 0.
#     A merge path that fails OPEN on a hold is strictly worse than no hold at
#     all, so an unreadable registry refuses. Exit 6 has no override door.
#   7 PR-LABEL HOLD: this PR carries the `hold` label on GitHub. A DIFFERENT
#     CLAIM FROM 5, and deliberately a different code. 5 is a statement about
#     MAIN ("this tree is red on main"), derived from a committed registry and
#     scoped per-file; 7 is a statement about THIS PR ("a human put it on
#     hold"), derived from the PR's own labels and scoped to the whole PR. They
#     stay on different arms for the same reason the verifier's 4 and the
#     required-checks suite's 4 do: folding two claims onto one code means the
#     operator cannot tell which one they answered. There is NO override door
#     on 7 — the door is `gh pr edit <n> --remove-label hold`, which is one
#     command, is visible on the PR, and is the deliberate act the label exists
#     to require.
#   8 PR-LABEL HOLD CANNOT READ: the PR's label set could not be read, or did
#     not parse — so NOTHING was measured about a label hold. Same doctrine as
#     6: an unread label is not an absent hold, and a merge path that fails
#     OPEN on a hold is strictly worse than no hold at all.
#
# USAGE
#   scripts/bp-merge.sh              # no arguments; the PR is derived from HEAD
#   BP_MERGE_BUDGET_SECONDS=2400 scripts/bp-merge.sh
#   BP_MERGE_POLL_SECONDS=15 scripts/bp-merge.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO_ROOT/scripts/required-checks-verify.sh"

BUDGET_SECONDS="${BP_MERGE_BUDGET_SECONDS:-1200}"
POLL_SECONDS="${BP_MERGE_POLL_SECONDS:-30}"

# THE PRE-FLIGHT OPTS IN TO THE SHARED READER'S BOUNDED RETRY (default OFF).
#
# Measured 2026-09-11: three of five merges refused at the pre-flight with
# `BLOCKED: … cannot read check runs for <sha>` and the identical command, run
# by hand 15-20 s later against the same head with no push between, read the
# feed and merged. GitHub's check-runs pagination is not a snapshot; the reader
# refuses a set whose accumulated length disagrees with the `total_count` page
# one reported, and it is RIGHT to. The defect was that the thing which retried
# was a human.
#
# THIS IS THE ONLY CALLER THAT SHOULD SET IT. scripts/lib/check-runs.sh leaves
# the ladder off by default because its loop-over-many-heads consumers
# (registration-sample.sh, required-checks-generate.sh) would pay a sleep per
# head for a hole they already tolerate. This reads ONE head, and its refusal
# costs a human a manual rerun — so it is the case the ladder exists for.
# Exported so it reaches the reader through `bash "$VERIFY"`, a child process.
#
# IT BUYS NO GREEN IT DID NOT HAVE. The ladder retries ONLY transient READ
# classes; a missing required context, a red one, a DIRTY head — every actual
# refusal — is unreachable from it, and a read that never settles refuses in the
# incumbent wording. Override it (including back to 1) from the environment.
export BARKPARK_CHECK_RUNS_RETRIES="${BARKPARK_CHECK_RUNS_RETRIES:-3}"
export BARKPARK_CHECK_RUNS_RETRY_SLEEP="${BARKPARK_CHECK_RUNS_RETRY_SLEEP:-10}"

PR_NUMBER=""
PR_URL=""
HEAD_SHA=""

die() { echo "bp-merge: $*" >&2; exit 1; }

# ── the classifier ───────────────────────────────────────────────────────────
# Pure: one string in, one state token out. No I/O, no gh, no clock — this is
# the whole reason scripts/bp-merge.test.sh can drive it over captured fixture
# strings without touching GitHub.
#
# ORDER IS LOAD-BEARING. The plural arm must precede the singular ones: the
# plural forms read `… are expected.` / `… have not succeeded: 1 expected and 1
# failing.` and would otherwise be swallowed by the RED or DEADLOCK arm and
# reported with a confidence the message does not support.
classify_refusal() {
  case "$1" in
    *"base branch policy prohibits"*) printf 'CLIENT_BLOCK\n' ;;
    *"required status checks"*)       printf 'PLURAL\n' ;;
    *"is expected."*)                 printf 'DEADLOCK\n' ;;
    *"is failing."*)                  printf 'RED\n' ;;
    *"is cancelled."*)                printf 'RERUN\n' ;;
    *"is in progress."*)              printf 'WAIT\n' ;;
    # NOT A MERGE REFUSAL. gh runs its local branch-delete only AFTER the merge
    # call returned, so this string is only ever emitted about a merge that
    # already went to the server; git is refusing to delete a branch another
    # WORKTREE has checked out, which is the resting state of this fleet.
    #
    # WHETHER IT LANDED IS STILL THE API'S QUESTION, NOT THIS TABLE'S:
    # merge_loop calls merged_despite_error() first and it wins, so this arm is
    # reached only when the state read did NOT confirm MERGED. All it changes is
    # the ADVICE — UNRECOGNISED sends the reader to re-merge by hand, and on this
    # shape that is an instruction to re-merge an already-merged PR.
    #
    # BOTH NEEDLES ARE REQUIRED, and the match is deliberately not widened to
    # every "failed to run git": a branch-delete that failed for some other
    # reason is not a worktree collision, and a message-shaped guess about
    # whether a merge landed is the vacuous pass in the other direction.
    *"failed to delete local branch"*"checked out at "*)
                                      printf 'LOCAL_POST_MERGE\n' ;;
    # PLACED BELOW ALL SEVEN ARMS ABOVE so it cannot change what any of them
    # means, and keyed on BOTH needles. The first needle alone is a trap: the
    # CLIENT_BLOCK message is "… is not mergeable: the base branch policy
    # prohibits the merge.", so a bare *"not mergeable"* arm placed anywhere
    # above it would relabel every client-side block as a conflict. The second
    # needle is GitHub's own conflict sentence and appears nowhere else.
    *"is not mergeable"*"the merge commit cannot be cleanly created"*)
                                      printf 'DIRTY\n' ;;
    # TRANSIENT, and the only arm this script ever retries. GitHub emits this
    # from the merge mutation when the base advanced between the mergeability
    # snapshot it took and the merge it tried to write — a race, not a verdict
    # about this head. Measured twice on 2026-09-13 (api and studio lanes): the
    # by-hand retry merged first try both times, and before this arm existed the
    # table answered UNRECOGNISED, which is the right SHAPE and the wrong
    # COVERAGE — a named, safe-to-retry-once condition read as an unknown one.
    #
    # The needle is GitHub's own sentence and appears in no other measured
    # shape. It is deliberately NOT widened to "was modified": the retry is a
    # WRITE, and a message-shaped guess about which writes are safe to repeat is
    # exactly the vacuous pass the rest of this table refuses.
    *"Base branch was modified"*)      printf 'BASE_MODIFIED\n' ;;
    *)                                printf 'UNRECOGNISED\n' ;;
  esac
}

# Exactly one named resolving command per state. A state whose advice is "look
# into it" is not advice; if you cannot name the command, the row is not done.
refusal_advice() {
  # $4 is an OPTIONAL run id resolved BY THE CALLER — this function stays pure
  # (no gh, no I/O, no clock) so bp-merge.test.sh can drive the whole table
  # over captured fixtures. An empty $4 degrades to the placeholder plus the
  # command that looks the id up — never a wrong id.
  local state="$1" pr="${2:-<pr>}" sha="${3:-<sha>}" run_id="${4:-}"
  case "$state" in
    CLIENT_BLOCK)
      # THE DOMINANT POST-FLIP ARM (D79). gh reads `mergeStateStatus: BLOCKED`
      # from its own GraphQL query and refuses locally, so the merge API is
      # never called and the server never gets to say WHICH context blocked.
      # A JSON dump is not advice: `statusCheckRollup` lists every check on the
      # head, advisory ones included, and says nothing about which of them the
      # branch actually requires. The set difference against the committed spec
      # is the only thing that answers that, exactly as for DEADLOCK and PLURAL.
      printf 'gh blocked this CLIENT-SIDE from its own read of the base branch policy; the merge API was never called,\n'
      printf 'so nothing here names the blocking context. This is the most common refusal under branch protection.\n'
      printf 'RESOLVE: scripts/required-checks-verify.sh --deadlock --sha %s\n' "$sha"
      printf 'THEN:    gh pr checks %s          # for a required context that rendered but is red or still running\n' "$pr"
      ;;
    PLURAL)
      printf 'A plural refusal carries COUNTS and CATEGORIES, never names — and the categories DO NOT SUM\n'
      printf '(measured: "2 of 2 required status checks have not succeeded: 1 expected."). At N>1 the set\n'
      printf 'difference against the committed spec is the ONLY way to learn which context is missing (D38).\n'
      printf 'RESOLVE: scripts/required-checks-verify.sh --deadlock --sha %s\n' "$sha"
      ;;
    DEADLOCK)
      printf 'A required context never rendered on this head, so GitHub will report it "expected" forever.\n'
      printf 'RESOLVE: scripts/required-checks-verify.sh --deadlock --sha %s\n' "$sha"
      ;;
    RED)
      printf 'A required context concluded FAILURE — but RE-RUN FIRST, BEFORE reading any code: "Elixir gate"\n'
      printf 'launders cancellation into failure (D57), and on a fleet that force-pushes stacked branches a\n'
      printf 'superseded run is indistinguishable from a real defect at the required-context level.\n'
      if [ -n "$run_id" ]; then
        printf 'RESOLVE: gh run rerun --failed %s\n' "$run_id"
      else
        printf 'RESOLVE: gh run rerun --failed <run-id>          # gh pr checks %s  prints the run links\n' "$pr"
      fi
      ;;
    RERUN)
      printf 'A required context concluded CANCELLED — a superseded run, not a code defect. It blocks with\n'
      printf 'neither "is failing." nor "is expected.", and nothing will ever re-report it on its own.\n'
      if [ -n "$run_id" ]; then
        printf 'RESOLVE: gh run rerun --failed --repo FRIKKern/barkpark %s\n' "$run_id"
      else
        printf 'RESOLVE: gh run rerun --failed --repo FRIKKern/barkpark <run-id>          # gh pr checks %s  prints the run links\n' "$pr"
      fi
      ;;
    WAIT)
      printf 'A required context is still running. This is the most common state and it is not an error.\n'
      printf 'RESOLVE: gh pr checks %s --watch\n' "$pr"
      ;;
    LOCAL_POST_MERGE)
      printf 'NOT A MERGE REFUSAL. gh emitted this from its own LOCAL branch-delete, which runs only\n'
      printf 'AFTER the merge call returned — git will not delete a branch another WORKTREE has checked\n'
      printf 'out, and on this fleet every agent works in one. The merge very likely LANDED; the state\n'
      printf 'read above is what could not confirm it, so this is reported rather than assumed.\n'
      printf 'RESOLVE: gh pr view %s --json state,mergedAt      # confirm — do NOT re-merge on this message\n' "$pr"
      printf 'THEN:    if it MERGED, the remote head branch is probably still there — gh never reached\n'
      printf '         its delete either. gh pr view %s --json headRefName,isCrossRepository names it;\n' "$pr"
      printf '         delete that ref in the BASE repo only when isCrossRepository is false (a fork PR\n'
      printf '         head name resolves to a DIFFERENT branch here).\n'
      ;;
    DIRTY)
      printf 'CONFLICTING. GitHub cannot create the merge commit: this head and the base touch the same\n'
      printf 'lines. This is NOT a finding about the required contexts — they can be 4/4 green and this\n'
      printf 'still refuses (measured 2026-09-11 on #17612: green at 03:56Z, a sibling landed, dirty by\n'
      printf '04:05Z). Waiting will never clear it; only a rebase will.\n'
      printf 'RESOLVE: rebase the PR BRANCH onto origin/main IN ITS OWN WORKTREE, then re-push:\n'
      printf '           git -C <the branch'"'"'s worktree> fetch origin main\n'
      printf '           git -C <the branch'"'"'s worktree> rebase origin/main       # resolve, then --continue\n'
      printf '           git -C <the branch'"'"'s worktree> push --force-with-lease\n'
      printf 'THEN:    wait for the required contexts to re-render on the NEW head, and run this again.\n'
      printf 'NOT:     gh will have offered to queue the merge for later instead. Do not take it — this\n'
      printf '         repo keeps unattended merging switched OFF (D53), so the queue never fires, and\n'
      printf '         queueing a conflict does not resolve the conflict either way.\n'
      printf 'NOT:     gh also prints a local "git merge origin/main" recipe. It works, and it puts a\n'
      printf '         MERGE commit on a branch this repo squash-merges; the rebase above is the form\n'
      printf '         that leaves the same one-commit shape the base expects.\n'
      ;;
    BASE_MODIFIED)
      printf 'THE BASE MOVED UNDER THE MERGE CALL. GitHub took a mergeability snapshot, another PR landed on\n'
      printf 'the base before our write, and the mutation refused. It is TRANSIENT — measured twice on\n'
      printf '2026-09-13 (api and studio lanes), where a by-hand retry merged first try both times. This\n'
      printf 'script already re-read mergeable_state and spent its ONE retry; seeing this message here means\n'
      printf 'the SECOND attempt refused too, so it is no longer behaving like a race.\n'
      printf 'RESOLVE: scripts/bp-merge.sh        # run it again — a fresh run gets a fresh pair of attempts\n'
      printf 'THEN:    if it keeps repeating, the base is landing faster than this head can merge; rebase and\n'
      printf '         re-run, or wait for the lane to quieten. It is NOT a finding about the checks.\n'
      ;;
    UNRECOGNISED)
      printf 'UNRECOGNISED REFUSAL. This shape is not in the measured table, so this script refuses to guess —\n'
      printf 'a parser that assumes green on an unknown string is exactly the vacuous pass this epic exists\n'
      printf 'for. Read the quoted message above, then extend the table in scripts/bp-merge.sh.\n'
      printf 'RESOLVE: gh pr merge %s --squash --delete-branch      # by hand, and read what gh says\n' "$pr"
      ;;
    *)
      printf 'internal: refusal_advice called with unknown state %s\n' "$state"
      ;;
  esac
}

# ── everything below needs a real GitHub; the harness never reaches it ───────
resolve_pr() {
  command -v gh >/dev/null 2>&1 || die "gh is not installed — this wrapper is optional; merge by hand."
  local json
  json="$(gh pr view --json number,url,headRefOid,state,isDraft 2>&1)" \
    || die "no pull request for the current branch: $json"
  PR_NUMBER="$(printf '%s' "$json" | jq -r '.number')"
  PR_URL="$(printf '%s' "$json" | jq -r '.url')"
  HEAD_SHA="$(printf '%s' "$json" | jq -r '.headRefOid')"
  [ "$(printf '%s' "$json" | jq -r '.state')" = "OPEN" ] \
    || die "PR #$PR_NUMBER is not OPEN — nothing to merge."
  [ "$(printf '%s' "$json" | jq -r '.isDraft')" = "false" ] \
    || die "PR #$PR_NUMBER is a DRAFT — mark it ready first: gh pr ready $PR_NUMBER"
  echo "bp-merge: PR #$PR_NUMBER  head $HEAD_SHA"
  echo "          $PR_URL"
}

# Pre-flight. Never reimplemented here — this shells out to the one detector
# that already exists, whose exit codes are its contract (D14).
#   0 = every required context rendered · 3 = DEADLOCK · 4 = RE-RUN (cancelled)
#   5 = BLOCKED (an input could not be read / a producer refused)
#
# 5 IS NAMED HERE RATHER THAN LEFT TO THE `*)` CATCH-ALL, AND IT CHANGES NO
# BEHAVIOUR ON PURPOSE. The catch-all already refuses, which is the only correct
# answer: an unreadable pre-flight is a refusal, never a skip, and this is the
# merge verb — every lane merges through it. What the named arm buys is the
# OPERATOR'S next move. `exit $rc` in a catch-all sends a human to read code to
# learn whether the detector found something or could not look; the detector now
# says which, so this says which too. Note the collision the verifier's header
# documents: 4 here is RE-RUN, and 4 in scripts/required-checks.test.sh is that
# suite's HOLD. They are different claims and they stay on different arms.
preflight() {
  echo "bp-merge: pre-flight — required-checks-verify.sh --deadlock"
  local rc=0
  bash "$VERIFY" --deadlock --sha "$HEAD_SHA" || rc=$?
  case "$rc" in
    0) echo "bp-merge: pre-flight ok — every required context is present on this head." ;;
    3) echo "bp-merge: REFUSED before waiting — the head can never satisfy the required set (named above)." >&2
       exit 3 ;;
    4) echo "bp-merge: REFUSED before waiting — a required context concluded CANCELLED (named above)." >&2
       echo "          Nothing will re-report it on its own. Re-run it, then run this again." >&2
       exit 3 ;;
    5) echo "bp-merge: REFUSED — the pre-flight is BLOCKED: it could not READ an input (named above)." >&2
       echo "          This is NOT a finding about your PR. Nothing was measured about the required set," >&2
       echo "          so the refusal carries no claim that this head is missing or red." >&2
       echo "          An unreadable pre-flight is a refusal, never a skip." >&2
       exit 1 ;;
    *) echo "bp-merge: REFUSED — the deadlock detector exited $rc, which is not a code it documents." >&2
       echo "          An unrecognised pre-flight is a refusal, never a skip." >&2
       exit 1 ;;
  esac
}

# ── pre-flight 2: mergeable_state, read BEFORE the merge call is spent ───────
# ONE REST read — literally the same one scripts/pr-required-style callers make.
# It exists because the required-context verdict and the MERGEABILITY verdict
# are different questions with different clocks: measured 2026-09-11 on #17612,
# the four required contexts were green at 03:56Z, a sibling PR touching the
# same file merged, and by 04:05Z this head conflicted with the base. Pre-flight
# 1 (the deadlock detector) is blind to that by construction — it reads check
# runs, not the diff.
#
# `unknown` IS NOT CLEAN. GitHub computes mergeability asynchronously and serves
# `unknown` until it finishes; a reader that folds unknown into "not dirty" is
# the vacuous pass, just quieter. So unknown re-reads a bounded number of times
# and then REFUSES, which is self-healing (re-running the script re-reads).
#
# The states seen on this repo (REST .mergeable_state):
#   clean, has_hooks   no conflict, and the checks are satisfied
#   unstable           a NON-required check is red; the merge is still allowed
#   blocked            a required context is missing or red — pre-flight 1 names it
#   behind             the base moved; strict:false here, so not a blocker
#   dirty              THE CONFLICT this arm exists for
#   unknown            not computed yet — NEVER a green
#
# ONLY `dirty` refuses here. Everything else falls through to the merge call,
# whose own refusal string stays the authority (D54) — this pre-flight adds a
# name, it does not take over the classification.
MERGEABLE_POLLS="${BP_MERGE_MERGEABLE_POLLS:-4}"
MERGEABLE_POLL_SECONDS="${BP_MERGE_MERGEABLE_POLL_SECONDS:-3}"

# IMPURE (it calls gh) and kept as its own one-line function so the harness can
# stub `gh` around it and drive the real reader rather than a re-implementation.
read_mergeable_state() {
  gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER" --jq '.mergeable_state' 2>&1
}

preflight_mergeable() {
  echo "bp-merge: pre-flight — mergeable_state (one REST read, before the merge call)"
  local state="" rc=0 i=1
  while [ "$i" -le "$MERGEABLE_POLLS" ]; do
    rc=0
    state="$(read_mergeable_state)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      {
        echo "bp-merge: REFUSED — could not READ mergeable_state. The API answered:"
        printf '%s\n' "$state" | sed 's/^/            /'
        echo "          An unreadable pre-flight is a refusal, never a skip. NOTHING was measured"
        echo "          about this head, so this refusal carries no claim that it conflicts."
        echo "          RESOLVE: scripts/bp-merge.sh        # run it again once the API answers"
      } >&2
      exit 1
    fi
    if [ "$state" != "unknown" ] && [ -n "$state" ]; then
      break
    fi
    echo "bp-merge: mergeable_state is 'unknown' — GitHub has not computed it yet (read $i/$MERGEABLE_POLLS)"
    i=$(( i + 1 ))
    if [ "$i" -le "$MERGEABLE_POLLS" ]; then
      sleep "$MERGEABLE_POLL_SECONDS"
    fi
  done
  case "$state" in
    dirty)
      {
        echo
        echo "bp-merge: REFUSED — DIRTY (mergeable_state: dirty), read BEFORE the merge call."
        echo "  The merge call was NOT spent: GitHub already says this head cannot be merged into"
        echo "  the base without a conflict. The required contexts are a SEPARATE question and may"
        echo "  well be green — that is exactly the shape this arm exists for."
        echo
        refusal_advice DIRTY "$PR_NUMBER" "$HEAD_SHA" | sed 's/^/  /'
        echo
        echo "  PR: $PR_URL"
      } >&2
      exit 4 ;;
    unknown|"")
      {
        echo "bp-merge: REFUSED — mergeable_state is STILL 'unknown' after $MERGEABLE_POLLS reads."
        echo "          'unknown' means GitHub has not computed mergeability yet. It is NEVER a green,"
        echo "          and this script will not spend a merge call on a state nobody has looked at."
        echo "          RESOLVE: scripts/bp-merge.sh        # run it again in a few seconds"
      } >&2
      exit 1 ;;
    *)
      echo "bp-merge: pre-flight ok — mergeable_state: $state (not a conflict)." ;;
  esac
}

# ── pre-flight 0: THE MAIN-RED HOLD REGISTRY ────────────────────────────────
#
# WHY THIS LIVES HERE AND NOT IN THE REQUIRED CHECK SET (ruled 2026-09-13).
# `scripts/main-red-hold.sh` records a red that REPRODUCES on a clean checkout
# of main, with an owner and a per-tree scope, in .github/main-red-holds.json.
# Until this block existed the registry was ADVISORY everywhere: pr-meta.yml
# runs `check` and annotates, but that workflow is not in the required four
# (Cloud gate / Console gate / Elixir gate / PR references an active task) and
# CANNOT be, because a paths-filtered workflow emits no check run on a
# non-matching PR and a required context that never renders deadlocks the
# branch forever. Widening the required set is the wrong fix and was rejected
# twice.
#
# THE HELPER LAYER IS WHERE A HOLD CAN ACTUALLY REFUSE. This fleet does not
# merge with the GitHub button; every lane merges through THIS script — it is
# the only live `gh pr merge` call in the repository. So the hold is advisory
# at the GitHub layer and ENFORCED here. That needs no required context and it
# cannot deadlock a branch: lifting the hold, or overriding it on the record,
# releases the merge immediately.
#
# IT FAILS CLOSED, AND THAT IS THE PROPERTY THAT MATTERS MOST. A merge path
# that fails OPEN on an unreadable registry is strictly worse than no hold at
# all: it teaches everyone the hold is real while quietly merging through it
# whenever the file is missing, empty, unparseable, or the file list could not
# be read. Every one of those is `HOLD CHECK CANNOT READ` and exit 6. An
# unreadable hold registry is a refusal, never a skip — the same rule this
# script already applies to its own pre-flight.
#
# IT DOES NOT REFUSE A PR THAT TOUCHES NOTHING HELD. A hold that blocks
# everything gets lifted under pressure, which is exactly why fleet-wide holds
# were rejected on 2026-09-13 after one was issued and retracted the same
# morning. The judgement is per-file against the hold's own trees, and the
# CLEAR path prints which holds it considered and did not hit.
HOLD_SCRIPT="$REPO_ROOT/scripts/main-red-hold.sh"

# Selects WHICH registry to judge; it cannot select NO registry. An empty value
# falls back to the committed default rather than skipping — an env var that
# can turn the check off is the fail-open door this block exists to close, and
# an unreadable path here is exit 6, not a pass.
HOLD_REGISTRY="${BP_MERGE_HOLD_REGISTRY:-.github/main-red-holds.json}"

# IMPURE (it calls gh) and kept as its own one-line function for the same
# reason read_mergeable_state is: the harness stubs `gh` around it and drives
# the REAL reader rather than a re-implementation of it.
read_pr_files() {
  gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>&1
}

# The distinct CANNOT READ line. It is never byte-identical to the CLEAR line
# and never to the HELD line, so no caller can confuse "nothing is held" with
# "I could not look".
hold_cannot_read() { # $1 = what could not be read
  echo "bp-merge: HOLD CHECK CANNOT READ — $1" >&2
  echo "          NOTHING is known about whether this PR touches a tree that is RED ON MAIN." >&2
  echo "          This refusal carries no claim that your PR is held, and none that it is clear." >&2
  echo "          An unreadable hold registry is a REFUSAL, never a skip: a merge path that fails" >&2
  echo "          OPEN on a hold is strictly worse than no hold at all. Fix the read and re-run." >&2
  echo "          Registry judged: $HOLD_REGISTRY   (scripts/main-red-hold.sh check)" >&2
  exit 6
}

# The override, and why it exists at all.
#
# A HOLD WITHOUT A DOOR DEADLOCKS ITS OWN FIX. The hold's scope is the tree the
# red reproduces in, and `lift` clears it only by re-running the reproduction on
# a LATER main sha — i.e. only AFTER the fix has landed. The PR that carries the
# fix touches the held tree by construction, so with no door the fix can never
# merge and the hold can never lift. That is not a hypothetical: the single hold
# open on 2026-09-14 (internal-taskboard-golden-drift, owner lane:cli, tree
# internal/taskboard) has exactly this shape.
#
# SO THE DOOR IS EXPLICIT, NAMED, AND RECORDED — THREE VARIABLES, ALL REQUIRED:
#   BP_MERGE_HOLD_OVERRIDE_ID    the hold slug being overridden (must be one
#                                that actually held THIS PR — an override that
#                                names a hold this PR is not held by releases
#                                nothing and refuses)
#   BP_MERGE_HOLD_OVERRIDE_WHO   who authorised it
#   BP_MERGE_HOLD_OVERRIDE_WHY   why
# A partial set is a refusal that names the missing ones. There is no single
# `--force`: a one-flag door is the one that gets used reflexively.
#
# THE RECORD IS A PRECONDITION, NOT A SIDE EFFECT. The override posts a comment
# on the PR naming the hold, the owner, who authorised it, why, and the held
# files that decided it — and if that write FAILS the merge is refused. A record
# that only ever reached this script's stdout is not a record; the terminal
# scrolls, the PR does not. It cannot be un-posted, and the hold stays open in
# the committed registry either way, so the next PR into the same tree meets the
# same refusal rather than inheriting this one's exception.
#
# AN UNREADABLE REGISTRY CANNOT BE OVERRIDDEN, BY CONSTRUCTION. The override is
# reachable only from the HELD arm, and it must name a hold id that appeared in
# the check's own output — which an unreadable registry never produces. Exit 6
# has no door.
hold_override_or_refuse() { # $1 = the check's own HELD output
  local held_out="$1"
  local oid="${BP_MERGE_HOLD_OVERRIDE_ID:-}"
  local owho="${BP_MERGE_HOLD_OVERRIDE_WHO:-}"
  local owhy="${BP_MERGE_HOLD_OVERRIDE_WHY:-}"

  if [ -z "$oid" ] && [ -z "$owho" ] && [ -z "$owhy" ]; then
    echo "bp-merge: REFUSED — MAIN-RED HOLD" >&2
    echo "          This PR changes a file under a tree that is RED ON MAIN, reproduced on a clean" >&2
    echo "          checkout. The verdict above names the hold, the held trees, the OWNER, the task" >&2
    echo "          and the files of yours that fall inside it." >&2
    echo "          LIFT IT (the ordinary path, and it lifts on a MEASUREMENT, never on a claim):" >&2
    echo "            bash scripts/main-red-hold.sh lift --id <id>" >&2
    echo "          OVERRIDE IT ON THE RECORD (for the PR that CARRIES the fix, which touches the" >&2
    echo "          held tree by construction and could otherwise never merge):" >&2
    echo "            BP_MERGE_HOLD_OVERRIDE_ID=<id> BP_MERGE_HOLD_OVERRIDE_WHO=<who> \\" >&2
    echo "            BP_MERGE_HOLD_OVERRIDE_WHY='<why>' scripts/bp-merge.sh" >&2
    echo "          The override posts the authorisation as a PR comment BEFORE merging; if that" >&2
    echo "          comment cannot be posted, the merge is refused." >&2
    exit 5
  fi

  local missing=""
  [ -n "$oid" ]  || missing="$missing BP_MERGE_HOLD_OVERRIDE_ID"
  [ -n "$owho" ] || missing="$missing BP_MERGE_HOLD_OVERRIDE_WHO"
  [ -n "$owhy" ] || missing="$missing BP_MERGE_HOLD_OVERRIDE_WHY"
  if [ -n "$missing" ]; then
    echo "bp-merge: REFUSED — MAIN-RED HOLD OVERRIDE INCOMPLETE" >&2
    echo "          An override names WHO authorised it and WHY, against a specific hold. Missing:$missing" >&2
    echo "          A partial override is not an authorisation, so the hold above still stands." >&2
    exit 5
  fi

  case "$held_out" in
    *"HELD: $oid"*) : ;;
    *) echo "bp-merge: REFUSED — MAIN-RED HOLD OVERRIDE NAMES THE WRONG HOLD" >&2
       echo "          BP_MERGE_HOLD_OVERRIDE_ID='$oid' does not match any hold that held this PR." >&2
       echo "          The verdict above names the hold(s) that did. An override releases the hold it" >&2
       echo "          NAMES and nothing else — a mis-typed id must never read as a blanket bypass." >&2
       exit 5 ;;
  esac

  local body crc=0 cout
  body="$(printf '%s\n\n%s\n\n%s\n\n%s\n\n```\n%s\n```\n' \
    "**MAIN-RED HOLD OVERRIDDEN — \`$oid\`**" \
    "AUTHORISED BY: $owho" \
    "REASON: $owhy" \
    "Merged by \`scripts/bp-merge.sh\` through the hold above. The hold is NOT lifted by this override and stays open in \`$HOLD_REGISTRY\`; it lifts only when \`scripts/main-red-hold.sh lift --id $oid\` re-runs its own reproduction on a later main sha and that command exits 0. The registry verdict this override answers:" \
    "$held_out")"

  echo "bp-merge: MAIN-RED HOLD OVERRIDE — recording the authorisation on PR #$PR_NUMBER before merging"
  cout="$(gh pr comment "$PR_NUMBER" --body "$body" 2>&1)" || crc=$?
  if [ "$crc" != "0" ]; then
    echo "bp-merge: REFUSED — MAIN-RED HOLD OVERRIDE COULD NOT BE RECORDED" >&2
    echo "          gh pr comment failed, so the authorisation exists nowhere but this terminal." >&2
    echo "          The record is a PRECONDITION of the override, not a side effect of it, so the" >&2
    echo "          hold STANDS. gh said:" >&2
    printf '%s\n' "$cout" | sed 's/^/          | /' >&2
    exit 5
  fi
  echo "bp-merge: hold '$oid' OVERRIDDEN by $owho — authorisation recorded on the PR; proceeding."
}

# ── THE PR-LABEL HOLD ────────────────────────────────────────────────────────
# MEASURED, 2026-09-17. PR #18497 carried the `hold` label continuously from
# 2026-09-16T08:51:19Z (labelled by the owner; the issue timeline shows NO
# unlabelled event) and merged at 06:41Z the next morning through this very
# script. It was owner-held: a migration on a 31k-row prod table that the owner
# said must be ORDERED. Nothing mechanical refused, because NOTHING IN THIS FILE
# EVER READ THE PR'S LABELS. The hold above is the MAIN-RED registry — a
# different claim entirely, and it correctly said CLEAR, because the PR touched
# no tree that is red on main.
#
# So the label was a convention enforced by whoever remembered it. The sweep
# skipped held PRs; a human running the merge verb directly did not. A hold that
# only some paths honour teaches everyone the hold is real while one path merges
# straight through it — the exact failure the comments at lines 116-118 and
# 488-489 already named for the registry.
#
# THIS ARM IS INDEPENDENT ON PURPOSE. Its own read, its own classifier, its own
# exit codes (7 / 8), its own CANNOT-READ. It does not consult the registry and
# the registry does not consult it; either can refuse alone. Folding it into
# preflight_hold would have made one unreadable input silence both claims.
BP_MERGE_LABEL_HOLD="${BP_MERGE_LABEL_HOLD:-hold}"

# IMPURE (it calls gh), one line, for the same reason read_pr_files is: the
# harness stubs `gh` around it and drives the REAL reader.
read_pr_labels() {
  gh pr view "$PR_NUMBER" --json labels --jq '[.labels[].name]|@json' 2>&1
}

# PURE. One raw string in, one state token out, so the harness drives THIS and
# not a lookalike.
#
# IT IS HANDED THE RAW JSON ARRAY, NEVER A join(","). merge-check.sh's arm read
# `[.labels[].name]|join(",")` and could not tell a PR with NO labels from a
# read that returned nothing — both render the empty string — so it published
# "not held" off an empty read. `[]` is a readable, genuinely unlabelled PR; a
# string that is not a JSON array of names is a read that did not happen.
#
# And the membership test is EXACT, not the `*hold*` glob merge-check used:
# `holdover`, `withhold` and `stakeholder` all match `*hold*`.
# Prints "<STATE>\t<detail>"; rc 0 CLEAR, 1 HELD, 2 UNREAD.
label_hold_classify() { # $1 = raw
  local raw="${1-}" names
  if [ -z "$raw" ]; then
    printf 'UNREAD\tthe label read produced NO OUTPUT — an empty read is not an empty label set\n'; return 2
  fi
  printf '%s' "$raw" | jq -e 'type=="array" and (map(type=="string")|all)' >/dev/null 2>&1 || {
    printf 'UNREAD\tthe label read did not parse as a JSON array of names. gh said: %s\n' "$raw"; return 2; }
  if printf '%s' "$raw" | jq -e --arg h "$BP_MERGE_LABEL_HOLD" \
       'any(.[]; ascii_downcase == ($h|ascii_downcase))' >/dev/null 2>&1; then
    names=$(printf '%s' "$raw" | jq -r 'join(", ")')
    printf 'HELD\tlabels: [%s]\n' "$names"; return 1
  fi
  names=$(printf '%s' "$raw" | jq -r 'if length==0 then "(none)" else join(", ") end')
  printf 'CLEAR\tlabels: [%s]\n' "$names"; return 0
}

# The distinct CANNOT READ line. Never byte-identical to the CLEAR or HELD line,
# so no caller can confuse "no hold label" with "I could not look".
label_hold_cannot_read() { # $1 = what could not be read
  echo "bp-merge: PR-LABEL HOLD CANNOT READ — $1" >&2
  echo "          NOTHING is known about whether PR #$PR_NUMBER carries the '$BP_MERGE_LABEL_HOLD' label." >&2
  echo "          This refusal carries no claim that your PR is held, and none that it is clear." >&2
  echo "          An unread label is NOT an absent hold: a merge path that fails OPEN on a hold is" >&2
  echo "          strictly worse than no hold at all. Fix the read and re-run." >&2
  echo "          Read attempted: gh pr view $PR_NUMBER --json labels" >&2
  exit 8
}

preflight_label_hold() {
  echo "bp-merge: pre-flight — PR-label hold ('$BP_MERGE_LABEL_HOLD' on PR #$PR_NUMBER)"
  local raw rc=0 out
  raw="$(read_pr_labels)" || rc=$?
  [ "$rc" = "0" ] \
    || label_hold_cannot_read "gh could not read the labels on PR #$PR_NUMBER (exit $rc): $raw"

  rc=0
  out="$(label_hold_classify "$raw")" || rc=$?
  case "$rc" in
    0) echo "bp-merge: label pre-flight ok — CLEAR: ${out#*	}" ;;
    1) {
         echo "bp-merge: REFUSED — PR-LABEL HOLD: #$PR_NUMBER carries the '$BP_MERGE_LABEL_HOLD' label."
         echo "          ${out#*	}"
         echo "          A hold label is a HUMAN'S DELIBERATE STOP on this PR, and it is not a note:"
         echo "          it is the only thing standing between an owner-held change and main. The PR"
         echo "          may be 4/4 green; this refusal says nothing about its checks."
         echo "          There is no override flag. The door is one visible, deliberate command:"
         echo "            gh pr edit $PR_NUMBER --remove-label $BP_MERGE_LABEL_HOLD"
         echo "          Ask whoever applied it FIRST — read the PR's timeline for who and why."
       } >&2
       exit 7 ;;
    *) label_hold_cannot_read "${out#*	}" ;;
  esac
}

preflight_hold() {
  echo "bp-merge: pre-flight — main-red hold registry ($HOLD_REGISTRY)"
  [ -f "$HOLD_SCRIPT" ] \
    || hold_cannot_read "missing $HOLD_SCRIPT — the registry cannot be judged without it"

  local files rc=0
  files="$(read_pr_files)" || rc=$?
  [ "$rc" = "0" ] \
    || hold_cannot_read "gh could not list the changed files on PR #$PR_NUMBER (exit $rc): $files"
  [ -n "$files" ] \
    || hold_cannot_read "PR #$PR_NUMBER lists ZERO changed files; an empty file list is a failed read, not a clean PR, and CLEAR off zero paths asserts nothing"

  local out
  rc=0
  out="$(printf '%s\n' "$files" | bash "$HOLD_SCRIPT" check --registry "$HOLD_REGISTRY" --paths-from - 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/          /'

  case "$rc" in
    0) echo "bp-merge: hold pre-flight ok — CLEAR: this PR touches no held tree." ;;
    1) hold_override_or_refuse "$out" ;;
    2) hold_cannot_read "scripts/main-red-hold.sh check rejected its own arguments (exit 2); the judgement never ran" ;;
    3) hold_cannot_read "scripts/main-red-hold.sh check could not read its input (exit 3); its own CANNOT READ line is quoted above" ;;
    *) hold_cannot_read "scripts/main-red-hold.sh check exited $rc, which is not a code it documents" ;;
  esac
}

# ── the ONE retry: 'Base branch was modified' ────────────────────────────────
# THE BOUND IS A LITERAL AND IS NOT READ FROM THE ENVIRONMENT. Every other knob
# in this file is overridable because widening it costs only time; this one
# governs how many times a WRITE is repeated against GitHub, and an env-tunable
# retry count is an unbounded retry loop one variable away. One retry is what
# the measurement supports (2026-09-13, api and studio lanes: the first by-hand
# retry merged in both cases) and one retry is what this script will spend.
BASE_MODIFIED_RETRY_BUDGET=1

# The pause before the retry. The base just moved; hitting the same mutation in
# the same millisecond re-races the write that already lost. Overridable ONLY so
# the harness can drive the arm without spending wall time — it does not change
# how many attempts happen.
BASE_MODIFIED_RETRY_SLEEP="${BP_MERGE_BASE_MODIFIED_RETRY_SLEEP:-5}"

# RE-READ BEFORE THE RETRY, NEVER OFF THE STALE READ. The pre-flight's
# mergeable_state was read BEFORE the merge call, and the refusal we are
# answering says, in GitHub's own words, that the base changed since then. So
# the one thing the pre-flight measured is the one thing now known to be out of
# date: the same sibling that moved the base may have made this head CONFLICT.
# A retry off the pre-flight read would be a retry off a read the error itself
# invalidated. Returns 0 only on a FRESH read that still reports the head
# mergeable; every other outcome (unreadable, dirty, unknown, empty) returns 1
# and the caller takes the ordinary refusal path.
recheck_mergeable_for_retry() {
  local state="" rc=0
  state="$(read_mergeable_state)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    {
      echo "bp-merge: could not RE-READ mergeable_state before the retry — NOT retrying blind."
      echo "          The API answered:"
      printf '%s\n' "$state" | sed 's/^/            /'
    } >&2
    return 1
  fi
  case "$state" in
    dirty)
      echo "bp-merge: the re-read says DIRTY — the base that moved took this head CONFLICTING with it." >&2
      echo "          NOT retrying: a retry cannot merge a conflict, and a rebase is the only remedy." >&2
      return 1 ;;
    unknown|"")
      echo "bp-merge: the re-read says '$state' — GitHub has not recomputed mergeability since the base moved." >&2
      echo "          NOT retrying: 'unknown' is never a green here either." >&2
      return 1 ;;
    *)
      echo "bp-merge: re-read after the moved base — mergeable_state: $state. Spending the ONE retry."
      return 0 ;;
  esac
}

# A plural refusal names nothing, so ask the detector which context is missing.
resolve_plural() {
  echo "bp-merge: plural refusal — falling through to the set-difference detector to get a NAME." >&2
  local rc=0
  bash "$VERIFY" --deadlock --sha "$HEAD_SHA" >&2 || rc=$?
  case "$rc" in
    3) echo "bp-merge: DEADLOCK (named above) — this head can never go green." >&2; exit 3 ;;
    4) echo "bp-merge: RE-RUN (a required context is CANCELLED, named above)." >&2; exit 3 ;;
    0) return 0 ;;
    5) echo "bp-merge: BLOCKED — the detector could not READ an input (named above), so it never" >&2
       echo "          got to the set difference and this plural refusal is still unexplained. Refusing." >&2
       exit 1 ;;
    *) echo "bp-merge: the detector exited $rc, a code it does not document — refusing." >&2; exit 1 ;;
  esac
}

# THE COUNTER-LINE (honest-gates D78). gh's own refusal is quoted VERBATIM
# above — that is the whole point of this wrapper, and it must never be edited
# or filtered. But `viewerCanAdminister` is true for every agent in this fleet,
# so gh appends its own suggestion to override the branch policy and merge now.
# Under `enforce_admins: true` that suggestion is dead: the server refuses the
# override too. Without a line saying so, bp-merge's refusal — the very artifact
# this epic produces as evidence — would itself teach the verb the epic
# abolished, in gh's voice, right where an agent is looking for what to do next.
#
# The counter-line deliberately does NOT spell the flag. `scripts/bp-merge.test.sh`
# ratchets that no executable line of this file emits it, and a wrapper that has
# to print a string to argue against printing it has lost the argument.
counter_line() {
  local msg="$1"
  # The SECOND suggestion gh appends, measured 2026-09-11 on the DIRTY refusal:
  # it offers to queue the merge for after the requirements are met. Matched on
  # gh's own SENTENCE rather than on the flag it names, because the flag is one
  # of the two strings bp-merge.test.sh ratchets out of every executable line
  # here — a wrapper that has to print a string to argue against printing it has
  # lost the argument (the same reason the admin arm below does not spell its).
  case "$msg" in
    *"To have the pull request merged after all the requirements have been met"*)
      printf 'NOTE: gh offered to QUEUE this merge for later above. It is DEAD — this repo keeps\n'
      printf '      allow_auto_merge FALSE (D53), so nothing lands unattended, and queueing a\n'
      printf '      conflicting head would not resolve the conflict in any case.\n'
      ;;
  esac
  case "$msg" in
    *admin*|*override*)
      printf 'NOTE: gh suggested an admin override above. It is DEAD — under enforce_admins:true the server\n'
      printf '      refuses it exactly like the merge itself, and it is no longer this repo'"'"'s merge protocol.\n'
      printf '      The merge verb is this script. Fix the required context named below, then run it again.\n'
      ;;
  esac
}

# Resolve the numeric run id behind a required context that concluded
# failure/cancelled on the head — the id the RED/RERUN advice interpolates.
# IMPURE ON PURPOSE (it calls gh) and BEST-EFFORT: any miss prints nothing and
# the advice degrades to the placeholder path. Lives in the CALLER so that
# refusal_advice() keeps the no-network purity the test harness relies on.
resolve_failed_run_id() { # $1 = head sha  -> prints a numeric run id, or nothing
  local sha="$1" spec="$REPO_ROOT/.github/required-checks.json" runs required
  [ -n "$sha" ] || return 0
  runs="$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[] | select(.conclusion=="failure" or .conclusion=="cancelled") | [.name, .details_url] | @tsv' \
    2>/dev/null)" || return 0
  [ -n "$runs" ] || return 0
  # Prefer a run behind a REQUIRED context (the committed spec); fall back to
  # any failed/cancelled check when the spec cannot be read or none matches.
  if [ -f "$spec" ]; then
    # The COMMITTED spec nests protection under .protection (the live API
    # read-back does not) — read both shapes so neither source of the file
    # silently empties the required set.
    required="$(jq -r '[(.protection.required_status_checks.checks[]?.context), (.required_status_checks.checks[]?.context), (.required_status_checks.contexts[]?)] | .[]' "$spec" 2>/dev/null)"
    if [ -n "$required" ]; then
      while IFS="$(printf '\t')" read -r name url; do
        if printf '%s\n' "$required" | grep -qxF "$name"; then
          printf '%s\n' "$url" | sed -n 's#.*/runs/\([0-9][0-9]*\)/.*#\1#p' | head -1
          return 0
        fi
      done <<EOF
$runs
EOF
    fi
  fi
  printf '%s\n' "$runs" | head -1 | cut -f2 | sed -n 's#.*/runs/\([0-9][0-9]*\)/.*#\1#p'
  return 0
}

refuse() {
  local state="$1" msg="$2" run_id=""
  case "$state" in
    RED|RERUN) run_id="$(resolve_failed_run_id "$HEAD_SHA" || true)" ;;
  esac
  {
    echo
    echo "bp-merge: REFUSED — $state"
    echo "  gh said, verbatim:"
    printf '%s\n' "$msg" | sed 's/^/    /'
    counter_line "$msg" | sed 's/^/    /'
    if [ "$PR_STATE_READ" = "UNKNOWN" ]; then
      echo
      echo "  NOTE: the landed-check could NOT read the PR state — the API did not answer:"
      printf '%s\n' "$PR_STATE_ERROR" | sed 's/^/        /'
      echo "        So this refusal is classified from gh's MESSAGE ALONE, and an unreadable"
      echo "        instrument is not evidence that the merge did not land. Confirm first:"
      echo "        gh pr view $PR_NUMBER --json state,mergedAt"
    fi
    echo
    refusal_advice "$state" "$PR_NUMBER" "$HEAD_SHA" "$run_id" | sed 's/^/  /'
    echo
    echo "  PR: $PR_URL"
  } >&2
  # DIRTY gets its OWN code (4): every other refusal here means "not yet", and a
  # caller may sensibly re-run or wait. A conflict never clears by waiting, so a
  # caller that retries on 1 must NOT retry on this.
  [ "$state" != "DIRTY" ] || exit 4
  exit 1
}

# VERIFY THE STATE, NEVER THE EXIT CODE. Measured on this script's own first
# live merge (PR #6924, mergedAt 2026-07-28T22:54:25Z, merge commit 98f95be6):
# `gh pr merge --squash --delete-branch` merged SERVER-SIDE and then exited 1 on
# its LOCAL post-merge step —
#
#   failed to run git: fatal: 'main' is already checked out at '/…/barkpark'
#
# — because `--delete-branch` tries to switch the local checkout to the base
# branch, and in this fleet `main` is permanently checked out by the primary
# worktree while every agent works in another one. So the exit code said REFUSED
# about a merge that had already landed, and the classifier honestly reported
# UNRECOGNISED (the right failure direction, and exactly the arm that exists for
# strings nobody measured). It is still a FALSE STALL: on a worktree fleet it
# would fire on every successful merge. The fix is to ask the server what
# happened rather than to add another string to the table — a message-shaped
# guess about whether a merge landed is the vacuous pass in the other direction.
# AN UNREADABLE STATE IS NOT "NOT MERGED". Measured 2026-09-02 on this fleet:
# `gh pr view` fails outright under a rate limit ("API rate limit already
# exceeded for user ID …"), so this returns UNKNOWN — and the caller's `!=
# MERGED` test cannot tell UNKNOWN from a confirmed-OPEN PR. That is the false
# stall coming back through the INSTRUMENT instead of through the table. The
# answer and the error are recorded so refuse() can say which one it got; the
# script still refuses either way, because a blind read is never a green.
#
# IT SETS GLOBALS AND IS NEVER CALLED INSIDE $( ). A command substitution runs a
# SUBSHELL, so a global assigned in there dies with it — the error text would be
# discarded in exactly the case it exists for, and the refusal would go back to
# sounding as confident as a read one.
PR_STATE_READ=""
PR_STATE_ERROR=""

pr_state() {
  local out rc=0
  out="$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    PR_STATE_READ="$out"
    PR_STATE_ERROR=""
  else
    PR_STATE_READ="UNKNOWN"
    PR_STATE_ERROR="$out"
  fi
}

merged_despite_error() {
  local out="$1"
  # Called PLAINLY, never as $(pr_state): this if-condition is not a subshell,
  # so the globals survive and the refusal path can distinguish a PR the API
  # said is OPEN from one the API never answered about at all.
  pr_state
  [ "$PR_STATE_READ" = "MERGED" ] || return 1
  {
    echo
    echo "bp-merge: MERGED #$PR_NUMBER (squash) — the server-side merge LANDED."
    echo "  gh then exited non-zero on its LOCAL post-merge step, and said, verbatim:"
    printf '%s\n' "$out" | sed 's/^/    /'
    echo "  This is not a refusal: 'gh pr view --json state' reads MERGED. The exit code was"
    echo "  about gh's attempt to update this checkout, not about the merge."
  } >&2
  # gh's --delete-branch never reached the remote either, so finish the job
  # through the API, where no local checkout is involved.
  #
  # THE DELETE IS FENCED, because this is a WRITE on an error path and the
  # obvious form of it deletes the wrong branch. `headRefName` is a bare branch
  # name with no repository in it. On a CROSS-REPOSITORY (fork) PR that name
  # belongs to the FORK, while the DELETE below is addressed to the BASE repo —
  # so a fork PR from a branch called `staging` would delete THIS repo's
  # `staging`, which the merge had nothing to do with. Likewise a head that
  # equals the base branch is never ours to remove. Both are refusals, not
  # warnings: an unrecoverable write must not proceed on a guess.
  local head base cross
  head="$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  base="$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
  cross="$(gh pr view "$PR_NUMBER" --json isCrossRepository --jq '.isCrossRepository' 2>/dev/null || printf 'true\n')"
  if [ "$cross" != "false" ]; then
    echo "bp-merge: head branch '$head' lives in a FORK (or the repository could not be" >&2
    echo "          determined) — NOT deleting it: that name resolves to a different branch" >&2
    echo "          in this repo. Delete it in the fork if you want it gone." >&2
  elif [ "$head" = "$base" ]; then
    echo "bp-merge: head and base are both '$head' — refusing to delete the base branch." >&2
  elif [ -n "$head" ] && [ "$head" != "null" ]; then
    if gh api -X DELETE "repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/git/refs/heads/$head" >/dev/null 2>&1; then
      echo "bp-merge: deleted the remote head branch '$head'." >&2
    else
      echo "bp-merge: could NOT delete the remote head branch '$head' — remove it by hand." >&2
    fi
  fi
  return 0
}

merge_loop() {
  local deadline=$(( $(date +%s) + BUDGET_SECONDS ))
  local out rc state waited=0
  # Counts RETRIES SPENT, not attempts. attempts == retries + 1, and the two
  # are printed together in the refusal so the bound is readable from the run.
  local base_modified_retries=0
  while :; do
    rc=0
    out="$(gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "bp-merge: MERGED #$PR_NUMBER (squash, branch deleted)."
      return 0
    fi
    # Before classifying a single string: did it merge anyway?
    if merged_despite_error "$out"; then
      return 0
    fi
    state="$(classify_refusal "$out")"
    case "$state" in
      WAIT) : ;;
      # THE ONLY RETRY IN THIS SCRIPT, AND IT IS BOUNDED AT ONE. Three gates
      # stand between this message and a second merge call, and any of them
      # failing takes the ordinary refusal path:
      #   1. the retry budget is not already spent (a second BASE_MODIFIED
      #      refuses — it is no longer behaving like a race);
      #   2. a FRESH mergeable_state read still reports the head mergeable
      #      (never retry off the read the error invalidated);
      #   3. the overall budget has not run out.
      # It can therefore never become an unbounded loop, and it cannot swallow
      # a genuine conflict: gate 2 reads `dirty` and refuses, and a real
      # conflict answers with the DIRTY string, which is a different arm.
      BASE_MODIFIED)
        if [ "$base_modified_retries" -ge "$BASE_MODIFIED_RETRY_BUDGET" ]; then
          {
            echo
            echo "bp-merge: 'Base branch was modified' AGAIN after $(( base_modified_retries + 1 )) merge attempts"
            echo "          (budget: $BASE_MODIFIED_RETRY_BUDGET retry). Twice is not a race — refusing."
          } >&2
          refuse "$state" "$out"
        fi
        echo "bp-merge: the base moved under the merge call (attempt $(( base_modified_retries + 1 ))). Re-reading mergeable_state before retrying."
        recheck_mergeable_for_retry || refuse "$state" "$out"
        base_modified_retries=$(( base_modified_retries + 1 ))
        if [ "$(date +%s)" -ge "$deadline" ]; then
          {
            echo
            echo "bp-merge: OVER BUDGET after ${waited}s (budget ${BUDGET_SECONDS}s) with a retry still owed. NOT merged."
            printf '%s\n' "$out" | sed 's/^/    /'
            echo "  PR: $PR_URL"
            echo "  RESOLVE: scripts/bp-merge.sh        # a fresh run gets a fresh pair of attempts"
          } >&2
          exit 2
        fi
        [ "$BASE_MODIFIED_RETRY_SLEEP" -le 0 ] || sleep "$BASE_MODIFIED_RETRY_SLEEP"
        echo "bp-merge: retrying the merge ONCE (attempt $(( base_modified_retries + 1 )) of $(( BASE_MODIFIED_RETRY_BUDGET + 1 )))."
        continue
        ;;
      PLURAL)
        # No names in the message. Ask the detector; if it says the contexts are
        # all present, the plural refusal is pending-or-failing — and the string
        # itself is the only thing that can tell those apart.
        resolve_plural
        case "$out" in
          *failing*) refuse "$state" "$out" ;;
          *)         : ;;
        esac
        ;;
      *) refuse "$state" "$out" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      {
        echo
        echo "bp-merge: OVER BUDGET after ${waited}s (budget ${BUDGET_SECONDS}s). NOT merged, and deliberately NOT queued:"
        echo "  this repo keeps unattended merging switched off (D53), so nothing lands while you are away."
        echo "  gh last said:"
        printf '%s\n' "$out" | sed 's/^/    /'
        echo "  PR: $PR_URL"
        echo "  RESOLVE: scripts/bp-merge.sh        # run it again; or BP_MERGE_BUDGET_SECONDS=2400 scripts/bp-merge.sh"
      } >&2
      exit 2
    fi
    echo "bp-merge: waiting (${waited}s/${BUDGET_SECONDS}s) — $(printf '%s' "$out" | head -1)"
    sleep "$POLL_SECONDS"
    waited=$(( waited + POLL_SECONDS ))
  done
}

main() {
  case "${1:-}" in
    # Print the header block by SHAPE, not by a hard-coded line range: the
    # range version silently truncated --help the moment anyone added a line
    # to a comment above, which is the same class of quiet wrongness this
    # script exists to refuse.
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    "") : ;;
    *) die "this command takes NO arguments (got '$1'); the PR is derived from the current branch." ;;
  esac
  [ -x "$VERIFY" ] || [ -f "$VERIFY" ] || die "missing $VERIFY — the pre-flight cannot run."
  resolve_pr
  preflight_label_hold
  preflight_hold
  preflight
  preflight_mergeable
  merge_loop
}

# Sourced by scripts/bp-merge.test.sh to drive the classifier directly. The
# harness must never reach resolve_pr/merge_loop, and this is the seam that
# guarantees it.
if [ "${BP_MERGE_LIB:-0}" != "1" ]; then
  main "$@"
fi
