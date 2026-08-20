# 11027 unjammed: the re-claim + rerun cure was RUN, and it flipped the gate

Wave 27 VERIFY, assignment `unjam-11027-and-prove-the-cure`. 2026-08-09T07:59-08:00Z.
This is not a reading of the cure. The cure was EXECUTED against the live ledger and
the live check run, and the flip was observed.

## The before state (run, not inherited)

    gh pr view 11027 --json mergeable,mergeStateStatus,statusCheckRollup \
      --jq '{m:.mergeable,s:.mergeStateStatus,fail:[.statusCheckRollup[]|select(.conclusion=="FAILURE")|.name]}'
    # => {"fail":["PR references an active task"],"m":"MERGEABLE","s":"BLOCKED"}

Exactly ONE failure, and it is the epic's own lapsed claim. The gate's own error text
named the cure verbatim, including the re-fire and the do-not-release warning:

    gh run view --job 93184991248 --log | grep -i "pr-task-gate: FAIL"
    # ##[error]pr-task-gate: FAIL: task 'task-fb4fb869490b4213' is 'open': the claim by
    # 'epic-cycle-decide-w25' had ALREADY lapsed 29877s before this PR was opened ...
    # Re-claim it: bp task claim task-fb4fb869490b4213 <worker>. THEN RE-FIRE THIS CHECK
    # ... gh run rerun 31289824906 --failed. And do NOT release the claim afterwards.

Ledger read at the exact URL the gate uses (unauthenticated, dataset `production`,
note the `/task/` path segment — `/v1/data/doc/production/<id>` without it 404s):

    curl -s "https://guerrilla.barkpark.cloud/v1/data/doc/production/task/task-fb4fb869490b4213" \
      | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];c=r['claim'];print(r['lifecycle_status'],c['worker'],c['previous_worker'],c['expired_at'])"
    # open None epic-cycle-decide-w25 2026-08-08T16:47:00.617019Z

PR_OPENED_AT was 2026-08-09T01:04:58Z, so `open_lead` = expired_at - opened_at = -29877s,
which trips `scripts/pr-task-gate.sh` P4 (the last clause of the `open` branch).

## The cure, executed

    bp task claim task-fb4fb869490b4213 epic-cycle-verify-w27
    # task-fb4fb869490b4213 epoch=68 rev=49489e42efd71d5d38270a9fed511e7f

    # ledger now (same curl as above):
    # lifecycle_status=in_progress  claim.worker=epic-cycle-verify-w27  epoch=68
    # expired_at=None  released_at=None

    gh run rerun 31289824906 --failed        # 07:59:36Z
    until [ "$(gh run view 31289824906 --json status --jq .status)" = completed ]; do sleep 10; done

## The flip, observed

    gh run view --job 93217282429 --log | tail -1
    # pr-task-gate: PASS: task 'task-fb4fb869490b4213' is task-backed — in_progress, claimed by 'epic-cycle-verify-w27'

    gh pr view 11027 --json mergeable,mergeStateStatus,statusCheckRollup \
      --jq '{m:.mergeable,s:.mergeStateStatus,pending:[.statusCheckRollup[]|select(.status!="COMPLETED")|.name],fail:[.statusCheckRollup[]|select(.conclusion=="FAILURE")|.name]}'
    # => {"fail":[],"m":"MERGEABLE","pending":[],"s":"CLEAN"}

Note WHICH branch of the gate passed: `in_progress`, not the `open`+lapsed branch. The
re-claim does not repair the old lapse — it moves the task to a different case entirely.
`EXPECTED_WORKER` was empty in the job env, so the worker name is unconstrained
(`pr-task-gate.sh:472`).

## Why 25-behind does not block, and why no rebase is needed

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{strict:.required_status_checks.strict,contexts:.required_status_checks.contexts}'
    # {"strict":false,"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"]}

All four required contexts are SUCCESS. `strict:false` means the 25-commit lag is not a
merge blocker — and that matters beyond convenience: a rebase would push new commits,
which re-fires the gate, which re-opens the window in which a lapse or a release could
re-red it. Merging as-is fires nothing.

## The landmine that is still armed

`scripts/pr-task-gate.sh:429` — the ordering clause:

    [ "$released_ge_expired" = "no" ] || fail "task '...' is 'open' because its claim was RELEASED ..."

A `release` merges `released_at` into the SURVIVING claim and never clears `expired_at`,
so `released_at >= expired_at` becomes permanently true and NO re-fire can clear it —
only a fresh claim. The claim placed above is therefore left HELD deliberately.
A TTL reap is harmless by contrast: it stamps `expired_at` at the lease end, which is
after 2026-08-09T01:04:58Z, so a re-fired gate would take the `open` branch and still
compute `open_lead >= 0`. Reap survives; release does not.

## The time box, measured

    gh api repos/FRIKKern/barkpark/pulls/11027/files --jq '.[]|select(.filename|endswith("charter.md"))|.patch' | grep -E "^@@"
    # @@ -7987,3 +7987,432 @@
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | wc -l   # 7989

The charter change is a PURE TAIL APPEND (429 added, 0 deleted) at the last line of the
file. That is exactly where wave 27's own charter write lands, so the conflict is not a
risk — it is a certainty the moment wave 27 writes. The three older charter PRs already
took that hit:

    for p in 10407 10496 10522; do gh pr view $p --json number,mergeable,mergeStateStatus; done
    # 10407 CONFLICTING/DIRTY · 10496 CONFLICTING/DIRTY · 10522 CONFLICTING/DIRTY

and #11027 is the only MERGEABLE/CLEAN charter PR of the four. No
`epic-charter/deploy-reliability-w27-*` branch exists yet
(`gh api repos/FRIKKern/barkpark/branches --paginate --jq '.[].name' | grep w27`), so the
window was still open when this was written.

## What merging it actually buys (checked, not assumed)

D447-D461 are absent from main and present only here:

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -oE "^### D[0-9]+" | sort -uV | tail -1
    # ### D446

So the digest's "D456 is a phantom" is right about MAIN and wrong about the world: D456
exists, in this PR, as "SOMETHING DID REPORT THE OUTAGE. IT TOLD THE CUSTOMER, THIRTY
TIMES...". It is UNMERGED, not fictional. Merging #11027 is what converts fifteen
decisions from hearsay into citable charter — and the same act is what makes citing them
legitimate. Until then: restate verbatim, never cite.
