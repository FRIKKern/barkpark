# 11076 sticky pr-task-gate red: cleared by a RERUN, no push (2026-08-09)

Wave-58 verifier assignment `11076-sticky-red-recovery`. PR #11076 (`cch-w57-s5`),
head `2065563706b399d68a20ff4ca0be1a2edd5ead51`, was the last unmerged wave-57 PR.

## Result

`gh run rerun 31289611121 --failed` cleared it. No push, no empty commit.
`mergeStateStatus` went `BLOCKED` -> `CLEAN` in one rerun.

## Re-derivation

```sh
# state before (fail) and after (pass) — the deciding context only
gh pr checks 11076 | grep -i "active task"
gh pr view 11076 --json state,mergeable,mergeStateStatus

# the red's own text (the branch that fired)
gh run view 31289611121 --log-failed | grep -i "already lapsed"

# the fix
gh run rerun 31289611121 --failed
sleep 95
gh pr checks 11076 | grep -i "active task"
gh run view --job 93188220023 --log | grep "pr-task-gate: PASS"
```

## Mechanism (two-part, and the order matters)

The red came from the `open` lifecycle branch, `pr-task-gate.sh:393`
(`open_lead >= 0`): the claim's `expired_at` predated `PR_OPENED_AT` by 92s.

`PR_OPENED_AT` is `github.event.pull_request.created_at`
(`.github/workflows/pr-task-gate.yml:225`), which is IMMUTABLE across
`synchronize`/`edited`/`reopened` — the workflow's own comment says so and cites
#6414. Therefore:

- A rerun ALONE can never clear a lapsed-claim red: both operands are fixed.
- A PUSH / empty commit ALONE can never clear it either, for the same reason —
  `created_at` does not move on synchronize. This refutes the general
  "only a PUSH re-fires a sticky verdict" reading for THIS block shape.
- What clears it is a LEDGER WRITE that changes `lifecycle_status`, then a rerun
  to re-read the ledger. The re-claim (worker `epic-wave-reviewer-w57`,
  `2026-08-09T02:09:01Z`, epoch 8) moved the task `open -> in_progress`, so the
  rerun took the `in_progress` branch (`pr-task-gate.sh:315-324`) — which only
  requires a non-empty `claim.worker` — and passed.

`EXPECTED_WORKER` was empty on this run, so the re-claiming worker did not have
to match the original builder.

## Standing hazard (unchanged, do not test it)

Do NOT `bp task release` after re-claiming. `apply_release_update/2` merges
`released_at` into the surviving claim and never touches `expired_at`, so
`released_at >= expired_at` trips `pr-task-gate.sh:359` — a refusal no re-fire
can clear, only a fresh claim. Not exercised here; quoted from the gate's own
error text and confirmed against the script.
