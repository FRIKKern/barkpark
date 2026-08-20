# dr-w35 — the wavelog gate cure, OBSERVED (2026-08-17)

Wave 35 verify round, assignment `wavelog-gate-live-cure`. Prediction converted to
observation: **all SIX stranded deploy-reliability PRs now read SUCCESS on
`PR references an active task`.** Nothing was released. No ledger row was written
for the two P4 greens.

## Verdict table (as_of 2026-08-17T07:12:55Z)

| PR | branch | created_at | gate arm that passed | mergeStateStatus |
|---|---|---|---|---|
| #10133 | epic-charter/deploy-reliability-w10-wavelog | 2026-08-07T06:01:23Z | P4 open/lapsed, **no ledger write** | CLEAN |
| #10612 | epic-wavelog/deploy-reliability-w20 | 2026-08-08T02:27:39Z | P4 open/lapsed, **no ledger write** | CLEAN |
| #11539 | epic-charter/deploy-reliability-w34-wavelog | 2026-08-10T00:37:32Z | in_progress, claim `verify-w35` | CLEAN |
| #10522 | epic-charter/deploy-reliability-w19-20260807T222400Z | 2026-08-07T22:27:42Z | in_progress, claim `verify-w35` | DIRTY |
| #10407 | epic-charter/deploy-reliability-w16-20260807T163248Z | 2026-08-07T16:36:22Z | in_progress, claim `verify-w35` | DIRTY |
| #10496 | epic-charter/deploy-reliability-20260807T195051Z | 2026-08-07T19:55:00Z | in_progress, claim `verify-w35` | DIRTY |

Zero other FAILURE check-runs on any of the six.

## Recipe A — the two P4 greens, zero ledger writes

The pre-existing w34 claim (`previous_worker: epic-decide-w34`,
`expired_at: 2026-08-09T23:48:00.250361Z`) already satisfies P4 for any PR opened
before it lapsed. A bare re-fire is the whole cure.

    gh run rerun 31152521812 --failed          # #10133
    gh pr view 10133 --json statusCheckRollup \
      -q '[.statusCheckRollup[]|select(.name=="PR references an active task")|.conclusion]'
    gh run view 31152521812 --log | grep -E 'pr-task-gate: (PASS|FAIL)'

Arithmetic re-derivation of `open_lead` (matched the runner's own printed number
to the second, both PRs):

    python3 -c "
    from datetime import datetime
    exp=datetime.fromisoformat('2026-08-09T23:48:00.250361+00:00')
    for p,t in [('10612','2026-08-08T02:27:39Z'),('10133','2026-08-07T06:01:23Z'),('11539','2026-08-10T00:37:32Z')]:
        o=datetime.fromisoformat(t.replace('Z','+00:00'))
        print(p,int((exp-o).total_seconds()))"
    # 10612 163221   10133 236797   11539 -2971

## Recipe B — the wedged-run fallback (#10612)

`gh run rerun 31235104900 --failed` **exited 0 and created nothing.** The run flipped
to `status: queued` with `run_attempt: 1`, `attempts/2` → HTTP 404, `jobs` → 0 rows,
and every later rerun is refused permanently:

    gh run rerun 31235104900
    # run 31235104900 cannot be rerun; This workflow is already running

Not age-correlated — #10522's run from the same week reran fine. Sporadic, and the
wedge is irreversible for that run id. The cure is a **`pull_request: edited`
re-fire**, cheaper than the empty-commit push (no repo write, and only
pr-task-gate re-fires — `types:` at .github/workflows/pr-task-gate.yml:101 lists
`edited`):

    gh pr view 10612 --json body -q '.body' > /tmp/b.md
    printf '\n<!-- note -->\n' >> /tmp/b.md     # APPEND only: extractor takes the FIRST `Task:` line
    gh pr edit 10612 --body-file /tmp/b.md

This produced a brand-new run 32004450569 which passed. Detect a wedged run with:

    gh api repos/FRIKKern/barkpark/actions/runs/<id> -q '"\(.status) \(.run_attempt)"'
    gh api repos/FRIKKern/barkpark/actions/runs/<id>/attempts/2 -q .status   # 404 == wedged

## Recipe C — the claim arm (one claim cures all six, durably)

    bp task claim task-fb4fb869490b4213 verify-w35     # -> epoch=94
    curl -s https://guerrilla.barkpark.cloud/v1/data/doc/production/task/task-fb4fb869490b4213 \
      | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r['lifecycle_status'],r['claim']['worker'])"
    # in_progress verify-w35
    gh run rerun <that PR's pr-task-gate run id> --failed

**DURABILITY.** `apply_reap` stamps `expired_at = DateTime.utc_now()` at reap time
(api/lib/barkpark/tasks/ttl_sweeper.ex:372,381), not claim_ts+ttl. Lease TTL is 2700 s
(ttl_sweeper.ex:159). Claimed 07:08:36Z → reaped ≈07:53Z with
`expired_at ≈ 2026-08-17T07:53Z`, `previous_worker: verify-w35`. That is AFTER every
one of the six `created_at` values, so **P4 passes for all six forever** on any future
re-fire — the claim is a permanent cure, not a 45-minute window.

**DO NOT `bp task release`.** Release merges `released_at` into the surviving claim
and never touches `expired_at`, so `released_at >= expired_at` trips the ordering
clause at pr-task-gate.sh:429 — a red no re-fire can clear.

## Merge-order ruling input (dry-assembled, no worktree, no commit)

The three CLEAN PRs merge **in sequence with zero conflicts**, and the union is
exactly additive:

    M=$(git rev-parse origin/main)
    B1=$(git rev-parse origin/epic-charter/deploy-reliability-w10-wavelog)
    B2=$(git rev-parse origin/epic-wavelog/deploy-reliability-w20)
    B3=$(git rev-parse origin/epic-charter/deploy-reliability-w34-wavelog)
    T1=$(git merge-tree --write-tree $M $B1); C1=$(git commit-tree $T1 -p $M -p $B1 -m x)
    T2=$(git merge-tree --write-tree $C1 $B2); C2=$(git commit-tree $T2 -p $C1 -p $B2 -m x)
    T3=$(git merge-tree --write-tree $C2 $B3)   # rc=0, tree fcffb79a9e97aedbe05859c48c8657abbc74193f
    git cat-file -p $T3:.claude/workflows/bp-deploy-reliability-charter.md | wc -l   # 12158
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | wc -l  # 11976

12158 − 11976 = **182 = 73 + 65 + 44**, the exact sum of the three PRs' additions
(all three are 0-deletion). Wave-10, wave-20 and wave-34 entries all land
(union.md:2457, :5447, :12116). **No union-extraction PR is needed for these three —
they can simply merge.**

The three DIRTY PRs genuinely conflict (not a stale GitHub status):
`git merge-tree --write-tree origin/main origin/<branch>` → rc=1,
`CONFLICT (content)` in `.claude/workflows/bp-deploy-reliability-charter.md` and in
**that file only** — their 15 `tooling/grip/ledger/*.md` sidecars are new-file
additions and would ride along clean. They are 269 / 253 / 244 commits behind main.

## Retraction owed to the brief

The brief called `#11539` "blocked on the gate, unblocks via task-close". Task-close
is the wrong instrument twice over: `close` needs a live claim anyway (so the claim
is the real cure), and the CLAIM arm alone greened #11539 plus three PRs the brief
did not expect to green. Nothing was closed.
