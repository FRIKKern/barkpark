# Recorder 503 + range sourcing — live re-derivation recipes (dr-w26 verify)

Date: 2026-08-09. Ground: origin/main @ `0239dd4ee`. Boxes: control plane
`barkpark.cloud` (container `cloud-control_plane_green-1`, host port 4101 → 4100),
instance `157.180.90.121` (guerrilla). Key `~/.ssh/barkpark_indx`.

All probe rows written below were DELETED; the table holds exactly the one
hand-posted row (`2e38228b… / 31255918184 / cp`, inserted 2026-08-08 12:23:21).

## R1 — every branch of POST /v1/internal/platform-deliveries, live

```sh
ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'c=$(docker ps --format "{{.Names}}" | grep control_plane); WT=$(docker exec "$c" printenv WORKER_TOKEN);
   P(){ curl -s -w " HTTP=%{http_code}\n" -X POST -H "content-type: application/json" \
        -H "authorization: Bearer $WT" -d "$1" http://127.0.0.1:4101/v1/internal/platform-deliveries; }
   P "{\"deliveries\":[]}"                       # {"ok":true,"received":0,"recorded":0} 200
   P "{\"foo\":1}"                               # deliveries_required 422
   P "{\"deliveries\":[{\"sha\":\"NOTAHEX\",\"delivering_run_id\":1,\"first_seen_at\":\"2026-08-09T00:00:00Z\"}]}"   # invalid_row 422
   P "{\"deliveries\":[{\"sha\":\"deadbeefcafe0000000000000000000000000003\",\"delivering_run_id\":9990004,\"first_seen_at\":\"2026-08-09T00:00:00Z\",\"target\":null}]}"  # null_column target 422
  '
```

`null_column` is reachable ONLY through an explicit `"target": null` — `sha`,
`delivering_run_id`, `first_seen_at` are in `validate_required/2`, so an explicit
null on any of those is caught earlier as `invalid_row`.

## R2 — SUCCESS insert + `recorded` vs `received` on the re-keyed index

Two rows, same `(sha, delivering_run_id)`, different `target` → `recorded: 2`
(the W23 key would have eaten one). Identical re-post → `recorded: 0`.

```sh
B='{"deliveries":[
 {"sha":"deadbeefcafe0000000000000000000000000001","delivering_run_id":9990001,"first_seen_at":"2026-08-09T00:00:00Z","target":"cp","queued_seconds":5,"build_seconds":7},
 {"sha":"deadbeefcafe0000000000000000000000000001","delivering_run_id":9990001,"first_seen_at":"2026-08-09T00:00:00Z","target":"instance"}]}'
# post twice; expect {"received":2,"recorded":2} then {"received":2,"recorded":0}
# CLEANUP (mandatory):
ssh … root@barkpark.cloud 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod \
  -c "delete from platform_deliveries where sha like '"'"'deadbeefcafe%'"'"';"'
```

DB creds are in the container env: `docker exec cloud-db-1 printenv | grep -i postgres`
(role `barkpark_cloud`, db `barkpark_cloud_prod` — NOT `postgres`/`barkpark_cloud`).

## R3 — the typed 503, proved by MUTATION (table renamed away and back)

A watchdog restores the table even if the ssh session dies. Runs in ~2s.

```sh
ssh … root@barkpark.cloud 'set -x
P="docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -t -A"
nohup sh -c "sleep 25; docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod \
  -c \"ALTER TABLE IF EXISTS platform_deliveries_w26probe RENAME TO platform_deliveries\"" >/tmp/w26watchdog.log 2>&1 &
$P -c "ALTER TABLE platform_deliveries RENAME TO platform_deliveries_w26probe"
# … POST one valid row here → expect 503 …
$P -c "ALTER TABLE IF EXISTS platform_deliveries_w26probe RENAME TO platform_deliveries"'
```

Observed 503 body carries a `reason` the caller can branch on:
`{"error":"unavailable","reason":"platform_deliveries_missing","detail":"… nothing was recorded."}`.

## R4 — off-box insert over the PUBLIC edge (no SSH)

The route is internet-reachable through Caddy (`/etc/caddy/Caddyfile:2 reverse_proxy localhost:4101`):

```sh
curl -s -w " HTTP=%{http_code}\n" -X POST -H "content-type: application/json" \
  -H "authorization: Bearer $WORKER_TOKEN" -d '{"deliveries":[…]}' \
  https://barkpark.cloud/v1/internal/platform-deliveries      # 200 from a laptop
curl -s -o /dev/null -w "%{http_code}\n" -X POST -d '{"deliveries":[]}' \
  https://barkpark.cloud/v1/internal/platform-deliveries      # 401 without a token
```

Consequence for s8: the SSH one-hop is a CHOICE (zero new GH secrets), not a
necessity. If SSH is kept, do NOT hardcode `4101` — that is the GREEN slot's host
port and it flips on a blue/green deploy. Read it instead:
`grep -oE 'localhost:[0-9]+' /etc/caddy/Caddyfile`.

## R5 — can a box source its own old→new sha range?

```sh
ssh … root@barkpark.cloud 'cd /opt/barkpark
  git rev-parse --is-shallow-repository; git rev-list --count HEAD
  git rev-parse ORIG_HEAD; git rev-list --count --left-right ORIG_HEAD...HEAD; echo rc=$?
  git reflog show --date=iso | head -1; git reflog show --date=iso | tail -1'
# same block against root@157.180.90.121 (guerrilla)
```

Both boxes: `is-shallow-repository` → `false`, 5536 commits, deep ranges rc=0.
CP reflog: 648 entries back to `clone: from …` 2026-06-27; guerrilla: 1360 back to
2026-06-29 (`reset: moving to FETCH_HEAD` per deploy). `gc.reflogExpire` unset →
default 90 days, so the CP's clone-era provenance evaporates around 2026-09-25.

## R6 — WARNING: `git fetch --unshallow --dry-run` is NOT a dry run

On git 2.34.1 it downloaded a 15.7 MiB pack and REMOVED `.git/shallow`. Measured
on the CP at 2026-08-09T00:16:22Z: `real 0m6.886s`, commit count 4066 → 5536,
`.git` 264 MB / size-pack 128.06 MiB. Re-derive the attribution with
`ls -lt --time-style=full-iso /opt/barkpark/.git/objects/pack/ | head -3`.
That is also the price of the fix — 7 seconds — and it is already paid on the CP.
The pre-existing shallow-boundary hazard (rc=0 with a truncated count AT the
boundary) is no longer reproducible on that box.
