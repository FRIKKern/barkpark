# W28 v9 — bound depth ceiling + the sub-second double-mint

Re-derivation recipes. All run 2026-08-09 ~10:16Z against cloud-db-1 (178.105.92.191)
and `git show origin/main` at the then-current tip.

## DB helper

```sh
psql() { ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'; }
```

## R1 — the depth ladder and its sanity total

```sh
printf "SELECT deferral_depth, count(*) FROM deployments WHERE status='deferred' AND deferral_depth IS NOT NULL GROUP BY 1 ORDER BY 1;\nSELECT count(*) AS sanity_total FROM deployments WHERE status='deferred';\n" | psql
```
Result 2026-08-09: 1/461 2/357 3/253 4/142 5/50 6/12 7/2 8/1 9/1 = 1279 stamped;
sanity_total 3097. NOTHING at 10 or 11.

## R2 — the whole stamped window IS the post-instrumentation window

```sh
printf "SELECT min(inserted_at), max(inserted_at), count(*) FROM deployments WHERE status='deferred' AND deferral_depth IS NOT NULL;\nSELECT date_trunc('day', inserted_at) d, max(deferral_depth) maxd, count(*) n FROM deployments WHERE status='deferred' AND deferral_depth IS NOT NULL GROUP BY 1 ORDER BY 1;\n" | psql
```
First stamp 2026-08-07 10:12:35.033826 → so every stamped row is post-instrumentation.
Per-day max: 08-07 → 6, 08-08 → 9, 08-09 → 6.

## R3 — post-W20-backoff ladder (cap landed 2026-08-08 02:35:40 UTC, commit 2673eb009 / #10611)

```sh
git log origin/main --format='%h %ad %s' --date=iso -S'@deferral_backoff_cap_seconds' -- cloud/lib/barkpark_cloud/sites/deploy.ex
printf "SELECT deferral_depth, count(*) FROM deployments WHERE status='deferred' AND inserted_at > '2026-08-08 02:35:40' GROUP BY 1 ORDER BY 1;\n" | psql
```
Post-cap max depth = 7 (n=1), 690 rows.

## R4 — did the backoff lengthen the chain clock?

```sh
printf "WITH g AS (SELECT site_id, inserted_at, inserted_at - lag(inserted_at) OVER (PARTITION BY site_id ORDER BY inserted_at) AS gap FROM deployments WHERE status='deferred') SELECT date_trunc('day', inserted_at) d, count(*) n, round(avg(extract(epoch FROM gap))::numeric,1) avg_gap_s, percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM gap)) p50_gap_s FROM g WHERE gap IS NOT NULL AND gap < interval '1 hour' GROUP BY 1 ORDER BY 1;\n" | psql
```
p50 gap: 08-05 65.8s / 08-06 63.2s / 08-07 61.3s → 08-08 125.7s / 08-09 121.7s. Doubled.

## R5 — sub-second double-mints (the premise under test)

```sh
printf "SELECT site_id, count(*) n, min(inserted_at), max(inserted_at) FROM deployments d WHERE status='deferred' AND EXISTS (SELECT 1 FROM deployments e WHERE e.site_id=d.site_id AND e.status='deferred' AND e.id<>d.id AND abs(extract(epoch FROM (e.inserted_at-d.inserted_at)))<2) GROUP BY 1 ORDER BY 2 DESC;\n" | psql
```
4 rows, 2 sites, ALL inside 2026-08-07 02:31:24.419 – 02:31:25.926. Widening the
window to 60s gives 12 rows, all ≤ 2026-08-07 02:31:52 — i.e. entirely BEFORE
deferral_depth instrumentation (10:12:35). Zero since.

## R6 — the refutation: no Oban job produced those rows

```sh
printf "SELECT id, worker, state, args->>'site_id' sid, inserted_at, scheduled_at, attempted_at FROM oban_jobs WHERE worker LIKE '%%AutoDeploy%%' AND (attempted_at BETWEEN '2026-08-07 02:20:00' AND '2026-08-07 02:35:00') ORDER BY attempted_at;\nSELECT min(id), max(id), count(*) FROM oban_jobs WHERE id BETWEEN 291780 AND 291800;\n" | psql
```
No AutoDeployWorker execution exists at 02:31:24.4 / .05 / .53 / .92 for sites
d8e9c2c7 or 0cf76788. The id range 291780–291800 is DENSE (21 of 21) so nothing
was pruned. The `site_id` unique did not leak — an unattributed producer of
`trigger='content-auto'` deferred rows exists.

## R7 — structural maximum is 11, not 12

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n '@max_consecutive_capacity_deferrals\|prior >= max_consecutive_deferrals'
```
`@max_consecutive_capacity_deferrals 12` (:1187); `defer/3` fails at
`prior >= max_consecutive_deferrals(cause) - 1` (:1272), so `prior = 11` writes
the 12th round as `failed`. Highest writable `deferral_depth` = 11.
