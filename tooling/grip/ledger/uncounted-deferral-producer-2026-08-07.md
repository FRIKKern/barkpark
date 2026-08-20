# Re-derivation recipe — the UNCOUNTED deferral producer (wave 12 VERIFY v6)

`auto_deploy_worker.defer_behind_running_build/2` returns `{:ok, :deferred}` and mints
NO `deployments` row. Nothing in this epic has ever measured it. Control plane =
`178.105.92.191`; DB container `cloud-db-1`; live slot = the RUNNING
`cloud-control_plane_{blue,green}-1` container (there is no systemd unit for it —
`systemctl` names only `barkpark-provisioner` and `caddy`; Caddy's upstream is
`localhost:4101`). All measurements 2026-08-07 08:38–08:43Z. `origin/main` = ba712a4b2.

## 0. Which slot is live, and how much log history exists

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}'"
```

TRAP: the app logs ONLY to the container's json-file driver. `journalctl --since '24 hours ago'
| grep -c 'deferred for site'` returns **0** against 41,498 journal lines — the app is not in
journald at all. Each cloud/** merge recreates a slot container, so log history is MINUTES.

## 1. The two log strings (sanity total first — a zero grep is a broken grep)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker logs --timestamps cloud-control_plane_green-1 2>&1 | grep -c 'site deploy deferred for site'"   # COUNTED producer, deploy.ex:1255
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker logs --timestamps cloud-control_plane_green-1 2>&1 | grep -c 'auto-deploy deferred for site'"   # UNCOUNTED producer, auto_deploy_worker.ex:307
```

## 2. The DB-side gap: job runs that minted no row

Every completed `AutoDeployWorker` run either mints one row (`Deploy.enqueue` ok) or hits a
`{:duplicate, _}` arm and mints NONE. `{:cancel, _}` arms land in Oban state `cancelled`, so
filtering `state='completed'` isolates the drive path (24h census: 3,720 completed, ZERO other states).

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"
with j as (select date_trunc('\''hour'\'', attempted_at) h, count(*) jobs from oban_jobs where worker='\''BarkparkCloud.Sites.AutoDeployWorker'\'' and state='\''completed'\'' and attempted_at > now() - interval '\''24 hours'\'' group by 1),
d as (select date_trunc('\''hour'\'', inserted_at) h, count(*) filter (where trigger='\''content-auto'\'') rows_ca, count(*) filter (where status='\''deferred'\'') deferred from deployments where inserted_at > now() - interval '\''24 hours'\'' group by 1)
select coalesce(j.h,d.h), coalesce(jobs,0), coalesce(rows_ca,0), coalesce(jobs,0)-coalesce(rows_ca,0) gap, coalesce(deferred,0) from j full outer join d on j.h=d.h order by 1\"'"
```

## 3. Why the gap moved (the mechanism)

Gap tracks how long a row stays non-terminal — while a row is queued/building, the next job
coalesces onto it and mints nothing:

```
... 'psql -tAc "select date_trunc('hour',inserted_at) h, round(avg(extract(epoch from (claimed_at-inserted_at)))::numeric,2) queued_s, count(*) n from deployments where inserted_at > now() - interval '24 hours' and trigger='content-auto' group by 1 order by 1"'
... 'psql -tAc "select date_trunc('hour',inserted_at) h, status, count(*), round(avg(extract(epoch from (updated_at-inserted_at)))::numeric,1) avg_s from deployments where inserted_at > now() - interval '24 hours' group by 1,2 order by 1,2"'
```

## 4. BOUND, not point estimate

The gap is an UPPER bound on uncounted deferrals: the `{:duplicate, %{status: "queued"}}` arm
re-drives an existing row (also no new row) and is indistinguishable in the DB. The ONLY
discriminator is the `auto-deploy deferred for site` log line — retained for minutes. Conversely
if any producer other than the worker mints `content-auto` rows the gap UNDERSTATES.

## 5. Code anchors (origin/main only — the worktree is hundreds of commits behind)

```
git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | sed -n '216,320p'   # drive/2, start_and_report/2, defer_behind_running_build/2
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1195,1265p'             # the COUNTED deferral row writer
```
