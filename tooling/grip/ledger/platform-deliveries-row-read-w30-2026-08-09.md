# platform_deliveries row read — dr-w28-s1 criterion 10 (wave 30, 2026-08-09)

READ PATH USED: **SSH + psql into `cloud-db-1` on 178.105.92.191. NOT HTTP.**
`GET /v1/deliveries` answers **HTTP 401** to an unauthenticated caller (router.ex:3917 is
`require_user_or_pat` + `require_ability("read")`), so no HTTP reader was used and no
fallthrough `note:` was involved in any number below.

## Re-derive the rows

```sh
cat > /tmp/q.sql <<'EOF'
select 'A| '||delivering_run_id||' | '||target||' | '||sha||' | carried='||coalesce(carried::text,'NULL')
     ||' | bs='||coalesce(build_seconds::text,'NULL')||' | prev='||coalesce(previous_sha,'NULL')
     ||' | trans='||coalesce(transition,'NULL')
from platform_deliveries
where delivering_run_id in ('31311406817','31316266628')
order by delivering_run_id, target, sha;
EOF
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -At"' < /tmp/q.sql
```

NOTE the schema: the column is **`delivering_run_id`, a varchar** — not `run_id`, and not an
integer. `where delivering_run_id = 31311406817` fails with
`operator does not exist: character varying = bigint`. Quote the value.

## Re-derive the job-log anchors

```sh
gh run view 31311406817 --log | grep -E 'target='
gh run view 31316266628 --log | grep -E 'target='
```

## Re-derive the carried-set truth check

```sh
git rev-list 8e83b709a4f1db483ea44cc9c16392435e19ba03..fd1182b066bec0bb8864e181b422f2a4cf75a5ad
git rev-list a18cbbc04eff43b3793fb310010d6162f03a0c00..02475d0ecaf41f8fcd464c543a07e1825defc090
git rev-list 4c8314c94a05772fb7c2d19d592fa3536936400c..02475d0ecaf41f8fcd464c543a07e1825defc090
```

Each list is **set-identical** to that (run, target)'s rows. This is the check that turns
"the rows look plausible" into "the recorder's range is provably the true range."

## Which run is "the FIRST post-merge run"

```sh
gh pr view 11203 --json mergedAt          # 2026-08-09T11:34:36Z
gh run list --workflow="Deploy (production)" --limit 12 \
  --json databaseId,createdAt,headSha,conclusion
```

31311147193 (11:34:58Z) and 31311375565 (11:40:31Z) are both **cancelled** and wrote **zero**
rows — confirm by their absence from `select distinct delivering_run_id from platform_deliveries`.
The first post-merge run that recorded anything is **31311406817** (11:41:17Z).
