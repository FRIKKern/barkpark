-- deploy-reliability W32 — THE CLASS CLASSIFIER, PINNED AS A FILE.
--
-- WHY THIS FILE EXISTS. Every wave of this epic has re-derived "which class is
-- failing" by hand, with a different ad-hoc LIKE each time, and got a different
-- answer. `deploy_ledger.ex classify/2` is the ONE classifier; this file is its
-- faithful SQL transliteration, arm for arm, in the SAME cond order. When the
-- two disagree, the Elixir is right and this file is the bug.
--
-- Run:
--   cd /Volumes/SATECHI/github/barkpark && \
--   ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
--     'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' \
--     < tooling/grip/ledger/deploy-reliability-w32-classes-2026-08-09.sql
--
-- COHORT CONTRACT (verified against origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex,
-- lines 553-565 classify/1, 574-629 classify/2, 796-830 classify_deferred/2).
--   census/3 failed_rows = attempted rows whose class is non-nil, minus @deferred_classes.
--   classify(%{status: "failed"})   -> classify(stage, reason); never nil, tail "UNCLASSIFIED".
--   classify(%{status: "deferred"}) -> classify_deferred/2; ONLY @deferred_classes.
--   classify(%{status: _other})     -> nil (live/queued/building/... are not classified).
--   => failed_rows == status='failed' MINUS @not_attempted_classes
--      (= ["GITHUB_PUSH_UNBUILDABLE"], i.e. failure_reason LIKE 'github push builds require%').
--   The classifier below reproduces that subtraction BY NAME, not by a NOT LIKE.
--
-- deployments.inserted_at is `timestamp without time zone` and stores UTC.
-- @min_sample = 200 (deploy_ledger.ex) — below that a percentage is noise.
--
-- BOTH BASES ARE PRINTED, ALWAYS (charter D525/D533):
--   fr_all     = failed / volume                      (cannot tell a cure from a relocation)
--   fr_settled = failed / (failed+live)               (the PRIMARY)
-- Never quote fr_all alone. Every rate printed here carries its window inline.

\timing off
\pset pager off

\echo
\echo ===== SANITY TOTAL (all rows, all time) — a zero here means the query is broken, not the fleet healed =====
SELECT count(*) AS rows_all_time,
       count(*) FILTER (WHERE status='failed')   AS failed,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       min(inserted_at) AS first_row,
       max(inserted_at) AS last_row,
       now() AS observed_at
FROM deployments;

