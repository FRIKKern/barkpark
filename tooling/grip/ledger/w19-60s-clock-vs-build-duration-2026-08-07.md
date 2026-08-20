# W19 verify: the 60s re-fire clock vs build duration, and the 409-vs-coalesce split

Re-derivation recipes for deploy-reliability wave 19, assignment v3-clock-mismatch.
Every window is pinned AFTER `2026-08-05 21:27:11` (the `status='deferred'` taxonomy break).
All timestamps are `timestamp without time zone`, UTC. Measured 2026-08-07 ~22:05–22:20Z.

## The one command shape (never inline awk; always a file)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -P pager=off'" \
  < /path/to/query.sql
```

Query files used, in order:
`w19v3.sql` (census + duration + gaps), `w19v3b.sql` (leak test + oban cross-check),
`w19v3c.sql` (chains + hourly), `w19v3d.sql` (daily duration + oracle sizing), `w19v3e.sql`
(the honest co-existence window). They live in the run's scratchpad; the SQL below is the
load-bearing subset, verbatim.

## 1. The metronome — a site's consecutive deferrals are 60s apart

```sql
with d as (
  select site_id, inserted_at,
         lag(inserted_at) over (partition by site_id order by inserted_at) as prev_defer
  from deployments
  where status='deferred' and inserted_at >= timestamp '2026-08-05 21:27:11'
)
select count(*) as n_pairs,
       percentile_cont(0.5) within group (order by extract(epoch from (inserted_at - prev_defer))) as p50_s,
       count(*) filter (where extract(epoch from (inserted_at - prev_defer)) between 55 and 75) as in_60_75_band,
       count(*) filter (where extract(epoch from (inserted_at - prev_defer)) < 55) as under_55
from d where prev_defer is not null;
```

Measured: `2262 | 61.607346 | 1441 | 4`. `@schedule_in_default 60`
(`cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex:110`) is the clock.

## 2. Build duration — regime-dependent, NOT a constant

```sql
select date_trunc('day', inserted_at) as day, count(*) n,
  round(percentile_cont(0.5) within group (order by extract(epoch from (became_live_at-inserted_at)))::numeric,1) as p50_s,
  round(100.0*count(*) filter (where extract(epoch from (became_live_at-inserted_at))>60)/count(*),1) as pct_over_60
from deployments
where status='live' and became_live_at is not null and inserted_at >= timestamp '2026-08-05 21:27:11'
group by 1 order by 1;
```

Measured: 08-05 `93.6 | 69.2`, 08-06 `135.7 | 82.5`, 08-07 `33.6 | 25.3`.
Window-wide p50 is 64.0s — quoting that alone hides that TODAY the median build is half the debounce.

## 3. The split — start-stage 409 vs CP-side coalesce

The `coalesced_attempts` counter did not exist before migration `20260807150000`, applied
`2026-08-07 10:02:23` (`select version, inserted_at from schema_migrations order by version desc`).
Any ratio quoted over a window that starts earlier is comparing an instrument against nothing.
The only honest window is `>= 2026-08-07 10:02:23`:

```sql
select
 (select count(*) from deployments where status='deferred' and inserted_at >= timestamp '2026-08-07 10:02:23') as start_stage_409_rows,
 (select coalesce(sum(coalesced_attempts),0) from deployments where coalesced_last_at >= timestamp '2026-08-07 10:02:23') as cp_side_coalesces;
```

Measured: `450 | 6` — 75:1.

## 4. Second way (box side) — the box's own 409s

Guerrilla's unit is `barkpark-slot@green.service` / `barkpark-slot@blue.service`.
There is **no** `barkpark.service` on guerrilla — grepping it returns 0 and looks like a
real zero. Both slots must be counted; green's journal has whole missing hours that blue covers.

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  "journalctl -u barkpark-slot@green.service --since '2026-08-07 10:02:23' --no-pager | grep -c 'Sent 409'; \
   journalctl -u barkpark-slot@blue.service  --since '2026-08-07 10:02:23' --no-pager | grep -c 'Sent 409'"
```

Measured: `273` + `275` = 548 (an upper bound: includes non-deploy 409s) against 450 CP
deferral rows. The box's first 409 at `10:12:35.093` matches the first `deferral_cause`-bearing
row at `10:12:35.033826` — the two instruments are looking at the same event.
The strings `box_at_capacity` / `already_running` do NOT appear in the box journal; only
`Sent 409` does.

## 5. Oracle-collapse sizing

```sql
with e as (
  select site_id, inserted_at, status,
         sum(case when status<>'deferred' then 1 else 0 end)
           over (partition by site_id order by inserted_at rows between unbounded preceding and current row) as grp
  from deployments where inserted_at >= timestamp '2026-08-05 21:27:11'
),
chains as (select site_id, grp, count(*) filter (where status='deferred') as l
           from e group by 1,2 having count(*) filter (where status='deferred')>0)
select sum(l) as deferrals, count(*) as chains, sum(l)-count(*) as removable_rows,
       round(100.0*(sum(l)-count(*))/sum(l),1) as pct_removable from chains;
```

Measured: `2268 | 807 | 1461 | 64.4`.

## Traps this run hit — do not repeat

- **A broken chain-span query returns a plausible number.** Grouping by the same `grp` and
  taking `min(inserted_at) .. max(became_live_at)` measures the settled row's OWN build
  duration, not the chain span, because `grp` increments ON the settled row. It returned
  `p50 34.1s` — indistinguishable from a real answer. Do not quote a chain span without
  anchoring the group's first DEFERRAL, not its settled row.
- **`oban_jobs` minus `deployments` is not an estimator of attempts-that-minted-no-row.**
  Over `>= 2026-08-07 10:02:23` it is `651 - 658 = -7`. It was the basis of the W12
  migration's "4.35:1" claim. Rows arrive from other triggers and jobs cross the boundary.
- **`grep -c` on a wrong unit name returns 0 and reads as evidence of absence.** Always
  print the log's line count and its first timestamp beside any count taken from it.
- Numbers drift between rounds because the fleet is live: total rows read 4426 → 4429,
  deferrals 2267 → 2268, live 1153 → 1156 across ~15 minutes. Pin the read time when quoting.
