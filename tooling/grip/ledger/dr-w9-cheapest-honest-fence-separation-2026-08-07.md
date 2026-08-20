# dr-w9 — the cheapest honest fence: measured separation across the fleet (2026-08-07)

Re-derivation recipes for the wave-9 fence-selection verdict. Every row is a
literal command. Boxes: cloud-db-1 = 178.105.92.191 (control-plane Postgres).

## R1 — vital PRESENCE per box (the decisive one)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select b.name, k, count(*) from agent_events e join barkparks b on b.id=e.barkpark_id, lateral jsonb_object_keys(e.payload) k where e.type='"'"'health'"'"' and e.inserted_at>now()-interval '"'"'30 minutes'"'"' group by 1,2 order by 2,1"'

Expect: cpu_percent / load1 / disk_used_percent / mem_used_percent on ALL 5
reporting boxes; load15 / cpu_cores / swap_used_percent / err_5xx_per_s on
Guerrilla ONLY.

## R2 — cpu_percent threshold sweep (level fence, false-positive rate)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select b.name, b.health_status, count(*) n, count(*) filter (where (e.payload->>'"'"'cpu_percent'"'"')::numeric >= 70) c70, count(*) filter (where (e.payload->>'"'"'cpu_percent'"'"')::numeric >= 85) c85, count(*) filter (where (e.payload->>'"'"'cpu_percent'"'"')::numeric >= 95) c95 from agent_events e join barkparks b on b.id=e.barkpark_id where e.type='"'"'health'"'"' and e.inserted_at > now() - interval '"'"'48 hours'"'"' group by 1,2 order by 3 desc"'

## R3 — SUSTAINED fence (12-of-15 beats >= 85): the perfect separator

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "with w as (select b.name, e.inserted_at, ((e.payload->>'"'"'cpu_percent'"'"')::numeric >= 85)::int hot from agent_events e join barkparks b on b.id=e.barkpark_id where e.type='"'"'health'"'"' and e.inserted_at > now() - interval '"'"'48 hours'"'"'), r as (select name, inserted_at, sum(hot) over (partition by name order by inserted_at rows between 14 preceding and current row) hot15 from w) select name, max(hot15) max_hot_in_15, count(*) filter (where hot15 >= 12) beats_w_12of15 from r group by 1 order by 2 desc"'

## R4 — re-derive D67's 1.75 fence from REAL load15 (D67 ordered this)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select count(*) real_l15_beats, round(min((payload->>'"'"'load15'"'"')::numeric/(payload->>'"'"'cpu_cores'"'"')::numeric),3) mn, round(percentile_cont(0.5) within group (order by (payload->>'"'"'load15'"'"')::numeric/(payload->>'"'"'cpu_cores'"'"')::numeric)::numeric,3) p50, round(max((payload->>'"'"'load15'"'"')::numeric/(payload->>'"'"'cpu_cores'"'"')::numeric),3) mx, count(*) filter (where (payload->>'"'"'load15'"'"')::numeric/(payload->>'"'"'cpu_cores'"'"')::numeric>=1.75) ge175, min(inserted_at) first_real from agent_events where type='"'"'health'"'"' and barkpark_id='"'"'b2b81e69-c79c-4eff-b6d7-84507d15b925'"'"' and payload ? '"'"'load15'"'"' and payload ? '"'"'cpu_cores'"'"'"'

## R5 — the agent-binary pin (why only guerrilla reports the ratio vitals)

    for ip in 157.180.90.121 91.98.139.58; do ssh -i ~/.ssh/barkpark_indx root@$ip 'ls -la /usr/local/bin/barkpark-agent'; done

## R6 — no verdict arm exists on main

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '55,80p'
    git grep -n "strainedLoad15PerCore\|1\.75" origin/main -- internal/