-- ── THE CLASSIFIER ──────────────────────────────────────────────────────────
-- One view, used by every arm below. Do not inline a LIKE anywhere else.
CREATE TEMP VIEW dep_classified AS
WITH base AS (
  SELECT d.id, d.site_id, d.status, d.stage, d.failure_reason AS r, d.inserted_at,
         -- refusal_code/1  <- @refusal ~r/^the instance refused the (?:deploy|build poll) \((?:HTTP )?(\d{3})\)/
         (regexp_match(d.failure_reason,
            '^the instance refused the (?:deploy|build poll) \((?:HTTP )?(\d{3})\)'))[1] AS refusal_code,
         -- refusal_phase/1 (reported, never folded into the class — D218)
         CASE WHEN d.failure_reason ~ '^the instance refused the deploy \((?:HTTP )?\d{3}\)' THEN 'start'
              WHEN d.failure_reason ~ '^the instance refused the build poll \((?:HTTP )?\d{3}\)' THEN 'poll'
              ELSE NULL END AS refusal_phase,
         -- abandoned?/1  <- @abandoned
         (d.failure_reason ~ ' — and it has now refused \d+ rebuilds in a row for this site,') AS abandoned,
         -- deferral_code/1: @deferral_prefix capture, minus @request_id_stamp, first ' — ' segment
         split_part(
           regexp_replace(
             coalesce((regexp_match(d.failure_reason,
               '^the instance refused the (?:deploy|build poll) \((?:HTTP )?\d{3}\):\s*(.+)$'))[1], ''),
             '\s*\[box request_id: [^\]]*\]', '', 'g'),
           ' — ', 1) AS defer_seg,
         (d.failure_reason ~ '^the instance refused the (?:deploy|build poll) \((?:HTTP )?\d{3}\):\s*.') AS has_defer_detail,
         -- graph_code/2, both dialects (D238)
         (regexp_match(d.failure_reason, 'could not read a content document: graph (\d+):'))[1] AS health_graph,
         (regexp_match(d.failure_reason, '\yError: graph (\d+):'))[1] AS build_graph,
         -- build_failure?/1
         (d.failure_reason LIKE 'BUILD failed (exit%' OR d.failure_reason LIKE 'BUILD failed — %') AS build_failed,
         -- @corpus_403
         (d.failure_reason ~ 'fetch failed:\s*403\y') AS corpus_403
  FROM deployments d
), coded AS (
  SELECT base.*,
         -- code_or_prose/1: :none when no detail captured, {:code,_} when @code_token, else :prose
         CASE WHEN NOT has_defer_detail THEN 'none'
              WHEN defer_seg ~ '^[a-z][a-z0-9_]*$' THEN defer_seg
              ELSE 'prose' END AS defer_code,
         CASE WHEN stage='HEALTH' THEN health_graph
              WHEN stage='BUILD' AND build_failed THEN build_graph
              ELSE NULL END AS graph_code
  FROM base
)
SELECT id, site_id, status, stage, r, inserted_at, refusal_code, refusal_phase, defer_code,
  CASE
    WHEN status = 'deferred' THEN
      CASE
        WHEN r IS NULL THEN 'DEFERRED_UNCLASSIFIED'
        WHEN position('could NOT be re-queued' in r) > 0 THEN 'DEFERRED_UNCLASSIFIED'
        WHEN refusal_code IS DISTINCT FROM '409' THEN 'DEFERRED_UNCLASSIFIED'
        WHEN defer_code = 'box_at_capacity' THEN 'BOX_AT_CAPACITY_DEFERRED'
        WHEN defer_code IN ('none','already_running') THEN 'BOX_BUSY_DEFERRED'
        ELSE 'DEFERRED_UNCLASSIFIED'
      END
    WHEN status <> 'failed' THEN NULL          -- classify(%{status: _other}) -> nil
    WHEN r IS NULL THEN 'UNCLASSIFIED'
    WHEN r LIKE 'github push builds require%' THEN 'GITHUB_PUSH_UNBUILDABLE'
    WHEN refusal_code = '409' THEN
      CASE WHEN NOT abandoned THEN 'BOX_BUSY_409'
           WHEN defer_code = 'box_at_capacity' THEN 'ABANDONED_AT_CAPACITY'
           WHEN defer_code IN ('none','already_running') THEN 'ABANDONED_BOX_STUCK'
           ELSE 'ABANDONED_UNCLASSIFIED' END
    WHEN refusal_code = '503' THEN
      CASE WHEN defer_code = 'feature_not_configured' THEN 'BOX_DEPLOY_DISABLED_503'
           WHEN defer_code = 'deploy_runner_unavailable' THEN 'BOX_RUNNER_UNAVAILABLE_503'
           ELSE 'BOX_UNAVAILABLE_503' END
    WHEN refusal_code = '500' THEN 'BOX_500'
    WHEN refusal_code = '429' THEN 'BOX_RATE_LIMITED_429'
    WHEN refusal_code IS NOT NULL THEN 'UNCLASSIFIED'
    WHEN graph_code = '500' THEN 'CONTENT_API_500'
    WHEN graph_code = '503' THEN 'CONTENT_API_503'
    WHEN graph_code = '0'   THEN 'CONTENT_API_UNREACHABLE'
    WHEN graph_code = '403' THEN 'CONTENT_API_403'
    WHEN graph_code IS NOT NULL THEN 'UNCLASSIFIED'
    WHEN stage='HEALTH' AND position('bp-doc-id marker is empty' in r) > 0 THEN 'DOC_ID_EMPTY'
    WHEN stage='HEALTH' AND (r LIKE 'HEALTH gate failed%' OR r LIKE 'HEALTH failed%') THEN 'HEALTH_GATE_FAILED'
    WHEN stage='BUILD' AND build_failed THEN (CASE WHEN corpus_403 THEN 'FORBIDDEN_403' ELSE 'BUILD_FAILED' END)
    WHEN r LIKE 'missing site source dir%' OR r LIKE 'artifact: artifact_url is empty%'
         OR position('fetch failed' in r) > 0 THEN 'SOURCE_UNFETCHABLE'
    WHEN position('is unreachable' in r) > 0 THEN 'BOX_UNREACHABLE'
    WHEN r LIKE 'the build did not finish in time%' THEN 'DEPLOY_TIMEOUT'
    WHEN r LIKE 'exceeded max deploy claim attempts%' THEN 'STALE_LEASE'
    WHEN r LIKE 'deploy process died abnormally%' THEN 'PROCESS_DIED'
    ELSE 'UNCLASSIFIED'
  END AS class
