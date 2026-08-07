# Re-derivation recipe — AMPLIFIED vs UNIQUE deploy denominator (2026-08-07, wave 14 verify)

Pinned window (D209's, verbatim): `inserted_at >= '2026-08-06 10:00:00' AND inserted_at < '2026-08-07 10:00:00'`,
`environment='production'`. Regime boundary (D179): `2026-08-06 22:19:52`.

Host: `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191` → `docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -f -`

## R1 — the dataset half of the proposed key is a CONSTANT (the survey's key is wrong)

```sql
SELECT count(DISTINCT s.bootstrap_dataset) AS distinct_datasets, count(DISTINCT s.team_id) AS teams
FROM deployments d JOIN sites s ON s.id=d.site_id
WHERE d.inserted_at >= '2026-08-06 10:00:00' AND d.inserted_at < '2026-08-07 10:00:00'
  AND d.environment='production';
-- => distinct_datasets 1, teams 1
SELECT bootstrap_dataset, count(*) FROM sites GROUP BY 1;   -- => production 12, NULL 1
```

## R2 — the three denominators, one window

```sql
WITH w AS (SELECT * FROM deployments
  WHERE inserted_at >= '2026-08-06 10:00:00' AND inserted_at < '2026-08-07 10:00:00'
    AND environment='production'),
wr AS (SELECT * FROM w WHERE content_rev IS NOT NULL),
chains AS (SELECT site_id, content_rev, bool_or(status='live') live, bool_or(status='failed') failed FROM wr GROUP BY 1,2),
revs AS (SELECT content_rev, bool_or(status='live') live, bool_or(status='failed') failed FROM wr GROUP BY 1)
SELECT 'ATTEMPT' u, (SELECT count(*) FROM w), (SELECT count(*) FROM w WHERE status='failed')
UNION ALL SELECT 'CHAIN', (SELECT count(*) FROM chains), (SELECT count(*) FROM chains WHERE NOT live AND failed)
UNION ALL SELECT 'PUBLISH', (SELECT count(*) FROM revs), (SELECT count(*) FROM revs WHERE NOT live AND failed);
-- => ATTEMPT 2446/452 (18.48%) · CHAIN 653/125 (19.14%) · PUBLISH 163/16 (9.82%)
```

## R3 — amplification decomposition (two independent quotients, product must equal the total)

2378 rows-with-rev / 653 chains = **3.64x retry**; 653 chains / 163 revs = **4.01x fan-out**;
2378 / 163 = **14.59x total**. 3.64 x 4.01 = 14.60 — closes.

## R4 — fan-out cross-check by a SECOND, independent method

```sql
SELECT count(DISTINCT site_id) FROM content_publishes;   -- => 5 sites ever fire a content publish
```
Matches the observed modal 5-6 distinct sites per `content_rev` in R2's window. The `sites` table's
"12 bound to dataset=production" OVERSTATES: only 7 sites deployed at all in the window, only 5 auto-publish.

## R5 — the partition does NOT separate populations (the decisive negative)

```sql
-- row_number() over (partition by content_rev) = 1 => UNIQUE; else FANOUT/RETRY sibling
-- AFTER regime: UNIQUE 2.20% fail (n=91) · FANOUT sibling 0.00% (n=318) · RETRY sibling 1.80% (n=1112)
-- BEFORE regime: UNIQUE 61.11% (n=72) · FANOUT 51.74% (n=172) · RETRY 40.46% (n=613)
```

## R6 — the blocking constraint: @min_sample 200 vs the unique denominator

`cloud/lib/barkpark_cloud/deploy_ledger.ex:173` `@min_sample 200`; `rate/2:639` refuses below it.
Unique-publish denominator by window width ending 2026-08-07T10:00Z:
1h 5 · 6h 43 · **24h 163 (REFUSES)** · 72h 386 · 168h 647. A partitioned 24h rate cannot publish.

## R7 — traps a builder will hit

- `deferral_cause` / `deferral_depth` are set on **116 rows all-time, all after 2026-08-07 10:12:35Z**.
  A reader keyed on them over any historical window returns ZERO. The real signal is `status='deferred'`
  (1,934 rows all-time; 1,396 in the pinned window).
- 68 of 2,446 window rows (2.78%) have `content_rev IS NULL` — **49 of them failed**, i.e. 10.8% of all
  failed rows are UNPARTITIONABLE and silently leave any dedup numerator.
- `merge_deploy_rate/2` does not exist on origin/main (`git grep -n deploy_rate origin/main` returns only
  charter prose, 2 hits). The whole arm is unmerged (#10129).
