# leg2-verdict-basis — re-derivation recipes (2026-08-07)

Host: `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191`
DB:   `docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc "<SQL>"`

## R1 — 14-day daily series (the MUST RUN)

```sql
select date(inserted_at), count(*) att,
 count(*) filter (where status='live') live,
 count(*) filter (where status='deferred') def,
 count(*) filter (where status='failed') fail,
 round(100.0*count(*) filter (where status='live')/count(*),2) absorption,
 round(count(*)::numeric/nullif(count(*) filter (where status='live'),0),2) att_per_live
from deployments where inserted_at > now() - interval '14 days' group by 1 order by 1;
```

## R2 — the taxonomy break (why failure_rate is not continuous)

```sql
select date(inserted_at) d,
 count(*) filter (where failure_reason like '%HTTP 409%') c409,
 count(*) filter (where failure_reason like '%HTTP 500%') c500,
 count(*) filter (where failure_reason like '%HTTP 503%') c503,
 count(*) filter (where failure_reason like 'BUILD%') build,
 count(*) filter (where failure_reason like 'HEALTH%') health,
 count(*) filter (where failure_reason like '%unreachable%') unreach,
 count(*) tot
from deployments where status='failed' and inserted_at > now() - interval '14 days'
group by 1 order by 1;
```
`deferred` rows first appear 2026-08-05; `c409` goes 1379 (07-30) -> 0 (08-06).

## R3 — SETTLED ABSORPTION (the proposed rung quantity)

Per-row 30-minute site lookahead. No episode detector: a plain EXISTS join.
Window MUST end >= 30 min before now or the tail under-absorbs.

```sql
with a as (select id, site_id, inserted_at from deployments
           where inserted_at > now() - interval '7 days'
             and inserted_at < now() - interval '30 minutes'),
     l as (select site_id, became_live_at from deployments
           where status='live' and became_live_at is not null
             and became_live_at > now() - interval '8 days')
select count(*) att,
 round(100.0*count(*) filter (where exists (
   select 1 from l where l.site_id=a.site_id
     and l.became_live_at >= a.inserted_at
     and l.became_live_at <= a.inserted_at + interval '30 minutes'))/count(*),2) settled_absorption
from a;
```
Swap `count(*)` grouping to `date(a.inserted_at)` or `date_trunc('hour',a.inserted_at)` for the series.

## R4 — the masking check (why R3 cannot ship alone)

Fraction of NON-409 ("hard") failures that R3 forgives because a sibling attempt
on the same site went live inside the same 30 minutes.

```sql
with a as (select id, site_id, inserted_at from deployments
           where inserted_at > now() - interval '14 days' and status='failed'
             and (failure_reason is null or failure_reason not like '%HTTP 409%')),
     l as (select site_id, became_live_at from deployments
           where status='live' and became_live_at is not null
             and became_live_at > now() - interval '15 days')
select date(a.inserted_at) d, count(*) hardfail,
 round(100.0*count(*) filter (where exists (
   select 1 from l where l.site_id=a.site_id
     and l.became_live_at >= a.inserted_at
     and l.became_live_at <= a.inserted_at + interval '30 minutes'))/count(*),2) pct_masked
from a group by 1 order by 1;
```

## R5 — the regime boundary (hard-failure rate per hour)

```sql
select date_trunc('hour',inserted_at) h, count(*) att,
 count(*) filter (where status='failed'
   and (failure_reason is null or failure_reason not like '%HTTP 409%')) hardfail,
 round(100.0*count(*) filter (where status='failed'
   and (failure_reason is null or failure_reason not like '%HTTP 409%'))/count(*),2) hardfail_pct
from deployments where inserted_at > now() - interval '30 hours' group by 1 order by 1;
```
Boundary: 2026-08-06 21:00 -> 22:00 UTC, 37.5-50.9%/hr -> 0.00-3.19%/hr.

## R6 — settling-horizon justification (time-to-live percentiles)

```sql
select date(inserted_at) d, count(*) n,
 round(percentile_cont(0.5) within group (order by extract(epoch from (became_live_at-inserted_at))/60)::numeric,2) p50_min,
 round(percentile_cont(0.9) within group (order by extract(epoch from (became_live_at-inserted_at))/60)::numeric,2) p90_min,
 round(percentile_cont(0.99) within group (order by extract(epoch from (became_live_at-inserted_at))/60)::numeric,2) p99_min,
 round(max(extract(epoch from (became_live_at-inserted_at))/60)::numeric,2) max_min
from deployments where status='live' and became_live_at is not null
  and inserted_at > now() - interval '14 days' group by 1 order by 1;
```
14-day max time-to-live = 23.67 min -> 30 min is the smallest safe horizon.

## Code anchors (origin/main, re-read with `git show origin/main:<path>`)

- `cloud/lib/barkpark_cloud/deploy_ledger.ex:179` `@min_sample 200`
- `cloud/lib/barkpark_cloud/deploy_ledger.ex:721-722` `failure_rate` / `live_rate` (= raw absorption) already emitted
- `cloud/lib/barkpark_cloud/deploy_ledger.ex:786` `rate/2` refuses below `@min_sample`
- no `box_rates` and no `deployFailingFence` on main (#10129 never landed)
