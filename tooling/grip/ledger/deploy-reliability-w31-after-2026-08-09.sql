-- deploy-reliability W31 — THE AFTER QUERY, PINNED AS A FILE.
--
-- Run:
--   scp -i ~/.ssh/barkpark_indx tooling/grip/ledger/deploy-reliability-w31-after-2026-08-09.sql root@178.105.92.191:/tmp/after.sql
--   ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
--     'docker cp /tmp/after.sql cloud-db-1:/tmp/after.sql && \
--      docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -f /tmp/after.sql"'
--
-- COHORT CONTRACT (verified against origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex).
--   census/3 failed_rows = attempted rows whose class is non-nil, minus @deferred_classes.
--   classify(%{status: "failed"}) -> classify(stage, reason), which NEVER returns nil
--     (worst case "UNCLASSIFIED") and never returns a @deferred_class.
--   classify(%{status: "deferred"}) -> classify_deferred/2, which returns ONLY
--     @deferred_classes (tail = "DEFERRED_UNCLASSIFIED").
--   => failed_rows == status='failed' MINUS failure_reason LIKE 'github push builds require%'
--      (@not_attempted_classes = ["GITHUB_PUSH_UNBUILDABLE"], 7 rows all-time, 0 in-window).
--   The `NOT LIKE` below is that exact subtraction. Do not drop it.
--
-- deployments.inserted_at is `timestamp without time zone` and stores UTC.
-- @min_sample = 200 (deploy_ledger.ex) — below that a percentage is noise.

\set WSTART '2026-08-09 16:00:00'
\timing off

\echo
\echo ===== SANITY TOTAL (all rows, all time) — a zero here means the query is broken, not the fleet healed =====
SELECT count(*) AS rows_all_time,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       min(inserted_at) AS first_row,
       max(inserted_at) AS last_row
FROM deployments;

\echo
\echo ===== ARM 1 — THE PARTITION, IN ABSOLUTE COUNTS (primary; failure_rate is NOT the primary) =====
\echo -- Rationale: 219 rows moving failed->live and 219 moving failed->deferred both yield
\echo -- 826/5874 = 14.06%. Only the full partition distinguishes a cure from a relocation.
SELECT count(*) AS volume_attempts,
       count(*) FILTER (WHERE status='failed'
                          AND failure_reason NOT LIKE 'github push builds require%') AS failed_census_cohort,
       count(*) FILTER (WHERE status='failed'
                          AND failure_reason LIKE 'github push builds require%')     AS not_attempted_excluded,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status IN ('queued','building','pushing')) AS in_flight,
       count(*) FILTER (WHERE status='cancelled') AS cancelled,
       count(*) FILTER (WHERE status NOT IN ('failed','deferred','live','queued','building','pushing','cancelled')) AS residual_unnamed
FROM deployments WHERE inserted_at >= timestamp :'WSTART';

\echo
\echo ===== ARM 2 — 500-FAMILY OPACITY: distinct RAW failure_reason strings (the number the disclosure must move) =====
\echo -- BEFORE: the box-refusal 500 family collapses to ONE string. Cure lands when the
\echo -- cardinality rises AND the census group-by on raw failure_reason splits the class.
\echo -- The refusal CODE must stay "internal_error" (Sites.Deploy transient_refusal?/1 grace).
-- SUBFAMILIES ARE REPORTED SEPARATELY ON PURPOSE. A raw `count(DISTINCT failure_reason)`
-- over the whole 500 family is a FALSE cure signal: BUILD_FAILED reasons embed the build
-- clock ("[ERROR] 09:44:21 …"), so every such row is already unique and inflates cardinality
-- by one per row without disclosing anything. The honest opacity metric is
-- `top_string_share` — the fraction of the subfamily carried by its single most common
-- string. BEFORE = 1.0000 on the box-refusal subfamily (301/301). A cure drives it DOWN.
SELECT subfamily, count(*) AS n,
       count(DISTINCT failure_reason) AS distinct_raw_reasons,
       round(max(c.n_str)::numeric / count(*), 4) AS top_string_share,
       min(inserted_at) AS first_seen, max(inserted_at) AS last_seen
FROM (
  SELECT d.inserted_at, d.failure_reason,
         CASE WHEN d.failure_reason LIKE 'the instance refused the deploy (HTTP 500)%'
                OR d.failure_reason LIKE 'the instance refused the build poll (HTTP 500)%'
              THEN 'box_refusal_500'
              WHEN d.failure_reason LIKE 'BUILD failed%' THEN 'build_log_graph_500'
              ELSE 'health_gate_graph_500' END AS subfamily,
         count(*) OVER (PARTITION BY d.failure_reason) AS n_str
  FROM deployments d
  WHERE d.status='failed'
    AND d.inserted_at >= timestamp :'WSTART'
    AND (d.failure_reason LIKE 'the instance refused the deploy (HTTP 500)%'
      OR d.failure_reason LIKE 'the instance refused the build poll (HTTP 500)%'
      OR d.failure_reason LIKE '%graph 500: unknown error%')
) c
GROUP BY subfamily ORDER BY 2 DESC;

SELECT failure_reason, count(*) AS n
FROM deployments
WHERE status='failed'
  AND inserted_at >= timestamp :'WSTART'
  AND (failure_reason LIKE 'the instance refused the deploy (HTTP 500)%'
    OR failure_reason LIKE 'the instance refused the build poll (HTTP 500)%'
    OR failure_reason LIKE '%graph 500: unknown error%')
GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

\echo
\echo ===== ARM 3 — DOC_ID_EMPTY (the only class with a pulse): does it disclose its graph code? =====
\echo -- deploy_ledger.ex:471-472 discards the graph code today; 264/265 rows carry one.
SELECT count(*) AS doc_id_empty_rows,
       count(*) FILTER (WHERE failure_reason LIKE '%graph 500%') AS graph_500,
       count(*) FILTER (WHERE failure_reason LIKE '%graph 503%') AS graph_503,
       count(*) FILTER (WHERE failure_reason LIKE '%graph 0%')   AS graph_0,
       count(*) FILTER (WHERE failure_reason NOT LIKE '%graph %') AS no_graph_code,
       count(DISTINCT site_id) AS sites,
       max(inserted_at) AS last_seen
FROM deployments
WHERE status='failed' AND stage='HEALTH'
  AND failure_reason LIKE '%bp-doc-id marker is empty%'
  AND inserted_at >= timestamp :'WSTART';

\echo
\echo ===== VERDICT — INSUFFICIENT VOLUME is a legitimate outcome, not a failure to reach =====
\echo -- Prints one row per arm. verdict=INSUFFICIENT VOLUME whenever n < 200 (@min_sample).
WITH w AS (SELECT * FROM deployments WHERE inserted_at >= timestamp :'WSTART'),
arms(arm, n) AS (
  SELECT 'ARM1 attempts', (SELECT count(*) FROM w)
  UNION ALL SELECT 'ARM1 failed (census cohort)',
    (SELECT count(*) FROM w WHERE status='failed' AND failure_reason NOT LIKE 'github push builds require%')
  UNION ALL SELECT 'ARM2 500-family rows',
    (SELECT count(*) FROM w WHERE status='failed'
       AND (failure_reason LIKE 'the instance refused the deploy (HTTP 500)%'
         OR failure_reason LIKE 'the instance refused the build poll (HTTP 500)%'
         OR failure_reason LIKE '%graph 500: unknown error%'))
  UNION ALL SELECT 'ARM3 DOC_ID_EMPTY rows',
    (SELECT count(*) FROM w WHERE status='failed' AND stage='HEALTH'
       AND failure_reason LIKE '%bp-doc-id marker is empty%')
)
SELECT arm, n, 200 AS min_sample,
       CASE WHEN n >= 200 THEN 'SUFFICIENT' ELSE 'INSUFFICIENT VOLUME' END AS verdict
FROM arms;

\echo
\echo ===== ARRIVAL SHAPE — is the clock honest? (bursty arrivals make a mean-based ETA a fiction) =====
WITH hrs AS (
  SELECT generate_series(date_trunc('hour', now()) - interval '167 hours',
                         date_trunc('hour', now()), interval '1 hour') AS hr
), c AS (
  SELECT hrs.hr, count(d.id) AS n
  FROM hrs LEFT JOIN deployments d ON date_trunc('hour', d.inserted_at) = hrs.hr
  GROUP BY 1
)
SELECT count(*) AS buckets_7d, sum(n) AS attempts_7d, round(avg(n),2) AS mean_per_hr,
       min(n) AS min_hr, max(n) AS max_hr, round(stddev_pop(n),2) AS sd,
       round(stddev_pop(n)/NULLIF(avg(n),0),3) AS cv,
       count(*) FILTER (WHERE n=0) AS zero_hours,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY n) AS p50,
       percentile_disc(0.9) WITHIN GROUP (ORDER BY n) AS p90
FROM c;

\echo
\echo ===== 24H HOURLY HISTOGRAM =====
SELECT date_trunc('hour', inserted_at) AS hr,
       count(*) AS attempts,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred
FROM deployments WHERE inserted_at >= now() - interval '24 hours'
GROUP BY 1 ORDER BY 1;

\echo
\echo ===== ARM 5 — BOTH BASES, SIDE BY SIDE (charter D525/D533: PRIMARY is fr_settled, printed WITH the partition) =====
\echo -- fr_all cannot distinguish a cure from a relocation (219 failed->live and 219 failed->deferred
\echo -- both give 14.06%). fr_settled separates them (30.91% vs 33.67%). Never quote fr_all alone.
\echo -- Set :WSTART above to the FIRST BUILDER MERGE INSTANT of the wave making the claim.
\echo -- Charter D526 (INHERITED CURE): a window crossing 2026-08-06T22:19:52Z may claim nothing.
SELECT count(*)                                        AS volume,
       count(*) FILTER (WHERE status='failed')         AS failed,
       count(*) FILTER (WHERE status='live')           AS live,
       count(*) FILTER (WHERE status='deferred')       AS deferred,
       count(*) FILTER (WHERE status NOT IN ('failed','live','deferred')) AS other,
       round(100.0 * count(*) FILTER (WHERE status='failed')
             / NULLIF(count(*),0), 2)                  AS fr_all,
       round(100.0 * count(*) FILTER (WHERE status='failed')
             / NULLIF(count(*) FILTER (WHERE status IN ('failed','live')),0), 2) AS fr_settled,
       now()                                           AS observed_through
FROM deployments WHERE inserted_at >= timestamp :'WSTART';
