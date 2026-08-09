# crown-reconcile BEHIND=17/21 is a CLOSED backlog, bounded by the writer's birth

Wave 29 verifier `crown-behind-is-it-live`, re-derived 2026-08-09 ~12:06Z.

## The verdict

`behind=17/21` over 24h. Windowed to 3h (post-writer) it is **behind=0/4**.
The writer (`record-delivery` job, PR #11167) merged **2026-08-09T09:39:44Z**.
Every one of the 17 BEHIND runs was created between 2026-08-08T12:27:30Z and
2026-08-09T08:39:42Z — all *before* the job existed. Their `gh run view --json jobs`
shows no `Record what this run delivered` job at all: not skipped, **absent**.
The BEHIND set ages out of the 24h window on its own at ~2026-08-10T08:40Z.

The live defect is the *other* number: `WRONG: 1 of 28` names
`8e83b709a4f1db483ea44cc9c16392435e19ba03` — the sha the BOX served, written as
the `carried=f` primary by #11203, while run 31311142804's own head sha
`5f3813659` was written `carried=t`. crown-reconcile.sh exempts only `carried`
rows from WRONG (`scripts/crown-reconcile.sh:49-51`, `:449-466`), so #11203's
whole point manufactures a WRONG on every deploy whose box-served sha differs
from its run head sha.

## Re-derivation recipes

```sh
# 0. tree under test
git fetch origin -q && mkdir -p /tmp/w29cr && git archive origin/main | tar -x -C /tmp/w29cr

# 1. the writer's birth (UTC)
TZ=UTC git show -s --format='%H %cd %s' --date=iso-strict \
  67f4a6ab27cdd0cc1bd834d9b5fb35d5d158f2dd

# 2. the 24h verdict (reproduces CI run 31311887504)
cd /tmp/w29cr && CP_HOST=178.105.92.191 DEPLOY_SSH_KEY="$(cat ~/.ssh/barkpark_indx)" \
  bash scripts/crown-reconcile.sh --repo FRIKKern/barkpark --window-hours 24

# 3. THE SPLIT: window to post-writer only -> behind=0/N
cd /tmp/w29cr && CP_HOST=178.105.92.191 DEPLOY_SSH_KEY="$(cat ~/.ssh/barkpark_indx)" \
  bash scripts/crown-reconcile.sh --repo FRIKKern/barkpark --window-hours 3

# 4. per-run: did the recorder job even exist?
for r in 31304047439 31301300597 31306459823 31311142804 31311406817 31311133833; do
  gh run view $r -R FRIKKern/barkpark --json databaseId,createdAt,headSha,conclusion,jobs \
    -q '[(.databaseId|tostring),.createdAt,.headSha[0:9],.conclusion,([.jobs[]|.name+"="+(.conclusion//"null")]|join(";"))]|@tsv'
done

# 5. the crown itself, with the carried flag that decides WRONG
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud \
  -d barkpark_cloud_prod -A -F'|' -c \"select left(sha,9),target,delivering_run_id,inserted_at,serving_since,build_seconds,carried from platform_deliveries order by inserted_at\""
```

## Traps this hit

- `timeout` is absent on this host — drop it, do not assume the command hung.
- Piping crown-reconcile.sh into `tail`/`grep` eats its rc (`RC=0` on a rc=1
  verdict). Read the VERDICT line, never `$?` after a pipe. (Charter: bespoke
  checks lie.)
- `gh run view <id>` with no `-R` resolves the *cwd* repo; run it outside the
  checkout and every id 404s. The slug is `FRIKKern/barkpark`.
- `platform_deliveries` has no `git_sha` column; it is `sha`.
