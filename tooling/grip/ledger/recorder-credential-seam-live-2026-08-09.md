# Re-derivation recipes — recorder credential seam, wave 27 verify (2026-08-09)

Ground: origin/main da47f61aa. All commands run 2026-08-09 from the primary checkout host.

## R1 — Are DEPLOY_SSH_KEY / CP_HOST / GUERRILLA_HOST repo or environment secrets?

```
gh secret list
gh api repos/:owner/:repo/environments --jq '.environments[].name'
for e in Production Preview "Production – barkpark"; do
  gh api "repos/:owner/:repo/environments/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$e")/secrets" --jq '.total_count'
done
```

Expected: all three appear in the REPO list (created 2026-06-30). Every environment reports
`total_count: 0`. There is NO lowercase `production` environment — the six are Preview,
Preview – barkpark, Preview – demo, Production, Production – barkpark, Production – demo;
`environment: production` in deploy.yml matches `Production` case-insensitively.

## R2 — `gh secret list --env <name>` empty-vs-missing (it does NOT silently lie)

```
gh secret list --env production; echo "rc=$?"        # empty output, rc=0  → env exists, 0 secrets
gh secret list --env doesnotexist123; echo "rc=$?"   # HTTP 404, rc=1      → env does not exist
```

The empty result is distinguishable from absence. Recorded because the opposite was assumed.

## R3 — Is the SSH + `docker exec printenv WORKER_TOKEN` seam live TODAY?

```
ssh -o BatchMode=yes -o ConnectTimeout=20 -i ~/.ssh/barkpark_indx root@barkpark.cloud '
  c=$(docker ps -q --filter ancestor=cloud-control_plane:latest | head -1); echo CONTAINER=$c
  WT=$(docker exec "$c" printenv WORKER_TOKEN)
  [ -n "$WT" ] && echo TOKEN_PRESENT_LEN=${#WT} || echo TOKEN_MISSING
  curl -s -o /dev/null -w "noauth=%{http_code}\n" -X POST https://barkpark.cloud/v1/internal/platform-deliveries
  curl -s -o /dev/null -w "badbody=%{http_code}\n" -X POST -H "Authorization: Bearer $WT" \
    -H "Content-Type: application/json" -d "{}" https://barkpark.cloud/v1/internal/platform-deliveries'
```

Expected: CONTAINER non-empty, TOKEN_PRESENT_LEN=64, noauth=401, badbody=422.
422 (`deliveries_required`, router.ex:6666) is reached only AFTER `Auth.require_worker` does not
halt — so 422 is the auth PASS proof; 401 is the refusal.

## R4 — Blue/green did not break the ancestor filter, and why

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker ps -a --format "{{.Names}} {{.Image}} {{.Status}}"; docker ps -q --filter ancestor=cloud-control_plane:latest | wc -l'
```

Expected: exactly 1 running match. The container is now `cloud-control_plane_green-1` (name changed);
the IMAGE TAG did not. Retired slots hold bare image IDs (`be2af9e48a80`), not the `:latest` tag, so
they cannot match. `deploy/cp-deploy.sh:39` tags the outgoing image `:rollback` and `:91` restores it
to `:latest` on abort — so the abort path also leaves exactly one `:latest` match running.

## R5 — Public reachability of the internal route (from off-box)

```
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://barkpark.cloud/v1/internal/platform-deliveries
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer deadbeef" \
  -H "Content-Type: application/json" -d '{}' https://barkpark.cloud/v1/internal/platform-deliveries
```

Expected: 401 and 401. Confirms D425's note that a runner-side POST is technically possible but
would need WORKER_TOKEN as a NEW GitHub secret.

## R6 — Crown state: table shape + the single hand-posted row

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -x -c \
   "select * from platform_deliveries"'
```

DB user is `barkpark_cloud`, db `barkpark_cloud_prod` (derive from
`docker exec cloud-control_plane_green-1 printenv DATABASE_URL`; `postgres`/`root`/`barkpark` all
fail with `role does not exist`). Expected: 1 row, sha 2e38228b0048…, delivering_run_id 31255918184,
target cp, previous_sha and transition EMPTY.

## R7 — The guerrilla box has no docker

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'hostname; docker ps'
```

Expected: `guerrilla` then `bash: line 1: docker: command not found`. The token seam exists ONLY on
the CP; a recorder recording `target=instance` must still take its token from CP_HOST.
