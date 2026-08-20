# Re-derivation recipes — box-rate degeneracy (deploy-reliability wave 10)

Taken 2026-08-07 against cloud-db-1 (control plane, 178.105.92.191) and origin/main.
Every number below is re-derivable by the command beside it. Windows are FLOATING
(`now() - interval '24 hours'`), so counts drift by a few rows between runs — that
drift is the point of movement 2, not an error here.

## 1. The barkpark-grouped fold (movement 1's actual shape)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"select b.name, b.id, count(*) filter (where d.status='failed') f, count(*) filter (where d.status='live') l, count(*) filter (where d.status='deferred') df, count(*) tot from deployments d join sites s on s.id=d.site_id join barkparks b on b.id=s.barkpark_id where d.inserted_at >= now()-interval '24 hours' and d.inserted_at < now() group by 1,2;\""

Returns ONE row: Guerrilla b2b81e69-c79c-4eff-b6d7-84507d15b925 | 593 | 685 | 1147 | 2425.
Terminal n = 593+685 = 1278, terminal failure rate 46.40%. A second run seconds later
gave 46.43% of n=1275 — same box, same query, different window edge.

## 2. Degeneracy

    ... -c 'select count(*) from barkparks' -c 'select count(distinct barkpark_id), count(*) from sites'
    ... -c "select b.id, b.name, count(s.id) from barkparks b left join sites s on s.barkpark_id=b.id group by 1,2 order by 3 desc;"
    ... -c "select b.name, count(d.id) alltime from barkparks b join sites s on s.barkpark_id=b.id join deployments d on d.site_id=s.id group by 1;"

8 barkparks · 13 sites over 2 barkpark_ids · Guerrilla 12 sites / jarl 1 site /
SIX barkparks with ZERO sites. All-time deployments: Guerrilla 30,263, jarl 55,
everyone else 0. Total deployments table = 30,319 rows / 44 MB.

## 3. min_sample reachability

`@min_sample 200` (origin/main cloud/lib/barkpark_cloud/deploy_ledger.ex:169).
jarl's ALL-TIME deployment count is 55 — it cannot reach 200 in any window ever.
=> exactly 1 of 8 boxes can reach a metered verdict; 7 of 8 are UNMETERED on day one.

## 4. Composition crack (per-site rates inside the SAME window)

    ... -c "select d.site_id, count(*) filter (where d.status in ('failed','live')) n, count(*) filter (where d.status='failed') f from deployments d where d.inserted_at >= now()-interval '24 hours' group by 1 order by 2 desc;"

Five sites individually clear n>=200; their rates span 17.0% (46/270) to 70.5% (179/254).

## 5. Index counterfactual — RUN, not reasoned

    ... -c "create index concurrently if not exists tmp_dep_inserted_at on deployments(inserted_at);"
    ... -c "EXPLAIN (ANALYZE,BUFFERS) select s.barkpark_id, d.status, count(*) from deployments d join sites s on s.id=d.site_id where d.inserted_at >= now()-interval '24 hours' group by 1,2;"
    ... -c 'drop index concurrently tmp_dep_inserted_at;'

WITHOUT (rides column 2 of deployments_status_inserted_at_index, bitmap): cost 4733,
buffers 631, Execution Time 5.220 ms.
WITH standalone (inserted_at): cost 923, buffers 2274, Execution Time 4.484 ms.
Planner cost falls 5.1x; real time falls 14%; buffers TRIPLE. Not a win at 30k rows.
The temp index was dropped in the same command; `select indexname from pg_indexes
where tablename='deployments'` should show 9 indexes, none named tmp_*.

## 6. Verdict-side absences on origin/main

    git grep -c 'Pressure' origin/main -- internal/cloudclient/     # no output = ZERO
    git grep -n 'unmeteredMarker' origin/main -- internal/          # ZERO (lives only in unmerged #9887)
    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '50,73p'   # switch ends `default: return "ok"`
    git show origin/main:cloud/priv/static/__fixtures__/attention_order.json  # 8 states, ok=8
    git show origin/main:cloud/priv/static/app.js | grep -n 'ATTENTION_RANK' -A 4  # 9 states, unreported=5, ok=9