FROM coded;

\echo
\echo ===== CLASSIFIER SELF-CHECK — every failed/deferred row gets a class, nothing else does =====
\echo -- A non-zero unclassified_status_row, or a failed row with a NULL class, means this
\echo -- file has drifted from classify/1 and every number below is void.
SELECT count(*) FILTER (WHERE status IN ('failed','deferred') AND class IS NULL)  AS settled_rows_with_null_class,
       count(*) FILTER (WHERE status NOT IN ('failed','deferred') AND class IS NOT NULL) AS nonsettled_rows_with_class,
       count(*) FILTER (WHERE status='deferred' AND class NOT IN
             ('BOX_BUSY_DEFERRED','BOX_AT_CAPACITY_DEFERRED','DEFERRED_UNCLASSIFIED')) AS deferred_leaked_a_failure_class,
       count(*) FILTER (WHERE status='failed' AND class IN
             ('BOX_BUSY_DEFERRED','BOX_AT_CAPACITY_DEFERRED','DEFERRED_UNCLASSIFIED')) AS failed_leaked_a_deferred_class
FROM dep_classified;

\echo
\echo ===== ARM A — 24H PARTITION, BOTH BASES, WITH ABSOLUTE COUNTS =====
SELECT '24h' AS window,
       count(*) AS volume,
       count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE') AS failed_census_cohort,
       count(*) FILTER (WHERE class = 'GITHUB_PUSH_UNBUILDABLE') AS not_attempted_excluded,
       count(*) FILTER (WHERE status='live')     AS live,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       count(*) FILTER (WHERE status NOT IN ('failed','live','deferred')) AS other,
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*),0), 2) AS fr_all,
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*) FILTER (WHERE status IN ('failed','live')),0), 2) AS fr_settled
FROM dep_classified WHERE inserted_at >= now() - interval '24 hours'
UNION ALL
SELECT '7d',
       count(*),
       count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE'),
       count(*) FILTER (WHERE class = 'GITHUB_PUSH_UNBUILDABLE'),
       count(*) FILTER (WHERE status='live'),
       count(*) FILTER (WHERE status='deferred'),
       count(*) FILTER (WHERE status NOT IN ('failed','live','deferred')),
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*),0), 2),
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*) FILTER (WHERE status IN ('failed','live')),0), 2)
FROM dep_classified WHERE inserted_at >= now() - interval '7 days';

\echo
\echo ===== ARM B — CLASS BREAKDOWN, 24H AND 7D (the number every wave re-derived by hand) =====
SELECT class,
       count(*) FILTER (WHERE inserted_at >= now() - interval '24 hours') AS n_24h,
       count(*) FILTER (WHERE inserted_at >= now() - interval '7 days')   AS n_7d,
       count(*) AS n_all_time,
       count(DISTINCT site_id) FILTER (WHERE inserted_at >= now() - interval '7 days') AS sites_7d,
       max(inserted_at) AS last_seen
