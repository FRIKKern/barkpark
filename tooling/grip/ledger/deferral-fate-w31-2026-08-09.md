# Deferral fate — re-derivation recipe (wave 31, deploy-reliability)

**Question:** do `status='deferred'` deployment rows ever SETTLE, or are they terminal?
**Answer:** they settle. 3,217/3,217 in the D516 window reached a later `live`/`failed` row for the
same `site_id`+`environment`. p50 lag 2m28s. Zero orphans in-window.

**Consequence:** the 86.76% → 0.41% collapse is NOT a relabelling. On a denominator that excludes
deferrals entirely (`live+failed` only), the rate still falls 87.19% (08-01) → 1.36% (08-09).
BUT the D516 headline is diluted: 1045/5889 = 17.74% on volume vs 1045/2672 = **39.11% on settled**.

## Host

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191
    docker exec cloud-db-1 sh -lc 'psql -U $POSTGRES_USER -d $POSTGRES_DB -f /tmp/f.sql'

Table is `deployments` (NOT `site_deployments`). The classifier lives at
`cloud/lib/barkpark_cloud/deploy_ledger.ex` — NOT `cloud/lib/barkpark_cloud/sites/deploy_ledger.ex`,
which does not exist on origin/main (`git show origin/main:<path>` → `fatal: path ... does not exist`).

## Arm 2b — settle rate (the deciding query)

```sql
WITH d AS (SELECT * FROM deployments WHERE status='deferred'
  AND inserted_at >= '2026-08-05 21:13:50' AND inserted_at < '2026-08-09 14:30:00')
SELECT coalesce(n.status,'(NONE EVER)') AS settled_successor, count(*) n,
  round(100.0*count(*)/sum(count(*)) OVER (),2) pct
FROM d LEFT JOIN LATERAL (
  SELECT x.status FROM deployments x
  WHERE x.site_id=d.site_id AND x.environment=d.environment
    AND x.inserted_at > d.inserted_at AND x.status IN ('live','failed')
  ORDER BY x.inserted_at LIMIT 1) n ON TRUE
GROUP BY 1 ORDER BY 2 DESC;
-- live 2436 (75.72%) | failed 781 (24.28%) | (NONE EVER) 0
```

## The control that makes it non-vacuous

Site churn means almost every row has *some* successor, so the successor's STATUS is the
discriminator, not its existence:

| cohort (D516 window) | next settled successor = live |
|---|---|
| deferred (n=3217) | **75.72%** |
| failed (n=1045) | 19.33% |
| live (n=1627) | 87.77% |

A deferral's next outcome is live 3.9x more often than a failure's. Deferrals behave like successes.

## Same-logical-publish check

`content_rev` shared with the settled successor: 2044/3217 (63.5%); 1044 differ (superseded by a
newer publish, still settles); 129 either-null. Direct causal support, not just adjacency.

## Two denominators — NEVER merge them

```sql
SELECT count(*) volume, count(*) FILTER (WHERE status='failed') failed,
  round(100.0*count(*) FILTER (WHERE status='failed')/count(*),2) rate_on_volume,
  round(100.0*count(*) FILTER (WHERE status='failed')
        /count(*) FILTER (WHERE status IN ('live','failed')),2) rate_on_settled
FROM deployments WHERE inserted_at >= '2026-08-05 21:13:50' AND inserted_at < '2026-08-09 14:30:00';
-- 5889 | 1045 | 17.74 | 39.11
```

Unscoped SQL gives volume 5,889; the team-scoped census gives 5,874. Same numerator (1,045).
Any BEFORE must name its scope AND its denominator basis.

## Arm C corollary (BOX_BUSY_DEFERRED is dead; its PRODUCER is not)

```sql
SELECT CASE WHEN failure_reason LIKE '%already_running%' THEN 'BOX_BUSY_DEFERRED'
            WHEN failure_reason LIKE '%box_at_capacity%' THEN 'BOX_AT_CAPACITY_DEFERRED' END fam,
       count(*), min(inserted_at), max(inserted_at)
FROM deployments WHERE status='deferred' GROUP BY 1;
-- BOX_AT_CAPACITY_DEFERRED  2571  2026-08-06 22:29:27  2026-08-09 16:09:42  <- firing NOW
-- BOX_BUSY_DEFERRED          698  2026-08-05 21:27:11  2026-08-07 08:16:29  <- silent
```

Same writer, same `PLAN` stage, same HTTP-409 shape. The deferral producer fired four seconds before
this query ran. So the `already_running` silence is a CHANGED REFUSAL SHAPE on the box, not a broken
producer — "fixed problem vs broken producer" resolves to neither: the class was *superseded*.
