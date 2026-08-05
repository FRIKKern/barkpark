# Re-derivation recipes — deploy failure census at full scale (2026-08-05)

Authority L1 (control-plane Postgres, read directly). The API projection hard-caps 200 rows/site
with no cursor and humanizes `failure_reason`; never quote it for a census.

Pinned window used throughout: `inserted_at < timestamp '2026-08-05 18:00:00'` (26,413 rows).

Prefix for every recipe:

    SSH="ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud"
    PSQL="docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod"

## R1 — full column list (rules out soft-delete/archival)

    $SSH "$PSQL -c '\\d deployments'"

27 columns; none of deleted_at / archived_at / discarded_at / visible. Raw count == app population.

## R2 — universe size and status split

    $SSH "$PSQL -c \"select count(*), min(inserted_at), max(inserted_at) from deployments;\" \
                -c \"select status, count(*) from deployments group by 1 order by 2 desc;\""

## R3 — taxonomy on RAW failure_reason, pinned upper bound

    $SSH "$PSQL -c \"select case when failure_reason is null then 'NULL_REASON'
      when failure_reason like '%409%' then 'BOX_BUSY_409'
      when failure_reason like '%bp-doc-id%' then 'DOC_ID_EMPTY'
      when failure_reason like '%403%' then 'FORBIDDEN_403'
      when failure_reason like '%500%' then 'BOX_500'
      when failure_reason like 'BUILD failed%' then 'BUILD_FAILED'
      else 'OTHER' end k, count(*) from deployments
      where status='failed' and inserted_at < timestamp '2026-08-05 18:00:00'
      group by 1 order by 2 desc;\""

## R4 — rate WITH volume (lifetime / 7d / 24h). Never quote an absolute count alone:
volume fell from 2,766/day (07-30) to 74/day (08-05).

    $SSH "$PSQL -c \"select 'lifetime' w, count(*) n, count(*) filter (where status='failed') f,
      round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),1) pct
      from deployments where inserted_at < timestamp '2026-08-05 18:00:00'
      union all select '7d', count(*), count(*) filter (where status='failed'),
      round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),1)
      from deployments where inserted_at < timestamp '2026-08-05 18:00:00'
        and inserted_at >= timestamp '2026-07-29 18:00:00'
      union all select '24h', count(*), count(*) filter (where status='failed'),
      round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),1)
      from deployments where inserted_at < timestamp '2026-08-05 18:00:00'
        and inserted_at >= timestamp '2026-08-04 18:00:00';\""

## R5 — the 409 identity question (git_ref is NULL on 100% of them)

    $SSH "$PSQL -c \"select count(*) total_409, count(git_ref) nonnull_gitref,
      count(delivery_id) nonnull_delivery from deployments
      where status='failed' and failure_reason like '%409%';\" \
      -c \"select count(*) all_rows, count(git_ref) with_gitref from deployments;\""

Consequence: `deployments_active_site_ref_index` UNIQUE (site_id, git_ref) WHERE status in
(queued,building,pushing) AND environment='production' is INERT — NULL git_ref never collides
in a btree unique index. Slice 4 cannot rely on it.

## R6 — what is actually inside the HTTP-500 class

    $SSH "$PSQL -c \"select failure_reason, count(*) from deployments
      where status='failed' and failure_reason like '%500%' group by 1 order by 2 desc limit 25;\""

## R7 — class x stage crosstab (stage is already a near-perfect classifier partition)

    $SSH "$PSQL -c \"select case when failure_reason like '%409%' then 'BOX_BUSY_409'
      when failure_reason like '%bp-doc-id%' then 'DOC_ID_EMPTY'
      when failure_reason like '%403%' then 'FORBIDDEN_403'
      when failure_reason like '%500%' then 'BOX_500' else 'OTHER' end k, stage, count(*)
      from deployments where status='failed' group by 1,2 order by 1,3 desc;\""

## R8 — the regression proof (clamp merged 2026-07-30 03:37:37 UTC = 05:37:37 +0200, #7870)

    $SSH "$PSQL -c \"select s.slug,
      count(*) filter (where d.inserted_at <  timestamp '2026-07-30 03:37:37') pre,
      count(*) filter (where d.inserted_at >= timestamp '2026-07-30 03:37:37') post,
      count(*) filter (where d.status='live' and d.inserted_at >= timestamp '2026-07-30 03:37:37') live_post
      from deployments d join sites s on s.id=d.site_id
      where s.slug in ('astro-search','search','search-ember','search-capstone','live-auto')
      group by 1 order by 1;\""

    git log origin/main --since='2026-07-29 20:00' --until='2026-07-30 06:00' --format='%h %ad %s' --date=iso

## R9 — per-site class matrix (89% of all failures live on 4 sites)

    $SSH "$PSQL -c \"select s.slug, count(*) n, count(*) filter (where d.status='failed') f,
      count(*) filter (where d.failure_reason like '%409%') c409,
      count(*) filter (where d.failure_reason like '%bp-doc-id%') docid,
      count(*) filter (where d.failure_reason like '%500%') c500,
      count(*) filter (where d.failure_reason like '%403%') c403,
      max(d.inserted_at) filter (where d.status='live') last_live
      from deployments d join sites s on s.id=d.site_id group by 1 order by 2 desc;\""

## R10 — GITHUB_PUSH_UNBUILDABLE population (7 rows; human-gated, cannot be moved by this wave)

    $SSH "$PSQL -c \"select count(*) from deployments where status='failed'
      and failure_reason like '%github push builds require%';\""

## R11 — the HEALTH 308 on guerrilla (slot-a services are in failed state right now)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "systemctl status barkpark-site@search__a --no-pager -n 12"

Next boots ("Ready in 0ms" on 127.0.0.1:8404), the probe gets 308, the unit is stopped (SIGTERM 143).
That is a basePath/trailing-slash probe mismatch, not a boot failure.
