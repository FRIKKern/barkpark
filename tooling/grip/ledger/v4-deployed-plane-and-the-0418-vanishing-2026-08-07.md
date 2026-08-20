# v4 — the deployed plane, and the 04:18Z "vanishing" that happened at 22:19:52Z

Wave 12 verify. Every row re-derives from scratch with the literal command beside it.
Boxes: `178.105.92.191` = control plane (`barkpark-cp`, Postgres `cloud-db-1` /
`barkpark_cloud_prod`); `157.180.90.121` = Guerrilla, the CMS box that refuses.
L2 = `git show origin/main:` / `git grep origin/main`.

## 1. The deployed control plane IS origin/main (premise CONFIRMED)

Active slot is **green**, and the systemd units named in the assignment are both
`inactive` — the plane runs in Docker, not `barkpark-slot@*`.

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'systemctl is-active barkpark-slot@blue barkpark-slot@green; docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"; grep -n reverse_proxy /etc/caddy/Caddyfile'

Deployed HEAD, and the pull→build→start chain that produced it:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'cd /opt/barkpark && git rev-parse HEAD && git reflog --date=iso -3; docker inspect cloud-control_plane:latest --format "{{.Created}}"; docker inspect cloud-control_plane_green-1 --format "{{.State.StartedAt}}"'

Proof the running RELEASE (not just the checkout) carries wave 11:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-control_plane_green-1 sh -c "grep -rl content_publishes /app/lib; grep -rl defer_behind_running_build /app/lib"'

There is no `/version` endpoint; `/health` returns only `{"db","checked_at"}`.
Identity must be taken from the checkout + image/container timestamps.

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'curl -s localhost:4101/health; curl -s localhost:4101/version'

## 2. 04:18:46Z is the CHAIN-PROSE rollout boundary, not a deferral-cause boundary

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "SELECT count(*), min(inserted_at), max(inserted_at) FROM deployments WHERE failure_reason ILIKE '"'"'%in this site'"'"''"'"'s current chain%'"'"'"'

## 3. The real boundary: last `already_running` 19:37:26Z → first `box_at_capacity` 22:29:27Z

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "SELECT CASE WHEN failure_reason ILIKE '"'"'%box_at_capacity%'"'"' THEN '"'"'box_at_capacity'"'"' WHEN failure_reason ILIKE '"'"'%already_running%'"'"' THEN '"'"'already_running'"'"' WHEN failure_reason IS NULL THEN '"'"'(null)'"'"' ELSE '"'"'other'"'"' END AS cause, status, count(*), min(inserted_at), max(inserted_at) FROM deployments WHERE inserted_at > now() - interval '"'"'7 days'"'"' GROUP BY 1,2 ORDER BY 3 DESC"'

Hourly cross-tab that makes the 20:00–22:29Z quiet window and the cause swap visible
in one read (write to a file; the quoting is otherwise unmanageable):

    cat > /tmp/v4c.sql <<'SQL'
    SELECT date_trunc('hour', inserted_at) AS hr, status,
      CASE WHEN failure_reason ILIKE '%box_at_capacity%' THEN 'box_at_capacity'
           WHEN failure_reason ILIKE '%already_running%' THEN 'already_running'
           WHEN failure_reason IS NULL THEN '(null)' ELSE 'other' END AS cause,
      count(*)
    FROM deployments
    WHERE inserted_at >= timestamp '2026-08-06 18:00' AND inserted_at < timestamp '2026-08-07 06:00'
    GROUP BY 1,2,3 ORDER BY 1,4 DESC;
    SQL
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod' < /tmp/v4c.sql

## 4. The cause: the box took #9827 (`ef77af274`) at 22:19:52Z, 9m35s before the first row

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git reflog --date=iso | grep -E "2026-08-06 (1[6-9]|2[0-3])"'
    git log origin/main --oneline -S"box_at_capacity" --format="%h %cI %s"

The merge landed 2026-08-06T16:52:47Z; the box lagged it by **5h27m**. Nothing
records that lag — the box's code age is not a field anywhere.

## 5. The two causes are DISJOINT on the live box — this is not a rename

`running_slug?` (line 476) is evaluated BEFORE `box_at_capacity?` (line 490), so a
same-slug refusal still yields `already_running` and `box_at_capacity` can only be a
DIFFERENT slug. `box_at_capacity` deferrals are therefore a NEW population, not
relabelled old ones.

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -n "running_slug?\|box_at_capacity?\|already_running" /opt/barkpark/api/lib/barkpark/sites/deploy_runner.ex'

The two land in DIFFERENT ledger classes (`BOX_BUSY_DEFERRED` vs
`BOX_AT_CAPACITY_DEFERRED`), both inside the deferred cohort:

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '355,395p'

## 6. 100% of deferrals are one box

    cat > /tmp/v4f.sql <<'SQL'
    SELECT b.name, b.host,
      count(*) FILTER (WHERE d.failure_reason ILIKE '%box_at_capacity%') AS cap,
      count(*) FILTER (WHERE d.failure_reason ILIKE '%already_running%') AS busy
    FROM deployments d JOIN sites s ON s.id=d.site_id JOIN barkparks b ON b.id=s.barkpark_id
    WHERE d.status='deferred' AND d.inserted_at > now() - interval '24 hours'
    GROUP BY 1,2 ORDER BY 3 DESC;
    SQL
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod' < /tmp/v4f.sql

Note `barkparks` has `host`/`custom_host`, NOT `ip_address` — the obvious column
name errors out.
