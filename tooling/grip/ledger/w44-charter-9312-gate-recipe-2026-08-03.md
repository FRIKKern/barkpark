# Charter PR #9312 — the one red, and the re-fire that clears it (PDS w44 verify)

VERDICT: #9312 is blocked by exactly ONE required context, `PR references an
active task`, and it is a LAPSED-CLAIM red on the epic GOAL task
`task-2ac1f95237c4a8e5` — not a conflict, not a docs gate, not a spec drift.
The remedy is a RE-CLAIM plus a RE-FIRE, and the re-fire needs NO push.

## Leg 1 — the required set is four names; three are green

    git show origin/main:.github/required-checks.json |
      python3 -c 'import sys,json;print([c["context"] for c in json.load(sys.stdin)["protection"]["required_status_checks"]["checks"]])'
    # -> ['Cloud gate', 'Console gate', 'Elixir gate', 'PR references an active task']

    gh pr checks 9312
    # -> Cloud gate pass / Console gate pass / Elixir gate pass
    # -> PR references an active task  FAIL
    # -> Required-check spec drift (advisory)  fail  <- NOT in the required set

## Leg 2 — the red's exact cause, read from the job, not guessed

    gh run view --job 91535708841 --log | grep pr-task-gate:
    # -> pr-task-gate: FAIL: task 'task-2ac1f95237c4a8e5' is 'open': the claim by
    #    'pds-w42-decide' had ALREADY lapsed 7536s before this PR was opened

    bp task get task-2ac1f95237c4a8e5 -o json | python3 -c \
      'import sys,json;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"],d["claim"]["epoch"],d["claim"]["expired_at"],d["claim"]["previous_worker"])'
    # -> open 68 2026-08-02T17:00:00.571870Z pds-w42-decide
    # PR created 2026-08-02T19:05:37Z; 19:05:37 - 17:00:00 = 7537s. The gate's
    # `open_lead` is negative, which is the `open`-branch fail (pr-task-gate.sh:382).

A re-claim moves lifecycle to `in_progress` WITH a `claim.worker`, which takes
the gate's in_progress branch (pr-task-gate.sh:336-338) and passes. The task's
own `claim.now` records wave 42 doing exactly this: "Re-claimed to clear the
pr-task-gate lease lapse."

## Leg 3 — the re-fire needs NO push (measured, not assumed)

pr-task-gate.yml triggers on `[opened, synchronize, reopened, edited]`. On PR
#9332, the gate flipped on the SAME head SHA with no new commit:

    git log -1 --format='%H %cI' 64c8b600cca758f764196b80896cfa262de36e55
    # -> 64c8b600... 2026-08-02T21:47:06+02:00   (no later commit)
    gh api "repos/FRIKKern/barkpark/commits/64c8b600cca758f764196b80896cfa262de36e55/check-runs?filter=all" \
      -q '.check_runs[]|select(.name=="PR references an active task")|"\(.conclusion)\t\(.completed_at)"'
    # -> success  2026-08-03T10:30:33Z
    # -> failure  2026-08-03T10:11:19Z

So: `bp task claim task-2ac1f95237c4a8e5 <worker>`, then re-run the failed job
(or touch the PR body to emit `edited`). No commit required.

## Caveat that outranks the recipe

By the time this row was written, #9332/#9333/#9334 had ALREADY MERGED
(2026-08-03T10:49:48Z / 10:49:56Z / 10:50:04Z) while #9312 was still open.
Charter-first was not held. `git grep -nE 'PDS-D6(3[3-9]|4[0-2])' origin/main`
returns 13 hits in `api/**` and `scripts/**`, and
`git show origin/main:.claude/workflows/bp-pds-charter.md | grep -cE 'D6(3[3-9]|4[0-2])'`
returns 0. Landing #9312 is now a REPAIR, not a precondition.
