\echo === A. LIFETIME (all rows, all time) ===
SELECT count(*) AS volume,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2)   AS live_per_row_pct,
       round(100.0*count(*) FILTER (WHERE status='failed')/count(*),2) AS failed_per_row_pct,
       round(100.0*count(*) FILTER (WHERE status='live')/NULLIF(count(*) FILTER (WHERE status<>'deferred'),0),2) AS live_per_nondeferred_pct
FROM deployments;

\echo === B. LAST 7 DAYS ===
SELECT count(*) AS volume,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2) AS live_per_row_pct,
       round(100.0*count(*) FILTER (WHERE status='live')/NULLIF(count(*) FILTER (WHERE status<>'deferred'),0),2) AS live_per_nondeferred_pct
FROM deployments WHERE inserted_at >= now() - interval '7 days';

\echo === C. PRE-DOOR vs POST-DOOR (door = 2026-08-06 22:29:27) ===
SELECT CASE WHEN inserted_at < timestamp '2026-08-06 22:29:27' THEN 'pre_door' ELSE 'post_door' END AS era,
       count(*) AS volume,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2) AS live_per_row_pct,
       round(100.0*count(*) FILTER (WHERE status='live')/NULLIF(count(*) FILTER (WHERE status<>'deferred'),0),2) AS live_per_nondeferred_pct
FROM deployments GROUP BY 1 ORDER BY 1 DESC;

\echo === D. FAILURE NUMERATOR FROZEN? last failed row overall ===
SELECT max(inserted_at) AS last_failed_inserted, max(updated_at) AS last_failed_updated,
       count(*) AS failed_total
FROM deployments WHERE status='failed';

\echo === E. PER-DAY STATUS SERIES (last 14 days) ===
SELECT date_trunc('day', inserted_at)::date AS day,
       count(*) AS volume,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2) AS live_per_row_pct
FROM deployments
WHERE inserted_at >= now() - interval '14 days'
GROUP BY 1 ORDER BY 1;

\echo === F. DEFERRAL CAUSE COVERAGE among deferred rows ===
SELECT coalesce(deferral_cause,'(null)') AS cause, count(*),
       min(inserted_at) AS first_seen, max(inserted_at) AS last_seen
FROM deployments WHERE status='deferred' GROUP BY 1 ORDER BY 2 DESC;

\echo === G. POST-DOOR ONLY, per-day, with deferral share ===
SELECT date_trunc('day', inserted_at)::date AS day,
       count(*) AS volume,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0*count(*) FILTER (WHERE status='deferred')/count(*),2) AS deferred_share_pct
FROM deployments WHERE inserted_at >= timestamp '2026-08-06 22:29:27'
GROUP BY 1 ORDER BY 1;

\echo === H. coalesced_attempts population ===
SELECT count(*) AS rows_total,
       count(*) FILTER (WHERE coalesced_attempts > 0) AS rows_with_coalescing,
       coalesce(sum(coalesced_attempts),0) AS sum_coalesced
FROM deployments;
