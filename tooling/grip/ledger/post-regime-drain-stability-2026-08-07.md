# Re-derivation recipe — post-D179 deferral drain distribution (deploy-reliability wave 13 verify)

Regime boundary: D179 rollback to `ef77af274` at **2026-08-06 22:19:52Z**. Every query below pins that
instant as its lower bound and excludes rows younger than 1 hour (right-censoring guard).

Host: `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191` → `docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|'`

Always write the SQL to a file and pipe it in; never inline it in the ssh argv (quote-mangling).

## 1. Row-level drain, split by cause (the MUST-RUN)

```sql
with d as (
  select id, site_id, inserted_at,
         case when failure_reason ilike '%box_at_capacity%' then 'box_at_capacity'
              when failure_reason ilike '%already_running%' then 'already_running'
              else 'other' end cause
  from deployments
  where status='deferred' and environment='production'
    and inserted_at >= timestamp '2026-08-06 22:19:00'
    and inserted_at < now() - interval '1 hour'),
j as (select d.*, (select min(l.became_live_at) from deployments l
                   where l.site_id=d.site_id and l.status='live'
                     and l.became_live_at > d.inserted_at) nl from d)
select cause, count(*) n,
  round(percentile_cont(0.5) within group (order by extract(epoch from nl-inserted_at))::numeric,1) p50,
  round(percentile_cont(0.95) within group (order by extract(epoch from nl-inserted_at))::numeric,1) p95,
  round(max(extract(epoch from nl-inserted_at))::numeric,1) max_s,
  count(*) filter (where nl is null or nl-inserted_at > interval '1 hour') no_live_1h
from j group by rollup(1) order by 2 desc;
```

Reading 2026-08-07 10:31Z: `|1110|212.4|949.1|2539.0|0`, box_at_capacity 1109, already_running 1.

## 2. Second key (guards against a `became_live_at` backfill artifact)

Replace `min(l.became_live_at) … l.became_live_at > d.inserted_at` with
`min(l.inserted_at) … l.inserted_at > d.inserted_at`. Reading: `1110|181.9|801.0|2500.9|0` —
same shape, ~15% tighter (live rows are inserted before they go live). Both keys must agree in shape;
divergence in SIGN is the alarm.

## 3. Sanity total (the censored arm must be named, not dropped)

```sql
select count(*) total, count(*) filter (where inserted_at < now()-interval '1 hour') uncensored,
       count(*) filter (where inserted_at >= now()-interval '1 hour') censored_last_hour,
       min(inserted_at), max(inserted_at)
from deployments where status='deferred' and environment='production'
  and inserted_at >= timestamp '2026-08-06 22:19:00';
```

Reading: `1143|1110|33|2026-08-06 22:29:27|2026-08-07 10:31:38`.

## 4. CHAIN units, not ROW units (the instrument-design trap)

Deferrals arrive ~1/minute on the same site and all resolve at the same live instant, so a single 42-minute
wait contributes ~40 rows. Percentile over rows over-weights long waits. Chain heads (gap > 5 min opens a
new chain) measure WAITING PUBLISHES:

```sql
… lag(inserted_at) over (partition by site_id order by inserted_at) prev …
   case when prev is null or inserted_at - prev > interval '5 minutes' then 1 else 0 end is_head
```

Reading: rows n=1110 p95 949.1 vs chain-heads n=139 p95 618.7 — the same fleet, 53% apart. Any published
p95 must name its unit.

## 5. Elapsed-since-regime (do not assume)

```sql
select now(), now() - timestamp with time zone '2026-08-06 22:19:00+00' as elapsed_since_regime;
```

Reading 2026-08-07 10:32Z: `12:13:15`. The regime was NOT 24h old at wave 13's verify.
Re-take after **2026-08-07 22:19Z** for a true 24h window.
