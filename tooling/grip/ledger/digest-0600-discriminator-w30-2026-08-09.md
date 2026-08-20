# digest-0600 discriminator — re-derivation recipes (wave 30, 2026-08-09)

Question: is a SAME-DAY discrimination of PR #11255 (DailyDigestWorker unique states)
possible without inserting a probe job?

Answer: YES — the running BEAM answers directly. No probe needed.

## R1 — running control-plane BEAM reports the worker's live unique opts (L1)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc \
       "IO.inspect(BarkparkCloud.Workers.DailyDigestWorker.__opts__(), limit: :infinity)"'

Expected on the fixed build: `unique: [period: 86400, states: [:available, :scheduled,
:executing, :retryable, :suspended]]` — `:completed` ABSENT.
Pre-fix (4c8314c94^) the whole `states:` key is absent (`unique: [period: 86_400]`),
so Oban 2.23 defaults apply and `:completed` IS included.

## R2 — prod oban_jobs digest rows (which days actually fired)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -Atc \
       \"select id,state,worker,args::text,inserted_at from oban_jobs \
         where worker like '"'"'%DailyDigest%'"'"' order by inserted_at desc limit 10;\""'

## R3 — stranded-row check (would a pending row eat the genuine 06:00Z tick?)

    ... -Atc "select state,count(*) from oban_jobs where worker like '%DailyDigest%' group by state"

Only `completed` rows ⇒ nothing stranded; the cron tick inserts fresh at 06:00Z.

## R4 — deployed sha / restart time

    gh run view 31316266628 --json name,conclusion,headSha,createdAt
    ssh ... 'docker inspect -f "{{.Name}} started={{.State.StartedAt}}" cloud-control_plane_blue-1'

## Why the 2026-08-10T06:00Z tick alone is NOT a proof

Under the bug the block is `new_tick_subsecond < previous_completed_row_subsecond`.
Previous row: 2026-08-09 06:00:00.337078 ⇒ P(suppressed) ≈ 0.337, P(fires anyway) ≈ 0.663.
One firing tick is therefore ~66% likely even if nothing had been fixed.
Behavioural-only confidence <5% needs ~7 consecutive ticks ⇒ re-read 2026-08-16.
R1 makes that wait unnecessary.

## Cost of the Rung-2 probe (NOT run, deliberately)

Inserting a DailyDigestWorker job is not read-only: on the live (fixed) build it is
ACCEPTED and sends a real fleet digest email to every platform admin. And under the
old build the resulting completed row (inserted_at ≈ 14:1x) would sit inside the
rolling 86,400s window covering 2026-08-10T06:00Z and suppress the genuine tick.
The probe is both side-effecting and self-defeating; R1 supersedes it.
