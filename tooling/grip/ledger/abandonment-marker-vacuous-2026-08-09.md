# The abandonment marker reads a truthful-looking zero — re-derivation recipe (2026-08-09)

Live control plane: `cloud-db-1` on `178.105.92.191`, table `public.deployments`
(NOT `site_deploy_ledger` — that name does not exist; the ledger is a *module*,
`cloud/lib/barkpark_cloud/deploy_ledger.ex`, over the `deployments` table).

Sanity total first, so nothing below is a vacuous zero.

```bash
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' <<'SQL'
-- A. sanity total
SELECT count(*) AS rows_total, min(inserted_at), max(inserted_at),
  count(*) FILTER (WHERE status='failed')   AS failed,
  count(*) FILTER (WHERE status='live')     AS live,
  count(*) FILTER (WHERE status='deferred') AS deferred
FROM deployments;

-- (a) PROSE scan: the abandonment sentence (Sites.Deploy.abandonment_reason/3)
SELECT count(*), min(inserted_at), max(inserted_at)
FROM deployments WHERE failure_reason LIKE '%rebuilds in a row for this site%';

-- (b) STRUCTURED predicate an exit gauge would naively use
SELECT count(*) FROM deployments WHERE deferral_depth = deferral_bound;

-- (c) first stamped marker row
SELECT min(inserted_at) FROM deployments WHERE deferral_cause IS NOT NULL;

-- (d) backfill dry-run: depth/bound/cause derived from the prose alone
SELECT id,
  (regexp_match(failure_reason,'refused ([0-9]+) rebuilds in a row'))[1]::int AS depth,
  CASE WHEN failure_reason LIKE '%concurrent-build cap for that entire run%' THEN 12
       WHEN failure_reason LIKE '%not busy but stuck%'                       THEN 6  END AS bound,
  CASE WHEN failure_reason LIKE '%concurrent-build cap for that entire run%' THEN 'BOX_AT_CAPACITY_DEFERRED'
       WHEN failure_reason LIKE '%not busy but stuck%'                       THEN 'BOX_BUSY_DEFERRED' END AS cause
FROM deployments WHERE failure_reason LIKE '%rebuilds in a row for this site%' ORDER BY inserted_at;

-- (e) did each abandoned publish chain (site_id, content_rev) ever reach live?
WITH ab AS (SELECT id, site_id, content_rev, inserted_at FROM deployments
            WHERE failure_reason LIKE '%rebuilds in a row for this site%')
SELECT ab.id, ab.site_id, ab.content_rev,
  (SELECT count(*) FROM deployments d
     WHERE d.site_id=ab.site_id AND d.content_rev=ab.content_rev AND d.status='live') AS same_rev_live
FROM ab ORDER BY ab.inserted_at;
SQL
```

Readings taken 2026-08-09 ~18:0xZ (corpus 32,953 rows, 2026-07-14 11:28:18 → 2026-08-09 18:01:41;
failed 18,652 / live 10,973 / deferred 3,327):

| probe | reading |
|---|---|
| (a) prose scan | **7**, first 2026-08-05 22:57:53.830161, last **2026-08-07 03:41:33.865677** |
| (b) `deferral_depth = deferral_bound` | **0** corpus-wide |
| (c) first stamped marker | **2026-08-07 10:12:35.033826** (depth, bound and cause all first-stamped at the same instant) |
| gap | last abandonment → first marker = **06:31:01** — every abandonment predates its own marker |
| stamped rows | 1,509 — **all `status='deferred'`**; max depth 9, bound always 12; no `failed` row carries a column |
| (d) derivable from prose | **7 of 7**, 0 underivable |
| (e) never reached live at same `(site_id, content_rev)` | **2 of 7** — `search`/`947c0dbd0de8`, `search-ember`/`91284be29666`; still non-live 2026-08-09 |

Why (b) is 0 even on healthy data: the abandonment arm fires at `prior >= bound - 1`, so the
bound-th round is written `failed`, and `fail/2` historically wrote no columns. The highest depth a
`deferred` row can carry is bound−1. So `depth = bound` is unsatisfiable for the pre-#11209 corpus and
was never the abandonment predicate.

What the CLI actually does today (and must keep doing): `internal/cli/cloud_site_cmd.go:907`
`siteDeployAbandoned` is a **class prefix** predicate (`ABANDONED_*`) whose class is derived from the
prose regex `deploy_ledger.ex:740`; depth is column-first / prose-fallback at `:958`. That reader is
NOT vacuous. The vacuous reader is `siteAbandonmentBound` (`:996`, column-only) — dead on all 7 —
and any future switch to a `deferral_cause IS NOT NULL` predicate (open task
`dr-w28-rv-abandonment-predicate-replaces-the-prose-regex`), which would silently drop all 7.
