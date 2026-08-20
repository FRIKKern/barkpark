# Re-derivation recipe — the crown row assertion (dr-w26, verifier `crown-row-assertion`)

Ground: `origin/main` @ `0239dd4ee662dd30c4d8da0c6b9a149638224b1d` (2026-08-09).
NOTE: the primary checkout's HEAD was `0789ab90a`, **717 commits behind** origin/main and the
crown schema file did not exist in the worktree — every read below goes through
`git show origin/main:` / `git grep origin/main` on purpose.

## The claim

A crown criterion that asserts only on `delivering_run_id` SHAPE (the wording in
`dr-w25-s8-crown-gets-its-writer` criterion 12) is GREEN TODAY on a hand-posted probe.
Adding "inserted_at falls inside the delivering run's `[createdAt, updatedAt]` window"
refuses that probe by 22m47s and accepts a row a recorder job writes.

## Re-derive

    # 1. the only row the crown has ever held
    ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" \
       -c "select sha,delivering_run_id,target,carried,queued_self_seconds,inserted_at from platform_deliveries order by inserted_at"'
    # → 2e38228b0048901b166d915d222cfc47f6f470d6|31255918184|cp|f||2026-08-08 12:23:21.862544  (1 row)

    # 2. that run's window
    gh run view 31255918184 --json databaseId,headSha,workflowName,conclusion,createdAt,updatedAt
    # → created 2026-08-08T11:51:21Z, updated 2026-08-08T12:00:34Z  →  row is 22m47s LATE

    # 3. the window clause cannot false-red a recorder row: run updatedAt >= last job completedAt
    gh run view 31284795417 --json jobs,createdAt,updatedAt
    # → created 23:48:15Z; last job completedAt 23:54:20Z; run updatedAt 23:54:21Z

    # 4. inserted_at is UTC, stamped by the CP app; CP clock skew measured sub-second
    ssh ... 'docker exec cloud-db-1 psql ... -c "show timezone" -c "select extract(epoch from now())"'

    # 5. carried has NO default (D422 honored in the schema); queued_* have zero rendered readers
    git show origin/main:cloud/lib/barkpark_cloud/platform_delivery.ex | sed -n '100,125p'
    git grep -n "queued_self_seconds\|queued_pickup_seconds\|queued_stall_seconds" origin/main
    # → schema + migration + test ONLY. No .go, no .heex, no route render.

    # 6. #11007's Go reader decodes carried as a plain bool (NULL -> confident false)
    gh pr diff 11007 | sed -n '/^+++ b\/internal\/cloudclient\/deliveries.go/,/^diff /p' | grep '`json'
    # → Carried bool `json:"carried"`   and NO QueuedSelf/Pickup/Stall fields

## The checker

`crown_row_check.sh` (four clauses C1 shape / C2 resolvable+workflow / C3 window / C4 carried
honesty) was run against the live row (REFUSED at C3) and a synthetic recorder-timed row
(ACCEPTED). Reproduce by pasting the criterion from the wave Paper.
