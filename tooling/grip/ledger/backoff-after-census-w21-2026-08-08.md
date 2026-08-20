# Re-derivation recipe — deferral census AFTER the depth-derived backoff (#10611)

Window bounds used: **backoff live since 2026-08-08T02:40:16Z** (earliest 120s-rung
AutoDeployWorker job, all-time — see query T), census taken at **2026-08-08T03:11–03:13Z**.
Elapsed: **~32 minutes**, NOT "hours". CP container `cloud-control_plane_blue-1` StartedAt
2026-08-08T02:45:39Z (a SECOND flip; the first, `_green-1`, was created 02:43:22Z and the
rung jobs predate both, so the live-since bound comes from the DATA, not the container).

## Host / access

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191
    docker cp <file>.sql cloud-db-1:/tmp/x.sql
    docker exec cloud-db-1 sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB -f /tmp/x.sql'

## T — is the backoff live at all, and since when (ALL-TIME, no window assumed)

    select round(extract(epoch from (scheduled_at - inserted_at)))::int delay_s,
           count(*), min(inserted_at), max(inserted_at)
    from oban_jobs where worker='BarkparkCloud.Sites.AutoDeployWorker'
    group by 1 order by 1;

Rungs 120/180/240 exist ONLY from 02:40:16 onward. 60s: 12,387 rows since 2026-08-01.
(78/79/98 = 4 clock-skew rows, ignore.)

## L — does the Oban site_id unique COLLAPSE the longer delay? (the whole question)

    select d.deferral_depth, count(*) total,
      count(*) filter (where j.delay_s = least(60*d.deferral_depth,240)) matched_rung,
      count(*) filter (where j.delay_s = 60 and d.deferral_depth>1) collapsed_to_60
    from (select id, site_id, deferral_depth, updated_at from deployments
          where status='deferred' and inserted_at >= timestamptz '2026-08-08 02:40:16Z') d
    left join lateral (
      select round(extract(epoch from (scheduled_at - inserted_at)))::int delay_s
      from oban_jobs o where o.worker='BarkparkCloud.Sites.AutoDeployWorker'
       and o.args->>'site_id' = d.site_id::text
       and o.inserted_at between d.updated_at - interval '5 seconds'
                            and d.updated_at + interval '5 seconds'
      order by o.inserted_at limit 1) j on true
    group by 1 order by 1;

## V — coalescing invariant at the 240s cap (criterion 3): overlapping pending pairs per site

    with j as (select args->>'site_id' s, inserted_at ins, scheduled_at sch
               from oban_jobs where worker='BarkparkCloud.Sites.AutoDeployWorker'
               and inserted_at >= timestamptz '2026-08-08 02:40:16Z')
    select a.s, count(*) overlapping_pairs from j a
    join j b on a.s=b.s and a.ins < b.ins and b.ins < a.sch group by 1 order by 2 desc;

## N — attempts-per-live, before/after on the SAME query

    select case when inserted_at >= timestamptz '2026-08-08 02:45:39Z' then 'after' else 'before12h' end w,
      count(*) total, count(*) filter (where status='live') live,
      round(count(*)::numeric / nullif(count(*) filter (where status='live'),0),2) attempts_per_live
    from deployments where inserted_at >= timestamptz '2026-08-07 14:45Z' group by 1;

## R — abandonment proximity (the bound-12 regression question)

    select deferral_depth, count(*) from deployments where deferral_depth >= 8 group by 1 order by 1;
    select max(deferral_depth) from deployments;

All-time max depth is 9. No row has ever reached the 12-round capacity bound, before or
after. The abandonment-regression question therefore has a ZERO base rate and cannot be
answered by this window — only by one long enough to observe a rare event.
