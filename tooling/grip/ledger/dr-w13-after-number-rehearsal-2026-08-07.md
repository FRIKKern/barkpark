# Re-derivation recipe — deploy-reliability WAVE 13 after-number

Verifier, deploy-reliability wave 13, 2026-08-07. Every number below is
re-derivable by the command beside it. DB node = `cloud-db-1` on
`178.105.92.191`. DB clock at the run: `2026-08-07 10:42:41 UTC` (so the pinned
window closed 42 min before the query and every row in it is settled).

## 0. The one window, pinned and half-open

**`from 2026-08-06T10:00:00Z <= inserted_at < to 2026-08-07T10:00:00Z`,
`environment = 'production'`.** Never `now() - interval`.

The regime boundary INSIDE it: **2026-08-06T22:24:16Z** (charter D137; D179's
guerrilla reset is 22:19:52Z). Boundary choice is immaterial — it moves 3 failed
and 2 live rows between the halves. No rate crosses it.

## 1. The pinned-window census (all conventions on one line)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"select case when inserted_at < timestamp '2026-08-06 22:24:16' then 'A_pre' else 'B_post' end regime, count(*) volume, count(*) filter (where status='failed') failed, count(*) filter (where status='deferred') deferred, count(*) filter (where status='live') live, round(100.0*count(*) filter (where status='failed')/nullif(count(*) filter (where status in ('failed','live')),0),2) terminal_pct, round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),2) published_pct, round(100.0*count(*) filter (where status in ('failed','deferred'))/nullif(count(*),0),2) old_convention_pct from deployments where inserted_at >= timestamp '2026-08-06 10:00' and inserted_at < timestamp '2026-08-07 10:00' and environment='production' group by 1 order by 1;\""
```

→
```
A_pre |927 |433 failed|277 deferred|217 live|66.62 terminal|46.71 published|76.59 old
B_post|1519| 19 failed|1119 deferred|381 live| 4.75 terminal| 1.25 published|74.92 old
whole |2446|452 failed|1396 deferred|598 live|43.05 terminal|18.48 published|75.55 old
```

Cross-checks that passed: same window on `updated_at` (2451/456/599/1396 — <1%
drift, expected from rows settled just outside); status census returns ONLY
failed/deferred/live (zero queued/building, so nothing is censored by
non-terminality); environment split returns production only (2446, zero preview).

## 2. The drain clock — NAME IT: `deployments.inserted_at` (status='deferred') → `min(became_live_at)` of the next `live` row on the SAME site

Post-regime, UNCENSORED (deferrals cut off at 09:00Z so every row had ≥60 min of
observation before the 10:00Z pin):

```
with d as (select id, site_id, inserted_at from deployments where status='deferred' and environment='production' and inserted_at >= timestamp '2026-08-06 22:19' and inserted_at < timestamp '2026-08-07 09:00')
select count(*) n, count(*) filter (where live_at is null) unserved,
 round(percentile_cont(0.5) within group (order by extract(epoch from (live_at-inserted_at)))) p50_s,
 round(percentile_cont(0.95) within group (order by extract(epoch from (live_at-inserted_at)))) p95_s,
 round(max(extract(epoch from (live_at-inserted_at)))) max_s
from (select d.*, (select min(l.became_live_at) from deployments l where l.site_id=d.site_id and l.status='live' and l.became_live_at > d.inserted_at and l.became_live_at < timestamp '2026-08-07 10:00') live_at from d) t;
```

→ `n=1093 | unserved=0 | p50=213s | p95=954s | max=2539s`

Cross-check by a SECOND clock column (`updated_at` of the live row instead of
`became_live_at`): identical `p50=213 / p95=954`.

## 3. The publish clock (`PublishClock`-shaped) — a DIFFERENT clock, stated as such

`content_publishes.received_at` → `min(became_live_at)` same site. First
`content_publishes` row is `2026-08-07 08:15:26Z` (writer #10187), so this clock
covers 1h45m of the 24h window and NOTHING before it. n=25, unserved=0,
p50=228s, max=942s. Do not blend with §2.

## 4. Abandonment — settled by prose, not by the `deferral_depth` column

```
select count(*) from deployments where failure_reason like '%rebuilds in a row for this site%';   -- 7 all-time
select substring(failure_reason from 'refused ([0-9]+) rebuilds') rounds, count(*) ... group by 1; -- 12→6 rows, 6→1 row
select max(deferral_depth), count(*) filter (where deferral_depth is not null) from deployments;   -- max 4, 23 rows non-null
```

Reconciliation of the wave-12 contradiction: **both surveyors were right about
different columns.** The abandonments live in `failure_reason` prose (7 all-time:
6 on 08-07 01:20:14Z–03:41:33Z across 5 sites at the `@max_consecutive_capacity_deferrals 12`
fence, 1 on 08-05 22:57:53Z at the `@max_consecutive_deferrals 6` fence). The
`deferral_depth` COLUMN is a brand-new writer with 23 non-null rows and max 4 —
it has never recorded an abandonment, because abandoned rows settle `failed` and
the column is written on the deferred arm only.

## 5. The alarm, on the SAME pinned window (not on calendar days)

`deployment_failed` deliveries, `2026-08-06 10:00Z → 2026-08-07 10:00Z`: **456**
(455 sent, 1 failed) against 452 `failed` rows — a 1:1 shadow. Split at the
boundary: 435 pre / 21 post. Zero for the 1,119 post-boundary deferrals.

**The calendar-day series 340/446/625/870/18 must NOT be read as a fall to 18:**
the 08-07 bucket is a PARTIAL day (01:20:14Z → 10:18:00Z at query time), and the
run also samples them ~40 min after the pin, so the last bucket is a different
window class from the four before it.

## 6. The demand denominator — DECLARED UNAVAILABLE for the pinned window

`content_publishes` holds 70 rows total, all `source=content-webhook`,
`doc_type=paper`, 5 sites, first row 08:15:26Z. Amplification is therefore only
computable on `2026-08-07 08:15:26Z → 10:00Z`: **10 distinct publish instants →
45 receipts (4.5 sites fanned per publish) → 95 production deployment attempts =
9.5 attempts per real publish** (31 live, 64 deferred, 0 failed). The 24h figure
does not exist and must not be extrapolated.

## 7. The largest surviving failure class still wears a false label

Pinned-window `failed` rows by reason prefix: `the instance refused the deploy
(HTTP 503): feature_not_configured` = **195 of 452 (43.1%)** — an UP box
answering 503, filed as unavailability. `HEALTH gate ... bp-doc-id marker is
empty` = 164. `box_at_capacity` = 6 (exactly the 6 abandonments).