FROM dep_classified WHERE class IS NOT NULL
GROUP BY class ORDER BY n_7d DESC, n_all_time DESC;

\echo
\echo ===== ARM C — THE BURST QUESTION: BOX_UNREACHABLE HOURLY, 48H =====
\echo -- INCIDENT  = a contiguous run of hours that returns to zero and STAYS zero. Alarm target.
\echo -- DEFECT    = rows keep arriving in the most recent settled hours. Cure target.
\echo -- Read the LAST few rows, not the max.
WITH hrs AS (
  SELECT generate_series(date_trunc('hour', now()) - interval '47 hours',
                         date_trunc('hour', now()), interval '1 hour') AS hr
)
SELECT hrs.hr,
       count(c.id) FILTER (WHERE c.class='BOX_UNREACHABLE')            AS box_unreachable,
       count(DISTINCT c.site_id) FILTER (WHERE c.class='BOX_UNREACHABLE') AS sites,
       count(c.id)                                                     AS attempts,
       count(c.id) FILTER (WHERE c.status='live')                      AS live,
       count(c.id) FILTER (WHERE c.status='failed')                    AS failed,
       count(c.id) FILTER (WHERE c.status='deferred')                  AS deferred
FROM hrs LEFT JOIN dep_classified c ON date_trunc('hour', c.inserted_at) = hrs.hr
GROUP BY 1 ORDER BY 1;

\echo
\echo ===== ARM D — BOX_UNREACHABLE FORENSICS: shape, span, sites, raw strings =====
SELECT count(*) AS rows_all_time,
       count(*) FILTER (WHERE inserted_at >= now() - interval '24 hours') AS n_24h,
       count(*) FILTER (WHERE inserted_at >= now() - interval '1 hour')   AS n_1h,
       count(DISTINCT site_id) AS sites_all_time,
       min(inserted_at) AS first_seen, max(inserted_at) AS last_seen,
       round(EXTRACT(EPOCH FROM (now() - max(inserted_at)))/60.0, 1) AS minutes_since_last
FROM dep_classified WHERE class='BOX_UNREACHABLE';

SELECT stage, r AS failure_reason, count(*) AS n,
       min(inserted_at) AS first_seen, max(inserted_at) AS last_seen
FROM dep_classified WHERE class='BOX_UNREACHABLE'
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 10;

\echo
\echo ===== ARM E — LIVE FAILING CLASSES: which classes have a pulse in the last 6h / 1h =====
\echo -- "the only live failing class" is a claim about THIS table, so it prints here.
SELECT class,
       count(*) FILTER (WHERE inserted_at >= now() - interval '1 hour')  AS n_1h,
       count(*) FILTER (WHERE inserted_at >= now() - interval '6 hours') AS n_6h,
       max(inserted_at) AS last_seen
FROM dep_classified
WHERE class IS NOT NULL AND status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE'
GROUP BY class HAVING count(*) FILTER (WHERE inserted_at >= now() - interval '6 hours') > 0
ORDER BY n_6h DESC;

\echo
\echo ===== ARM F — SETTLED-WINDOW HEADLINE: the 24h rate EXCLUDING the last hour (nothing in flight) =====
\echo -- @min_sample = 200. Below that, verdict is INSUFFICIENT VOLUME, which is a legitimate answer.
SELECT count(*) AS volume,
       count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE') AS failed,
       count(*) FILTER (WHERE status='live') AS live,
       count(*) FILTER (WHERE status='deferred') AS deferred,
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*),0), 2) AS fr_all,
       round(100.0 * count(*) FILTER (WHERE status='failed' AND class <> 'GITHUB_PUSH_UNBUILDABLE')
             / NULLIF(count(*) FILTER (WHERE status IN ('failed','live')),0), 2) AS fr_settled,
       CASE WHEN count(*) >= 200 THEN 'SUFFICIENT' ELSE 'INSUFFICIENT VOLUME' END AS verdict
FROM dep_classified
WHERE inserted_at >= now() - interval '25 hours' AND inserted_at < now() - interval '1 hour';
