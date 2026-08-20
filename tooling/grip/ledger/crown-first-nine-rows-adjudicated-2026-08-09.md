# The crown's first nine rows, adjudicated field by field — 2026-08-09

W28 verifier `v2-crown-rows-and-instance-leg`. Every line below was RUN, not inferred.
Verdict: **8 of 9 rows carry a sha the target never served.** Row 1 is the only corroborated row.

## Re-derivation recipes

### R1 — read all nine rows, expanded

```
printf "SELECT sha, target, previous_sha, transition, serving_since, merged_at, queued_seconds, queued_self_seconds, queued_pickup_seconds, queued_stall_seconds, build_seconds, delivering_run_id, inserted_at FROM platform_deliveries ORDER BY inserted_at;\n" | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -x"'
```

### R2 — what the boxes actually deployed in run 31306459823

```
gh run view --log --job 93227745553 | grep -E 'current=|target=|DONE —'   # cp
gh run view --log --job 93227745560 | grep -E 'current=|target=|HEALTHY'  # instance
```

cp: `current=a95bc7ca9…` / `Already up to date.` / `target=a95bc7ca9…` / `DONE — control plane slot green live at a95bc7ca9`
instance: `current=48a200aa…` / `target=a95bc7ca9…` / `HEALTHY — slot blue live at a95bc7ca9`

### R3 — the instance's durable serving record (D465's ruled source)

```
ssh -i ~/.ssh/barkpark_indx root@guerrilla.barkpark.cloud 'ls -l --time-style=full-iso /opt/barkpark/.instance-deploy-last; cat /opt/barkpark/.instance-deploy-last; git -C /opt/barkpark rev-parse HEAD'
```

`-rw-r--r-- … 2026-08-09 09:48:31.442360825 +0000 /opt/barkpark/.instance-deploy-last` → `a95bc7ca9747cb3d90a361c4d54eb2c068a24e32`; git HEAD identical.
NOTE: `https://guerrilla.barkpark.cloud/health` is NOT a health source — it returns a content-API `not_found` envelope. `/api/schemas` = 200.

### R4 — the recorder's own proof that its row was false

```
gh run view --log --job 93228346355 | grep -E '::warning|-> rollback|-> forward|rows to record|PD_HTTP|recorded 8'
```

```
##[warning]/health reports git_sha=a95bc7ca9747cb3d90a361c4d54eb2c068a24e32, not b977b16adffee068aaf9f3fd7d463647b9bba136 — serving_since would describe a different commit, so it is OMITTED
cp: a95bc7ca9…...b977b16ad… = 2 left / 0 right -> rollback
instance: 48a200aa…...b977b16ad… = 0 left / 7 right -> forward
rows to record: 8
PD_HTTP=200
recorded 8 of 8 row(s) for run 31306459823
```

### R5 — the root cause, one line

```
git show origin/main:.github/workflows/deploy.yml | sed -n '495p'
```
→ `          SHA="$GITHUB_SHA"`

Both deploy scripts pull `origin/main`'s TIP and log `target=`; the recorder records the run's TRIGGERING sha. Run 31306459823's headSha is `b977b16ad` (created 09:40:10Z) while origin/main had already advanced to `a95bc7ca9` by deploy time. The two never reconcile.

### R6 — ancestry (why "rollback" was arithmetically right and semantically false)

```
git rev-list --left-right --count a95bc7ca9747cb3d90a361c4d54eb2c068a24e32...b977b16adffee068aaf9f3fd7d463647b9bba136   # -> 2  0
git log --oneline b977b16adffee068aaf9f3fd7d463647b9bba136..a95bc7ca9747cb3d90a361c4d54eb2c068a24e32
```
The 2 commits delivered by this run and recorded NOWHERE: `a95bc7ca9` (#11173), `142d02de1` (#11172).

### R7 — the sha both boxes serve has zero rows

```
printf "SELECT count(*) FROM platform_deliveries WHERE sha='a95bc7ca9747cb3d90a361c4d54eb2c068a24e32';\n" | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'
```
→ `0`

### R8 — row 1 is the only corroborated row

```
gh run view --log --job $(gh run view 31255918184 --json jobs -q '.jobs[]|select(.name=="control-plane")|.databaseId') | grep -E 'current=|target=|DONE —'
```
→ `target=2e38228b0048901b166d915d222cfc47f6f470d6`, matching the row's `sha`. Its `serving_since` is non-NULL precisely because the recorder's `health_sha = SHA` branch fired.
