# Row-less and never-settled deploy population — re-derivation recipe (2026-08-07 17:48–17:51 UTC)

Wave 17 verifier `rowless-and-never-settled-population`. Every number below is
re-derivable with the commands as written. No mutation was performed.

## Transport

```bash
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' < /tmp/rowless.sql
```

## (a) never-settled rows no reaper covers — RESULT 0

```sql
SELECT count(*) , min(d.inserted_at)
FROM deployments d JOIN sites s ON s.id = d.site_id
WHERE d.status='queued' AND d.claim_epoch=0
  AND (s.kind='node' OR (s.kind='static' AND s.bootstrap_dataset IS NOT NULL));
-- 0 | (null)   @ 2026-08-07 17:48:03Z
```

## (b) queued/building older than one hour — RESULT 0 (no such status exists)

```sql
SELECT status, count(*) FROM deployments GROUP BY 1;
-- failed 18622 | live 10391 | deferred 2124   (no queued, no building, at all)
SELECT count(*) FILTER (WHERE claim_epoch=0), count(*) FROM deployments;
-- 7 | 31137   — and all 7 epoch-0 rows are status='failed' (settled)
```

## (c) Oban cancelled/discarded for the deploy workers — RESULT 0, 7-day window

```sql
SELECT worker, state, count(*) FROM oban_jobs
WHERE worker ILIKE '%AutoDeploy%' OR worker ILIKE '%SiteDeploy%' GROUP BY 1,2;
-- BarkparkCloud.Sites.AutoDeployWorker | completed | 12899   (only row)
SELECT min(inserted_at) FROM oban_jobs;  -- 2026-07-31 17:48:34 = exactly 7d
```
Bound: `{Oban.Plugins.Pruner, max_age: 60*60*24*7}` — `git show
origin/main:cloud/config/config.exs | sed -n 262p`.

## The class that IS material: attempts that mint no row (coalesced)

```sql
WITH o AS (SELECT date_trunc('day', completed_at) d, count(*) c FROM oban_jobs
           WHERE worker='BarkparkCloud.Sites.AutoDeployWorker' GROUP BY 1),
     r AS (SELECT date_trunc('day', inserted_at) d, count(*) c FROM deployments
           WHERE trigger='content-auto' GROUP BY 1)
SELECT o.d, o.c AS jobs, r.c AS rows, o.c-r.c AS rowless FROM o JOIN r USING (d) ORDER BY 1;
-- 08-01 0 | 08-02 0 | 08-03 0 | 08-04 0 | 08-05 171 | 08-06 1584 | 08-07 106
-- (07-31 negative: Oban prune horizon, not a signal)
```

Counter landed the same day (`git log origin/main -S record_coalesced_attempt` →
667276b22, PR #10248). It fired once — 6 attempts on 1 row at 10:17:38Z — and the
hourly gap for that hour is exactly 6. After 10:17:38Z: 431 jobs / 430 rows.

`git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -c coalesced`
→ 0. The census denominator is `volume` (row count) only.
