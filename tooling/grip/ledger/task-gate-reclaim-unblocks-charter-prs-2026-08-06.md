# Re-derivation recipe — re-claiming the epic task turns the required task gate GREEN on #9876 and #9905

Wave 7 VERIFY, assignment `task-gate-reclaim-unblocks`. Established 2026-08-06 ~22:47–23:11 UTC
against origin/main = `ef77af2748ceda54fdd6e078f71a6e6044b55439` and the live guerrilla ledger.

## Claim

`scripts/pr-task-gate.sh` was failing #9876 and #9905 on the **`open` + already-lapsed-claim**
arm (the `open_lead >= 0` clause). Claiming `task-fb4fb869490b4213` moves the document to
`lifecycle_status: in_progress` with a `claim.worker`, which routes the gate into the
**`in_progress`** arm — a different branch entirely, not a repaired `open` branch — and that arm
passes on `worker != "."` alone. `EXPECTED_WORKER` is empty in the workflow, so no worker-identity
clause applies. Both PRs are now `mergeStateStatus: CLEAN`.

## Re-derive

    # 1. the arm that was failing — line 407 EXACTLY, the `open_lead -ge 0` clause
    git show origin/main:scripts/pr-task-gate.sh | sed -n '404,412p'

    # 2. the arm a claim routes into
    git show origin/main:scripts/pr-task-gate.sh | sed -n '330,340p'

    # 3. the exact document CI reads — unauthenticated, published, dataset `production`
    curl -sS "https://guerrilla.barkpark.cloud/v1/data/doc/production/task/task-fb4fb869490b4213"

    # 4. run the gate as CI runs it, no CI required
    git show origin/main:scripts/pr-task-gate.sh > /tmp/g.sh
    TASK_ID=task-fb4fb869490b4213 PR_OPENED_AT=2026-08-06T16:03:05Z \
      LEDGER_BASE=https://guerrilla.barkpark.cloud bash /tmp/g.sh

    # 5. the check is REQUIRED and blocking (four contexts, enforce_admins true)
    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '.required_status_checks.contexts, .enforce_admins.enabled'

## Verdicts, verbatim

BEFORE (run 31120965534, job 92681373757, 2026-08-06T22:14:26Z):

    pr-task-gate: FAIL: task 'task-fb4fb869490b4213' is 'open': the claim by 'epic-cycle-decide'
    had ALREADY lapsed 8884s before this PR was opened, so this PR was not opened under a live
    claim. Re-claim it: bp task claim task-fb4fb869490b4213 <worker>

AFTER (`bp task claim task-fb4fb869490b4213 epic-cycle-verify` → epoch 18, 22:47:35Z), identical
line on both re-run jobs — #9905 job 92716274568 at 23:08:50Z, #9876 run 31120965534 at 23:10:50Z:

    pr-task-gate: PASS: task 'task-fb4fb869490b4213' is task-backed — in_progress, claimed by
    'epic-cycle-verify'

## Three things this also settled

1. **A plain re-run DOES clear this gate's sticky verdict.** `gh run rerun <id> --failed` flipped
   the required context on both PRs with no push. The "only a push re-fires a sticky verdict"
   folklore does not hold for `pr-task-gate.yml`.
2. **The green survives the lease lapse.** `@default_ttl_seconds 2700` (ttl_sweeper.ex:159) reaps
   at ~23:32Z, stamping `claim.expired_at` ≈ 23:32Z — *after* #9876's `created_at` 16:03:05Z and
   #9905's 18:19:25Z — so the `open` arm's `open_lead >= 0` clause would pass on any future re-run
   too. Do not `release` the claim: `released_ge_expired = yes` reds that same arm unconditionally.
3. **#9889's red is not this class.** Its gate job (92681088637) died on
   `##[error]Service Unavailable / Failed to resolve action download info` — GitHub's own action
   download, before any ledger read. Re-run, unrelated to any claim.

## Re-derive the ledger's TTL

    git show origin/main:api/lib/barkpark/tasks/ttl_sweeper.ex | sed -n '155,165p'
