# Re-derivation recipe — w15 verify [headline-is-rebucketing]

Date: 2026-08-07. Box: cloud-db-1 on 178.105.92.191 (control plane). All SQL is
read-only. `psql -f` reads INSIDE the container — always pipe on stdin instead.

## R1 — daily status census (the second independent method)

```sh
cat > /tmp/v1.sql <<'EOF'
SELECT date_trunc('day',inserted_at) d, count(*) att,
       count(*) FILTER (WHERE status='live') live,
       count(*) FILTER (WHERE status='failed') failed,
       count(*) FILTER (WHERE status='deferred') def,
       count(*) FILTER (WHERE status='cancelled') canc,
       round(100.0*count(*) FILTER (WHERE status='live')/nullif(count(*),0),2) live_pct
FROM deployments WHERE inserted_at >= '2026-07-28' GROUP BY 1 ORDER BY 1;
SELECT count(*) sanity_total FROM deployments;
EOF
scp -q -i ~/.ssh/barkpark_indx /tmp/v1.sql root@178.105.92.191:/tmp/v1.sql \
  && ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
     'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod < /tmp/v1.sql'
```

## R2 — the D179 boundary split, on a window that is NOT D209's

```sql
SELECT CASE WHEN inserted_at < '2026-08-06 22:19:52' THEN 'BEFORE' ELSE 'AFTER' END side,
       count(*) att,
       count(*) FILTER (WHERE status='live') live,
       count(*) FILTER (WHERE status='failed') failed,
       count(*) FILTER (WHERE status='deferred') def,
       round(100.0*count(*) FILTER (WHERE status='live')/count(*),2) live_pct,
       round(100.0*count(*) FILTER (WHERE status='failed')/count(*),2) failed_pct
FROM deployments WHERE inserted_at >= '2026-08-06 06:00:00' GROUP BY 1;
```

## R3 — the 08-01..08-04 regime, hour by hour, with zero-live hours flagged

```sql
SELECT date_trunc('hour',inserted_at) h, count(*) att,
       count(*) FILTER (WHERE status='live') live,
       CASE WHEN count(*) FILTER (WHERE status='live')=0 THEN '<<ZERO' ELSE '' END z
FROM deployments WHERE inserted_at >= '2026-08-01' AND inserted_at < '2026-08-05'
GROUP BY 1 ORDER BY 1;
```

The eleven `<<ZERO` hours ALL carry `att = 1`. Any detector that treats them as
outage hours is reading heartbeat noise. Guard any episode fixture with a
minimum-volume floor per bucket or this window manufactures eleven fake episodes.

## R4 — the `deferred` vocabulary's birth

```sh
git log origin/main --format='%h %ad %s' --date=short -S'deferred' \
  -- cloud/lib/barkpark_cloud/registry/deployment.ex
git show 2154e695f^:cloud/lib/barkpark_cloud/registry/deployment.ex | grep -n '@statuses'
git show 2154e695f:cloud/lib/barkpark_cloud/registry/deployment.ex  | grep -n '@statuses'
```

Plus the data-side confirmation that no row predates the code:

```sql
SELECT count(*) def_before_0805 FROM deployments WHERE status='deferred' AND inserted_at < '2026-08-05';
SELECT min(inserted_at) first_def, max(inserted_at) last_def, count(*) FROM deployments WHERE status='deferred';
```

## Trap this recipe exists to prevent

`docker exec -i … psql -f /tmp/v1.sql` fails with
`psql: error: /tmp/v1.sql: No such file or directory` even after a SUCCESSFUL
scp — the path resolves in the container, not on the host. The `&&` chain still
exits non-zero so it is loud, but the failure reads as "scp did not land",
which is wrong. Redirect on stdin.
