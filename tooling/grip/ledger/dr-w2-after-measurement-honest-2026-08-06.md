# Re-derivation recipe — deploy-reliability W2 AFTER measurement (honest)

Taken 2026-08-05 23:25–23:29Z on the cloud control plane (178.105.92.191),
load average 0.08–0.30 across every run (`uptime` printed before AND after each).

## Cohort census, pinned + repeatable-read

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'uptime; docker exec -i \
  -e PGPASSWORD=78d44f09ad1663acdc470864e3cea1bc cloud-db-1 \
  psql -U barkpark_cloud -d barkpark_cloud_prod <<SQL
begin isolation level repeatable read;
select now() pinned;
select case when inserted_at < '"'"'2026-08-05T21:24:00Z'"'"' then '"'"'BEFORE'"'"' else '"'"'AFTER'"'"' end coh,
 count(*) total,
 count(*) filter (where status='"'"'live'"'"') live,
 count(*) filter (where status='"'"'failed'"'"') failed,
 count(*) filter (where status='"'"'deferred'"'"') deferred,
 count(*) filter (where status='"'"'building'"'"') building
from deployments
where inserted_at >= '"'"'2026-08-05T17:00:00Z'"'"' and inserted_at < '"'"'2026-08-05T23:00:00Z'"'"'
group by 1;
commit;
SQL; uptime'
```

Result: BEFORE 565 / 60 live / 505 failed / 0 deferred / 0 building.
AFTER 144 / 65 / 53 / 26 / 0.

## Per-site split

Same shell, replace the SQL body with a `join sites s on s.id=d.site_id`,
`group by coh, s.slug`.

## Not-attempted (D19) check

```sql
select count(*) from deployments
 where inserted_at >= '2026-08-05T17:00:00Z' and inserted_at < '2026-08-05T23:00:00Z'
   and failure_reason like 'github push builds require%';
```
Result: 0 — D19's exclusion shifts nothing in either window.

## Window-mutation control

Re-run the BEFORE failed count twice, 20 s apart. Both returned 505.
A CLOSED past window does not mutate; the earlier 37→38 drift was an
open-ended `to`. Bound: `max(updated_at - inserted_at)` = 00:18:06.31,
p99 975.9 s — so `to` must sit >= ~19 min behind wall clock.

## Shipped-instrument semantics (read, not run)

```sh
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '140,190p;400,430p'
```
`@min_sample 200`; `rate/2` refuses below it; `volume = total(attempted)` where
`attempted` includes `status: "building"` (classify → nil, and nil is neither
`not_attempted?` nor `deferred?`), and includes deferrals.

## Live route reachability

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
 'https://barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-05T17:00:00Z&to=2026-08-05T21:24:00Z'
```
Result: 401 `{"error":"unauthorized"}` unauthenticated.
