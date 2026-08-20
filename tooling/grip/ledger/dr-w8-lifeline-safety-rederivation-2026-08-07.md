# dr-w8 [lifeline-safety] — re-derivation recipes (2026-08-07 ~01:00Z)

Verifier: deploy-reliability wave 8. Host: cloud-db-1 via CP `178.105.92.191`.
Every number below re-derives with the literal command beside it. No repo code was changed.

## R1 — AutoDeployWorker duration distribution (the rescue_after floor)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' -c \"select percentile_disc(0.5) within group (order by completed_at-attempted_at), percentile_disc(0.95) within group (order by completed_at-attempted_at), percentile_disc(0.99) within group (order by completed_at-attempted_at), percentile_disc(0.999) within group (order by completed_at-attempted_at), max(completed_at-attempted_at), count(*) filter (where completed_at-attempted_at > interval '30 seconds'), count(*) from oban_jobs where worker like '%AutoDeployWorker' and state='completed';\""
```

2026-08-07 result: p50 0.329s | p95 2.630s | p99 5.771s | p999 9.170s | max 15.016715s | >30s = 0 | n = 13287.

## R2 — the eight executing zombies, with node + max_attempts

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -x -c \"select id, worker, queue, attempt, max_attempts, attempted_at, attempted_by, args from oban_jobs where state='executing' order by id;\""
```

## R3 — was the stuck job's publish actually lost? (per-zombie successor probe)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' -c \"select z.id, z.attempted_at, (select min(inserted_at) from deployments d where d.site_id=(z.args->>'site_id')::uuid and d.inserted_at>z.attempted_at) next_dep from oban_jobs z where z.state='executing' and z.worker like '%AutoDeployWorker' order by z.attempted_at;\""
```

Note the deployments table column is `stage`, NOT `state` (a `state=` filter errors out).

## R4 — the clip: Oban's shutdown grace equals the observed max

```
git show origin/main:cloud/config/config.exs | grep -n "shutdown_grace"      # empty -> default
grep -rn "shutdown_grace_period" <any>/cloud/deps/oban/lib/oban/config.ex    # :timer.seconds(15)
```

## R5 — Lifeline's rescue-vs-discard rule (Oban 2.23.0)

```
sed -n "$(grep -n 'def rescue_jobs' <any>/cloud/deps/oban/lib/oban/engines/basic.ex | head -1 | cut -d: -f1),+20p" <any>/cloud/deps/oban/lib/oban/engines/basic.ex
```
`attempt < max_attempts` -> "available"; `attempt >= max_attempts` -> "discarded".
