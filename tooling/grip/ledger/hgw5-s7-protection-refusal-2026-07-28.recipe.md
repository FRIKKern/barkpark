# The first merge refusal under branch protection — 2026-07-28

Dated record. Branch protection went live on `FRIKKern/barkpark/main` at
`2026-07-28T22:42:10Z` with `enforce_admins: true` and two required contexts
(`Elixir gate`, `PR references an active task`, both `app_id 15368`).

This PR is the throwaway that proves the refusal is real rather than asserted.
It was opened deliberately WITHOUT a task trailer, so the required context
`PR references an active task` renders RED, and then:

1. `gh pr merge --admin` is attempted and must be REFUSED.
2. The refusal is quoted here byte-for-byte.
3. The PR is made green and merged through `scripts/bp-merge.sh` — the merge
   verb's first live exercise.

## The refusal, verbatim

State at capture: `mergeable: MERGEABLE`, `mergeStateStatus: BLOCKED`,
`Elixir gate: pass`, `PR references an active task: fail`.

```
$ gh pr merge 6924 --repo FRIKKern/barkpark --squash --admin
GraphQL: Required status check "PR references an active task" is failing. (mergePullRequest)
$ echo $?
1
```

That is the whole message. Note what it does NOT contain: any suggestion that
the override worked. `--admin` sends no server-side bypass — the server
decides, and under `enforce_admins: true` it decides no. Captured twice, before
and after both required contexts settled, byte-identical both times.

## Which arm bp-merge classified

`CLIENT_BLOCK`. On the same head, `scripts/bp-merge.sh` (argument-free, run from
this branch's own worktree) refused with exit 1:

```
bp-merge: PR #6924  head f296843db40fa2cbe4b8816e46511ccae036fd8c
bp-merge: pre-flight — required-checks-verify.sh --deadlock
  ok     every required context appears in the 13 name(s) rendered on f296843d…
bp-merge: pre-flight ok — every required context is present on this head.

bp-merge: REFUSED — CLIENT_BLOCK
  gh said, verbatim:
    X Pull request FRIKKern/barkpark#6924 is not mergeable: the base branch policy prohibits the merge.
    To have the pull request merged after all the requirements have been met, add the `--auto` flag.
    To use administrator privileges to immediately merge the pull request, add the `--admin` flag.
    NOTE: gh suggested an admin override above. It is DEAD — under enforce_admins:true the server
          refuses it exactly like the merge itself, and it is no longer this repo's merge protocol.
          The merge verb is this script. Fix the required context named below, then run it again.

  gh blocked this CLIENT-SIDE from its own read of the base branch policy; the merge API was never called,
  so nothing here names the blocking context. This is the most common refusal under branch protection.
  RESOLVE: scripts/required-checks-verify.sh --deadlock --sha f296843db40fa2cbe4b8816e46511ccae036fd8c
  THEN:    gh pr checks 6924          # for a required context that rendered but is red or still running
```

Three measured facts fall out of that transcript, and all three were predictions
before it was run:

1. **CLIENT_BLOCK is the dominant post-flip arm.** gh reads
   `mergeStateStatus: BLOCKED` from its own GraphQL query and refuses locally —
   the merge API is never called, so the server never gets to name the context.
   The old advice for this arm was a `statusCheckRollup` JSON dump, which lists
   every check on the head, advisory ones included, and cannot say which of them
   the BRANCH requires. It now names the set-difference detector, as DEADLOCK
   and PLURAL already did.
2. **gh's own output teaches both abolished verbs.** `viewerCanAdminister` is
   true for every agent in this fleet, so gh appends `--auto` and `--admin`
   suggestions to the refusal. The verbatim quote is kept — that is the
   wrapper's whole promise — and countered immediately beneath it, or this very
   file would have shipped the folklore in gh's voice.
3. **The pre-flight passed and the merge still refused, correctly.** Every
   required context RENDERED on this head; one of them was red. Present is not
   the same as green, and the deadlock detector is deliberately silent about the
   difference — that is `gh pr checks`'s job, which is why the advice names both.

## What the merge itself measured — appended after the fact

This section did not exist when the PR was opened; it records what happened
when the PR was actually merged, because the merge found a defect in the merge
verb and a record that stopped at the prediction would be a lie.

Both required contexts went green after the `Task:` trailer was added
(`Elixir gate: pass`, `PR references an active task: pass`). `scripts/bp-merge.sh`
was then run, argument-free, from this branch's own worktree. It printed:

```
bp-merge: REFUSED — UNRECOGNISED
  gh said, verbatim:
    failed to run git: fatal: 'main' is already checked out at '/Volumes/SATECHI/github/barkpark'
```

**And the merge had already landed.** `mergedAt 2026-07-28T22:54:25Z`, merge
commit `98f95be6`. `gh pr merge --squash --delete-branch` merged server-side and
then exited 1 on its LOCAL post-merge step: `--delete-branch` tries to check the
base branch out in the current checkout, and in this fleet `main` is permanently
checked out by the primary worktree while every agent works in another one.

Two things are true at once and both matter:

* The classifier behaved correctly. An unmeasured string got `UNRECOGNISED` and
  a refusal, not a guess. That is the arm the harness exists for.
* It was still a FALSE STALL, and on a worktree fleet it would have fired on
  every successful merge — the artifact's first live exercise, breaking on its
  own house style.

The fix is NOT another row in the refusal table. Whether a merge landed is a
question for the API, and a message-shaped guess about it is the vacuous pass
pointing the other way. `merge_loop` now reads `gh pr view --json state` before
classifying any string; on `MERGED` it reports success, quotes gh's local error
underneath so nothing is hidden, and deletes the remote head branch through the
API where no local checkout is involved. Pinned by `scripts/bp-merge.test.sh`
assertions 28-31, including one that the state read happens BEFORE
`classify_refusal` — after it, `refuse()` exits first and the stall survives.
