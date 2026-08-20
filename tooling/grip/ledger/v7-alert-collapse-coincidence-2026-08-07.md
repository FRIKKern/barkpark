# v7-alert-collapse-coincidence — re-derivation recipes (wave 12, verifier)

Read-only. Control-plane Postgres `cloud-db-1` on 178.105.92.191 (db read from
`$POSTGRES_DB` inside the container, never hardcoded). All timestamps are naive
UTC (`now()` on the box returned `+00`).

Transport used for every multi-statement proof (SQL in a FILE, piped on stdin —
avoids the quoting traps that make one-liners lie):

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -A -F\"|\"'" < v7.sql

## The alarm channel is 1:1 with `status='failed'`, hour for hour (not a cap, not a reaper)
    -- 54 hours 08-03 15:00Z .. 08-07 08:00Z: failed 2286, notif 2296, total |hourly diff| 72
    with n as (select date_trunc('hour',inserted_at) h,count(*) c from notification_deliveries where event='deployment_failed' group by 1),
         d as (select date_trunc('hour',inserted_at) h,count(*) c from deployments where status='failed' and inserted_at>=timestamp '2026-08-03' group by 1)
    select count(*), sum(abs(coalesce(n.c,0)-coalesce(d.c,0))), sum(coalesce(d.c,0)), sum(coalesce(n.c,0))
    from d full join n on n.h=d.h where coalesce(d.h,n.h) >= timestamp '2026-08-03 15:00';

## The crossover is 22:15–22:30Z on 08-06, NOT 20:00Z (15-min buckets separate the two events)
    -- 20:00 att=5 / 20:30 att=1 / 21:30 att=1  → a ~2h TRIGGER STOPPAGE (4 rows, all live after 20:11:38)
    -- 22:15 att=10 failed=3 notif=3 → 22:30 att=57 failed=0 deferred=42 notif=0  → the rename
    select date_trunc('hour',inserted_at)+(extract(minute from inserted_at)::int/15)*interval '15 min' b,
           count(*), count(*) filter (where status='failed'), count(*) filter (where status='deferred')
    from deployments where inserted_at>=timestamp '2026-08-06 19:00' and inserted_at<timestamp '2026-08-06 23:30' group by 1 order by 1;

## Suppressed rows = ZERO, and the cap is structurally unable to bind
    select status,count(*) from notification_deliveries group by 1;      -- sent 2999 | failed 5. No 'suppressed'.
    -- reaper-attributable failures, 08-03..08-07, matched on the four @*_reason literals in registry.ex:63-66
    select inserted_at::date, count(*) filter (where failure_reason like 'exceeded max deploy claim attempts%'), ...
      from deployments where inserted_at>=timestamp '2026-08-03' group by 1;   -- 0 | 0 | 0 | 0 every day
    -- max reaper-shaped failures in ANY single minute, table-wide: 1 (2026-07-16). @reap_alert_cap is 25/sweep.

## The alarm channel is YOUNGER than the epic — 6,119 failures 07-31..08-02 alerted NOBODY
    select count(*) from notification_deliveries where event='deployment_failed' and inserted_at < timestamp '2026-08-03';  -- 0
    select min(inserted_at) from notification_deliveries where event='deployment_failed';   -- 2026-08-03 14:57:40.197109
    select count(*) from deployments where status='failed' and inserted_at>=timestamp '2026-07-31' and inserted_at<timestamp '2026-08-03';  -- 6119
    -- NOT a retention artifact: agent_unreachable rows exist on 07-29/30/31, 08-01, 08-02, 08-03.
    -- Cause: `git log origin/main -S maybe_dispatch_deployment_failed` → 96a120b71, 2026-08-03 16:54:16 +0200
    -- (= 14:54:16Z). First alert row is 3m24s later. The feature did not exist before that merge auto-deployed.

## A `deferred` transition notifies nobody — by construction
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '6875,6886p'
    # defp maybe_dispatch_deployment_failed(_prior, %Deployment{status: "failed"} = updated) — edge INTO "failed" only.

## The suppression instrument WAS deployed during the 870/day peak (so zero means zero)
    git log origin/main --diff-filter=A -- cloud/lib/barkpark_cloud/notifications/withhold.ex   # 3ec60597c 2026-08-05 23:50:29 +0200
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-control_plane_green-1 sh -c 'find / -name \"*Withhold*\" 2>/dev/null | head -3'"
    # /app/lib/barkpark_cloud-0.1.0/ebin/Elixir.BarkparkCloud.Notifications.Withhold.beam

## D164 correction stands: ONE recipient, ONE team
    select event,count(*),count(distinct recipient),count(distinct team_id) from notification_deliveries group by 1;
    # deployment_failed | 2298 | 1 | 1
