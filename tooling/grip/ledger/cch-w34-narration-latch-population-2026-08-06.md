# cch-w34 — narration-latch population: re-derivation recipes (2026-08-06)

Verifier: narration-latch-population. All numbers below are L1 (production control-plane
DB, `178.105.92.191`, `cloud-db-1` / `barkpark_cloud_prod`) or L2 (`git show origin/main:`).

## R1 — terminal rows whose LAST console entry is still mid-stage (the latch population)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT status AS row_status, console[array_length(console,1)]->>'status' AS last_entry_status, console[array_length(console,1)]->>'stage' AS last_stage, count(*) FROM deployments WHERE status IN ('live','failed','deferred') AND coalesce(array_length(console,1),0)>0 GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 25\""
```

2026-08-06: failed/running/BUILD 1614 · failed/running/HEALTH 1392 · failed/running/STAGE 2 ·
failed/running/PLAN 1 = **3009**. Plus 25 failed / 23 live with a NULL last_entry_status.

## R2 — the partition is a pure column predicate (no new field)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT jsonb_object_keys(console[array_length(console,1)]) k, count(*) FROM deployments WHERE coalesce(array_length(console,1),0)>0 GROUP BY 1 ORDER BY 2 DESC\""
```

at/line 17666 · stage/detail/status 17618. The 48-row gap is exactly the off-box
`Registry.append_deployment_console/2` population (`{line, at}` + optional
`truncated_from`); every status-bearing entry comes from
`Sites.Deploy.record_stage/2`.

## R3 — the reaper is NOT the author of the latch population

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT status,(console[array_length(console,1)]->>'line') AS last_line, count(*) FROM deployments WHERE failure_reason IN ('exceeded max deploy claim attempts (stale builder lease)','instance unreachable — deploy could not be delivered; check instance health') GROUP BY 1,2 ORDER BY 3 DESC\""
```

22 rows total, ALL ending on a terminal `BUILD failed — …` line; 0 rows carry
`@instance_unreachable_reason`. The reaper contributes **0 of 3009**.

## R4 — the builder-prefix detector's whole reachable population

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT status, split_part(console[array_length(console,1)]->>'line',':',1) AS prefix, count(*) FROM deployments WHERE coalesce(array_length(console,1),0)>0 AND NOT (console[array_length(console,1)] ? 'status') GROUP BY 1,2 ORDER BY 3 DESC\""
```

failed/`failed` 24 · live/`activate` 23 · failed/`activate` 1. 48 rows, 100 % terminal
narrations. `git grep -n '"failed: ' origin/main -- internal cloud` → ONE hit
(`internal/builder/builder.go:142`), no test. `activate: build complete` is asserted at
`internal/builder/builder_test.go:857`.

## R5 — the s3 comment's own premise, measured over ALL entries

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT (e ? 'status') AS has_status, count(*) FROM deployments d, unnest(d.console) e GROUP BY 1\""
```

t 107371 / f 4135 → 96.3 % of console entries DO carry a status.

## R6 — empty-console terminal rows

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT status, stage, source, left(coalesce(failure_reason,'(null)'),70) AS reason, count(*) FROM deployments WHERE coalesce(array_length(console,1),0)=0 GROUP BY 1,2,3,4 ORDER BY 5 DESC LIMIT 20\""
```

failed 9594 · deferred 316; every row has a non-null `failure_reason`, 13/13 groups at
`stage = PLAN` (or NULL) — pre-console dispatch refusals, not lost narration.

## R7 — provision-side empty console on a TERMINAL job

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT status, coalesce(array_length(console,1),0)=0 AS empty_console, count(*) FROM provision_jobs GROUP BY 1,2 ORDER BY 3 DESC\""
```

succeeded/empty 3 · failed/empty 1 → `consoleTail` (app.js:15245) renders
"No console output yet." on 4 terminal jobs.

## R8 — harness

```
node /Volumes/SATECHI/github/barkpark/cloud/priv/static/__app.test.mjs 2>&1 | tail -5
```
`# fail 0 … # duration_ms 136.8` on origin/main-equivalent worktree.
