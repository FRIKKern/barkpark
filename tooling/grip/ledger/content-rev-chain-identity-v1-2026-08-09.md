# v1 — content_rev semantics + deferral chain outcome (wave 28 verify)

Re-derivation recipes. Run date 2026-08-09, cloud-db-1 via 178.105.92.191.
Prefix for every SQL row below:

    SQL='...' ; printf "%s\n" "$SQL" | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'

## R1 — what content_rev projects (code)

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '451,556p'

sha256 prefix(12) of `[doc_type, published_count, published_events]` probed FROM THE BOX
at enqueue. Unreadable box degrades to `""` (`@unknown_content_rev`, line 87) and is nonced.

## R2 — all sites share one dataset triple (why one rev lands on 8 sites)

    SELECT id, slug, bootstrap_workspace, bootstrap_project, bootstrap_dataset, doc_type
    FROM sites ORDER BY inserted_at;

12 of 13 = `(default, default, production)`, doc_type post|paper. Identical rev across
same-doc_type sites is BY CONSTRUCTION, not a defect.

## R3 — the key is not monotone (280 recurring pairs)

    WITH d AS (SELECT site_id, content_rev, inserted_at,
                 row_number() OVER (PARTITION BY site_id ORDER BY inserted_at) rn
               FROM deployments WHERE coalesce(content_rev,'')<>''),
    g AS (SELECT site_id, content_rev, rn,
            rn - row_number() OVER (PARTITION BY site_id, content_rev ORDER BY rn) grp FROM d),
    runs AS (SELECT site_id, content_rev, grp FROM g GROUP BY 1,2,3)
    SELECT count(*) FROM (SELECT site_id, content_rev FROM runs GROUP BY 1,2 HAVING count(*)>1) x;

## R4 — rev-keyed outcome (the misleading number)

    WITH lives AS (SELECT DISTINCT site_id, content_rev FROM deployments
                   WHERE status='live' AND coalesce(content_rev,'')<>'')
    SELECT count(*) deferred_rows,
      count(*) FILTER (WHERE coalesce(d.content_rev,'')='') empty_rev,
      count(*) FILTER (WHERE l.site_id IS NOT NULL) same_rev_live_exists,
      count(*) FILTER (WHERE coalesce(d.content_rev,'')<>'' AND l.site_id IS NULL) no_same_rev_live
    FROM deployments d LEFT JOIN lives l ON l.site_id=d.site_id AND l.content_rev=d.content_rev
    WHERE d.status='deferred';

## R5 — TIME-keyed outcome (the honest number)

    WITH d AS (SELECT id, site_id, inserted_at FROM deployments WHERE status='deferred')
    SELECT count(*) deferred_rows,
      count(*) FILTER (WHERE nxt IS NOT NULL) covered,
      count(*) FILTER (WHERE nxt IS NULL) uncovered,
      percentile_disc(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (nxt-d.inserted_at))) p50_s,
      percentile_disc(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (nxt-d.inserted_at))) p95_s,
      max(EXTRACT(EPOCH FROM (nxt-d.inserted_at))) max_s
    FROM d, LATERAL (SELECT min(coalesce(l.became_live_at,l.updated_at)) nxt FROM deployments l
      WHERE l.site_id=d.site_id AND l.status='live' AND l.inserted_at > d.inserted_at) x;

## R6 — the 7 abandonments' fate

    WITH a AS (SELECT id, site_id, inserted_at FROM deployments
               WHERE status='failed' AND failure_reason LIKE '%rebuilds in a row for this site%')
    SELECT a.site_id, a.inserted_at, nxt, EXTRACT(EPOCH FROM (nxt-a.inserted_at))::int lag_s
    FROM a, LATERAL (SELECT min(l.inserted_at) nxt FROM deployments l
      WHERE l.site_id=a.site_id AND l.status='live' AND l.inserted_at > a.inserted_at) x
    ORDER BY a.inserted_at;

## R7 — charter rulings that already settle this

    grep -n "D161\|D162\|D170\|D212\|D213" .claude/workflows/bp-deploy-reliability-charter.md
    sed -n '3140,3180p;3336,3345p;4115,4140p' .claude/workflows/bp-deploy-reliability-charter.md
