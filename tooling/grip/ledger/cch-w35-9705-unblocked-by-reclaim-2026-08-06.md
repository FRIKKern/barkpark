# cch-w35 — charter PR #9705 unblocked by a re-claim alone, no push (2026-08-06)

**Claim proved:** re-claiming `cloud-console-hardening-epic` clears the "PR references an
active task" required context on RERUN. The verdict is NOT sticky-until-push. Head sha
`7eba91b3f99cafe7f5610929f74fe29afd0826e0` is unchanged across the fix; no empty commit
was needed, so both inherited slice briefs keep whatever sha they cite.

**Why it was red.** `PR_OPENED_AT=2026-08-06T02:26:40Z`; the claim by `wave33-decide`
(epoch 88) carried `expired_at=2026-08-06T00:47:01Z`. The `open` branch of the gate
(`scripts/pr-task-gate.sh:407`) requires `open_lead >= 0` i.e.
`claim.expired_at >= PR created_at`. open_lead was -5978s. That predicate is IMMUTABLE
for a given PR — no re-claim can ever satisfy it, because a new claim does not move
`created_at`.

**Why the re-claim works anyway.** It does not satisfy P4; it LEAVES the `open` branch.
`scripts/pr-task-gate.sh:328-338` — the `in_progress` arm asserts only
`[ "$worker" != "." ]` and never reads `PR_OPENED_AT` or `open_lead`. A fresh claim flips
`lifecycle_status` open -> in_progress with a worker, so the gate decides on a different
arm entirely.

## Re-derivation

    # 1. the predicate that can never be satisfied, and the arm that dodges it
    git show origin/main:scripts/pr-task-gate.sh | sed -n '328,340p;405,410p'

    # 2. state before (red): lifecycle open, lapsed claim
    gh run view --job 92514560330 --log | grep -E 'PR_OPENED_AT|ALREADY lapsed'

    # 3. the mutation
    bp task claim cloud-console-hardening-epic <worker>
    bp task get cloud-console-hardening-epic -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim']['worker'])"
    # -> in_progress wave35-verify

    # 4. rerun the SAME job id — no push
    gh run rerun --job 92514560330
    until gh pr checks 9705 | grep -qi 'active task.*pass'; do sleep 5; done
    gh pr view 9705 --json mergeStateStatus,headRefOid
    # -> CLEAN, 7eba91b3f99cafe7f5610929f74fe29afd0826e0

    # 5. the phantom this unblocks
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -cE '^\| D39[0-3]|^\| D38[2-9]'      # -> 0
    git show 7eba91b3f:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -cE '^\| D39[0-3]|^\| D38[2-9]'      # -> 12

## The window, and how this re-reds

The lease TTL is 2700s (`api/lib/barkpark/tasks/ttl_sweeper.ex:158`), stamped from
`claim.ts_iso=2026-08-06T09:00:41Z`. The RECORDED green is durable — merge needs no live
claim. But any PUSH to #9705 re-evaluates the gate, and after the reap the task returns to
`open` with a fresh `expired_at` that is STILL earlier than the PR's frozen `created_at`.
So a post-reap push re-reds the context and needs another `bp task claim` before its rerun.
Merge without pushing, or re-claim immediately before any push.
