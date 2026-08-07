# Re-derivation recipe — per-site sample floor for PublishClock (deploy-reliability wave 14, V-[per-site-sample-floor])

Measured 2026-08-07 12:29Z against prod cloud-db-1 (`db_now 2026-08-07 12:29:17.928838+00`).
Every row is re-derivable by the command beside it. This recipe SUPERSEDES the sample-count
half of `publish-clock-site-owner-reachability-2026-08-07.md` (measured 10:35Z, n=13–14 per
site, "every site is BELOW min_sample 20") — the population crossed the floor between the two
measurements.

## 0. The one command

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -f -' < /tmp/pubclock_pop.sql
```

`/tmp/pubclock_pop.sql` is reproduced inline below, query by query. Every query carries its own
sanity total (`select count(*) from content_publishes` = 115) so a filtered answer cannot be
mistaken for the population.

## 1. Population of `content_publishes`

```sql
SELECT count(*) total_rows, count(DISTINCT site_id) distinct_site_ids,
       min(received_at) first_row, max(received_at) last_row,
       count(DISTINCT source) distinct_sources
FROM content_publishes;
```

Answer: `115 | 5 | 2026-08-07 08:15:26.02738 | 2026-08-07 12:26:36.741737 | 1`.
Single source `content-webhook`, single doc_type `paper`, 115 rows. The table's ENTIRE
lifetime is 4h11m — every "per day" number below is a 4h11m number and therefore a LOWER
BOUND on a day.

Recorder start (the censor instant, migration row not `min(received_at)`):

```sql
SELECT version, inserted_at FROM schema_migrations WHERE version = 20260807130000;
```

Answer: `20260807130000 | 2026-08-07 08:10:38`.

## 2. Sites carrying a content-webhook secret

```sql
SELECT count(*) total_sites,
       count(content_webhook_secret_encrypted) sites_with_secret,
       count(*) FILTER (WHERE content_webhook_secret_encrypted IS NULL) sites_without_secret
FROM sites;
```

Answer: `13 | 6 | 7`. Six carry a secret; FIVE have ever written a publish row. The odd site is
`auto-proof` (`8fa53cb3-46ce-4067-9f32-ba57184db301`): secret present, 0 publish rows, 0
deployments ever. This re-derives charter D201 exactly, at L1, on live data.

So the "we cannot verify your publish trigger from here" copy is the ONLY branch for **8 of 13
sites** (7 with no secret + `auto-proof`), not 5 — and it is permanent for them, not a youth
censor.

## 3. Per-site per-day sample vs `@min_sample` 20

```sql
WITH j AS (
  SELECT p.site_id, p.received_at, d.id AS deployment_id
  FROM content_publishes p
  LEFT JOIN LATERAL (
    SELECT dd.id FROM deployments dd
    WHERE dd.site_id = p.site_id AND dd.became_live_at IS NOT NULL
      AND dd.became_live_at >= p.received_at AND dd.inserted_at >= p.received_at
    ORDER BY dd.became_live_at LIMIT 1) d ON TRUE)
SELECT site_id, date_trunc('day', received_at) day,
       count(*) deliveries, count(deployment_id) delivered
FROM j GROUP BY 1,2 ORDER BY 4 DESC;
```

Answer (the lateral is `@census_sql` copied verbatim, minus columns): five site-days, all on
2026-08-07, `23|23`, `23|23`, `23|22`, `23|22`, `23|22`. Fleet: 115 deliveries / 112 delivered /
75 distinct deployments credited.

**Every one of the five publishing sites CLEARS `@min_sample` 20 — in 4h11m, not a day.** The
premise "no site can ever clear it" is REFUTED. The refusal branch is not the only branch.

## 4. The window decides, and today sits on the boundary

```sql
SELECT site_id,
       count(*) FILTER (WHERE received_at >= now() - interval '1 hour')  last_1h,
       count(*) FILTER (WHERE received_at >= now() - interval '6 hours') last_6h,
       count(*) AS lifetime
FROM content_publishes GROUP BY 1;
```

Answer: every site `7 | 23 | 23`. A **1h** reader window refuses every site (7 < 20); a 6h/24h
window passes every site at 23 — three above the floor. Hourly fleet volume:
`08h 25 · 09h 20 · 10h 25 · 11h 35 · 12h 10` (steady, not one burst).

## 5. The five samples are NOT independent — one publish stream, 5x fan-out

```sql
WITH b AS (SELECT date_trunc('second', received_at) s, count(*) n,
                  count(DISTINCT site_id) sites FROM content_publishes GROUP BY 1)
SELECT n deliveries_in_same_second, count(*) bursts, max(sites) max_sites FROM b GROUP BY 1;
```

Answer: `2|1|2`, `3|1|3`, `5|22|5` — 22 bursts of exactly five plus one split burst, 24 distinct
seconds, 23 logical publishes. Each site's n=23 is the SAME 23 human publishes. A per-site
denominator is the human publish count, not one-fifth of it; cross-site variance is build speed
only.

## 6. `enqueued` split — the coalesced rows are the point, not a defect

```sql
-- same lateral as §3, grouped by p.enqueued, with percentile_cont(0.5) on the wait
```

Answer: `f | 36 rows | 36 delivered | p50 215.3s | max 1313.5s`;
`t | 79 rows | 76 delivered | p50 246.1s | max 1342.3s`. 79 enqueued rows against 79 live
deploys since the recorder started (`count(*) from deployments where became_live_at >= '2026-08-07
08:10:38'` = 79, over 6 distinct sites). `enqueued=false` means the publish coalesced onto a
rebuild another publish owns (`content_publish.ex:60`) — crediting those 36 to the next live
deploy is the recorder's DESIGNED semantics, and it is 31% of the sample.

## 7. Code level (L3, origin/main 77cf2060c)

```
git show origin/main:cloud/lib/barkpark_cloud/publish_clock.ex | grep -n '@min_sample\|@live_deploys_sql\|@live_sites_sql\|WHERE p.received_at'
git grep -n 'PublishClock' origin/main -- | grep -v '_test.exs\|publish_clock.ex:'
```

Answer: `@min_sample 20` at :145; `@census_sql`'s only WHERE is on `received_at`;
`@live_sites_sql` / `@live_deploys_sql` are fleet-wide (D200's three-constant threading is
still unbuilt). PublishClock still has ZERO production callers — the only non-self, non-test hit
is the charter's own prose.
