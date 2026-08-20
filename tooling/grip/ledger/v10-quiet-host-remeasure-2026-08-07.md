# v10-quiet-host-remeasure — re-derivation recipes (2026-08-07 ~03:00–03:10Z)

Wave 9, deploy-reliability epic. Every number below is re-derivable with the
command beside it. origin/main = 95642c5500119d5ef5bb938a47516cacb5ab0f05.

## 1. Deploy rate, per side of the 2026-08-06 22:24:16Z capacity-door cutover

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select case when inserted_at < timestamp '"'"'2026-08-06 22:24:16'"'"' then '"'"'pre-door'"'"' else '"'"'post-door'"'"' end side, status, count(*) from deployments where inserted_at > now() - interval '"'"'30 hours'"'"' group by 1,2 order by 1,3 desc"'

D107 form (denominator + basis on the same line), NEVER compared across the door:
- pre-door  : 1032 failed / 1611 terminal = 64.1% terminal-failure; 1032 / 2308 all rows; 697 / 2308 = 30.2% deferred.
- post-door :    8 failed /  223 terminal =  3.6% terminal-failure;    8 /  900 all rows; 677 /  900 = 75.2% ABSORBED by the build cap.

Per-hour with denominators carried:

    ...psql -c "select date_trunc('hour',inserted_at) hr, round(100.0*count(*) filter (where status='failed')/nullif(count(*) filter (where status in ('failed','live')),0),1) term_fail_pct, count(*) filter (where status in ('failed','live')) terminal, round(100.0*count(*) filter (where status='deferred')/count(*),1) absorbed_pct, count(*) all_rows from deployments where inserted_at > now() - interval '30 hours' group by 1 order by 1 desc"

## 2. Active slot MUST be resolved before journalctl (erratum recurred 3x)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ACTIVE=$(for s in blue green; do systemctl is-active -q barkpark-slot@$s.service && echo $s; done); echo ACTIVE=$ACTIVE; systemctl show barkpark-slot@$ACTIVE.service -p ActiveEnterTimestamp'

Slot flips 4x in 4.2h (22:24:16 blue, 00:38:37 green, 00:55:20 blue, 02:35:02 green).
A per-unit "last 60 min" count CANNOT cover 60 min on this box. Use unit-agnostic
attribution instead:

    ssh ... 'journalctl --since "8 hours ago" --no-pager -o short-iso | grep "DBConnection.ConnectionError" | cut -c1-13 | sort | uniq -c'
    ssh ... 'journalctl --since "6 hours ago" --no-pager -o json | grep "DBConnection.ConnectionError" | grep -oE "\"_SYSTEMD_UNIT\":\"[^\"]+\"" | sort | uniq -c'

NOTE: `grep -oE "barkpark-slot@[a-z]+|start.sh"` on short-iso output attributes to
the SYSLOG IDENTIFIER (both slots run start.sh) and is useless. Use _SYSTEMD_UNIT
from -o json.

## 3. Vitals: fleet coverage and fence firing

    ...psql -c "select b.name, count(*) beats, count(*) filter (where p.payload ? 'load15') with_load15, count(*) filter (where p.payload ? 'p95_ms') with_p95 from agent_events p join barkparks b on b.id=p.barkpark_id where p.type='health' and p.inserted_at > now() - interval '6 hours' group by 1 order by 2 desc"

    ...psql -c "select b.name, count(*) n, round(percentile_cont(0.5) within group (order by (p.payload->>'p95_ms')::float)::numeric,0) med_p95, round(max((p.payload->>'p95_ms')::float)::numeric,0) worst from agent_events p join barkparks b on b.id=p.barkpark_id where p.type='health' and p.payload ? 'p95_ms' and p.inserted_at > now() - interval '6 hours' group by 1"

    ...psql -c "select date_trunc('hour',inserted_at) hr, count(*) rich, count(*) filter (where (payload->>'load15')::float/nullif((payload->>'cpu_cores')::float,0)>=1.75) fires, round(max((payload->>'load15')::float/nullif((payload->>'cpu_cores')::float,0))::numeric,3) mx from agent_events where type='health' and payload ? 'load15' and inserted_at > now() - interval '8 hours' group by 1 order by 1"

    ...psql -c "select min(inserted_at) from agent_events where type='health' and payload ? 'load15'"

## 4. Source-side

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '40,120p'      # attentionStatus — no vitals arm, "ok" is default:
    git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '289,297p'    # telemetry_threshold_meter — GUARDS n >= 0, so -1 -> @unmetered
    git grep -c "p95" origin/main -- cloud/lib/barkpark_cloud/web/router.ex        # 0 — p95 absent from the pressure block
