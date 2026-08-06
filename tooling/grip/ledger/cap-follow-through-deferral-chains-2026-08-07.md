# Re-derivation recipe — cap follow-through: do capacity deferrals recover or terminally drop?

Wave 7 VERIFY [cap-follow-through]. Control plane = `178.105.92.191`, container `cloud-db-1`.
All queries taken 2026-08-06 ~22:50-22:55Z. `origin/main` = ef77af274.

## 1. Which sites are in a capacity chain, and how deep

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select site_id,status,count(*),min(inserted_at),max(inserted_at) from deployments where failure_reason like '\''%box_at_capacity%'\'' group by 1,2 order by 1\"'"
```

## 2. The interleaved sequence that decides recover-vs-drop

A `live` row between deferrals RESETS the chain (`consecutive_deferrals/2` uses
`Enum.take_while` over head-of-stream rows of the SAME cause). Run this to see the resets:

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select site_id, status, inserted_at from deployments where site_id in (select distinct site_id from deployments where failure_reason like '\''%box_at_capacity%'\'') and inserted_at > now() - interval '\''1 hour'\'' order by site_id, inserted_at\"'"
```

## 3. Has the terminal arm ever fired?

The terminal drop writes `— and it has now refused N rebuilds in a row for this site, …`:

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select site_id,status,inserted_at,left(failure_reason,180) from deployments where failure_reason like '\''%in a row%'\'' order by inserted_at desc\"'"
```

## 4. Pending-job snapshot (the coalescing question)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select now(), state, args->>'\''site_id'\'', scheduled_at from oban_jobs where worker like '\''%AutoDeploy%'\'' and state in ('\''available'\'','\''scheduled'\'','\''executing'\'','\''retryable'\'') order by scheduled_at\"'"
```

Note the trap: `:executing` is DELIBERATELY dropped from `@unique` states
(auto_deploy_worker.ex), so `executing` rows here are NOT evidence about coalescing.
Several of them are multi-day zombies; check age with:

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select id,state,attempted_at,now()-attempted_at as age from oban_jobs where state='\''executing'\'' order by attempted_at\"'"
```

## 5. Code anchors (read from origin/main, never the worktree — it is 500+ commits behind)

```
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1150,1310p'
git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | sed -n '255,325p'
git grep -rn "consecutive_deferrals\|in a row" origin/main -- cloud/lib internal/
```

Constants: `@max_consecutive_deferrals 6`, `@max_consecutive_capacity_deferrals 12`,
`@deferral_scan_depth 14` — deploy.ex:1153/1162/1166.
