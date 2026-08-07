# The claim-lapse mechanism, and how a lapsed-claim red is actually cleared

**Date:** 2026-08-08 · **Occasion:** cch wave 50 verify, PR #10509 (`cch-w49-s2`) stuck on
`PR references an active task` · **Status:** mechanism re-derived by running; every row below
carries the command that re-derives it.

## The mechanism, in one sentence

The gate's `open`-lifecycle branch asks **"was the claim still live when this PR was OPENED?"** —
`claim.expired_at >= pull_request.created_at` — and `created_at` is immutable across
`synchronize` / `edited` / `reopened`, so **pushing does not move the comparison**; only the
ledger side can move.

Read the two halves:

```
git show origin/main:scripts/pr-task-gate.sh   | sed -n '350,412p'   # the open branch, P4
git show origin/main:.github/workflows/pr-task-gate.yml | sed -n '265,285p'  # PR_OPENED_AT
```

The deciding line is `scripts/pr-task-gate.sh:407`:

```
[ "$open_lead" -ge 0 ] || fail "task '…' is 'open': the claim by '…' had ALREADY lapsed
   ${open_lead#-}s before this PR was opened, so this PR was not opened under a live claim."
```

`open_lead = claim.expired_at − pull_request.created_at`, in whole seconds.

## What clears it, and what does not

| Action | Clears the red? | Why |
|---|---|---|
| `git push` / empty commit | **NO** | `created_at` does not move on `synchronize`; the same two timestamps are compared again. |
| Close the task | yes | lifecycle `done` + `claim.closed_by` takes a different branch that never reads `PR_OPENED_AT`. |
| **Re-claim** the task | **YES, durably** | Two independent reasons, below. |
| Voluntary `release` after re-claim | **NO — poisons it** | `released_at >= expired_at` fails at `:373` ("a released task is unowned"). Never release a task whose PR is in flight. |

**Why a re-claim is durable, not a race.** A fresh claim moves the task to `in_progress` with a
`claim.worker`, and the `in_progress` branch (`:336`) never consults `PR_OPENED_AT` at all. And
even after that lease lapses again, the reap stamps a **new** `expired_at` — now far in the
*future* relative to the PR's `created_at` — so `open_lead` is then positive and the `open`
branch passes too. Both post-re-claim states are green. Only a voluntary release breaks it.

**The re-fire is cheaper than a push.** The workflow's trigger set is
`types: [opened, synchronize, reopened, edited, labeled, unlabeled]`
(`.github/workflows/pr-task-gate.yml:91`), and the ledger is read **live** at run time. So a
`gh run rerun --failed <run-id>`, a label toggle, or a body edit all re-evaluate — no push, no
new commit, no gate-cascade re-run.

    gh run rerun 31214773411 --failed     # the run that carried the red on #10509

## The measured instance (#10509)

```
TASK_ID:      cch-w49-s2-checkout-refuses-before-it-charges-and-the-plane-declares-its-billing-capability
claim.expired_at   2026-08-07T20:11:00.224272Z
PR created_at      2026-08-07T20:11:28Z
open_lead          −28s   → gate reported "ALREADY lapsed 27s before this PR was opened"
```

Re-derive:

```
bp task get cch-w49-s2-checkout-refuses-before-it-charges-and-the-plane-declares-its-billing-capability -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['doc']['claim'])"
gh pr view 10509 --json createdAt,state,mergeable,mergeStateStatus
gh run view --job 92985618730 --log | grep '##\[error\]pr-task-gate'
```

## Closing a task whose claim was REAPED (the four wave-49 rows)

`claim.worker` is `null` after a TTL reap, so `bp task close <id> <worker> <epoch>` must name the
**`previous_worker`** — that is the `:self_resume` arm in
`api/lib/barkpark/tasks/internal.ex:105-124` (it checks `previous_worker` *and* `released_by`,
because a reap writes the first and a release the second). Anything else is
`{:error, {:not_holder, …}}` and needs a recorded `holder_override` reason.

Two traps:

1. **`previous_worker` is TRUNCATED to ~50 chars** on the stored document. Copy the stored string
   verbatim; do not reconstruct it from the task title.
2. **`observed_epoch` is the CURRENT epoch on the document**, not the epoch the builder printed
   when it claimed (the reap and any pulse bump it).

The merge-gated criterion auto-stamps: `unmet_after_autostamp/2`
(`api/lib/barkpark/tasks/close.ex:431,448`) flips merge-gate criteria met when the close carries a
`landed` digest naming the PR — so a correct close is one command per row.

    git show origin/main:api/lib/barkpark/tasks/internal.ex | sed -n '95,124p'
    git show origin/main:api/lib/barkpark/tasks/close.ex    | sed -n '425,460p'
