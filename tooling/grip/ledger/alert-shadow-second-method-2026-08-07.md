# Re-derivation recipe — alert shadow, second method (dr-w15 verifier V12)

Host: `178.105.92.191`, container `cloud-db-1`, db `barkpark_cloud_prod`.
DB clock at capture: `2026-08-07 14:40:57Z`.

## Gotcha that broke the assigned command

`docker exec -i cloud-db-1 psql ... -f /tmp/v12.sql` fails with
`psql: error: /tmp/v12.sql: No such file or directory` — `-f` resolves INSIDE the
container, and `scp` puts the file on the HOST. Pipe stdin instead:

```sh
scp -i ~/.ssh/barkpark_indx q.sql root@178.105.92.191:/tmp/q.sql
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod < /tmp/q.sql'
```

## R1 — deployments carries NO distinct terminal timestamp

`\d deployments` time columns: `claimed_at`, `became_live_at`, `inserted_at`,
`updated_at`, `coalesced_last_at`. `became_live_at` is live-only. So there is no
finished_at for a failure. Drift is real: median `updated_at - inserted_at` on
failed rows since 08-05 is 65.2 s, max 2269.9 s, and 62 of 1513 rows (4.1%) land
in a different hour than they were inserted in.

## R2 — the second method: join on `inserted_at`, which cannot drift

`deployments.inserted_at` is set at row creation and never rewritten by
`record_stage/2`. Daily join over the whole life of the email rail:

```sql
WITH d AS (SELECT date_trunc('day',inserted_at) h, count(*) f FROM deployments
           WHERE status='failed' GROUP BY 1),
     n AS (SELECT date_trunc('day',inserted_at) h, count(*) e FROM notification_deliveries
           WHERE event='deployment_failed' GROUP BY 1)
SELECT coalesce(d.h,n.h) AS dt, coalesce(d.f,0) AS failed_by_inserted,
       coalesce(n.e,0) AS emails
FROM d FULL OUTER JOIN n ON d.h=n.h ORDER BY 1;
```

## R3 — suppressed=0, by enumeration not by filter

```sql
SELECT event, status, count(*) FROM notification_deliveries GROUP BY 1,2 ORDER BY 3 DESC;
```
Enumerating every (event,status) pair that exists is strictly stronger than
`WHERE status='suppressed'` returning 0 — it proves the value has never been
written, rather than proving a filter matched nothing.

## R4 — a per-row join is IMPOSSIBLE

`\d notification_deliveries` columns: id, team_id, recipient, event, channel,
kind, status, attempts, last_error, inserted_at, updated_at, http_status.
No deployment_id, no site_id, no payload. Any 1:1 claim is aggregate-only,
forever. Record this as a schema limitation, not an analysis choice.

## R5 — worktree staleness trap

`git rev-list --count HEAD..origin/main` = 594 at capture. `git grep` in the
working tree MISSES `deferral_cause`, `DeployLedger`, and the whole deferred
taxonomy. Always `git grep <pat> origin/main -- <path>`.
Note `cloud/lib/barkpark_cloud/deploy_ledger.ex` — NOT under `sites/`.
