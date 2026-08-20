# w28 v5 — abandonment alert + classification (re-derivation recipes)

Run 2026-08-09 ~10:00–10:15Z against cloud-db-1 (178.105.92.191) and `git show origin/main`
(a95bc7ca9 at the time of the wave brief; local checkout was 221 commits behind, so every
code read is `git show origin/main:<path>`, never the worktree).

## (a) Do the 7 abandonment rows alert? YES — 7/7, within 1.3s

`notification_deliveries` has NO `deployment_id` column (`\d notification_deliveries`), so the
brief's literal join is impossible. Correlate through `sites.team_id` + a 5s lateral window:

```
printf '%s\n' "SELECT d.id, d.inserted_at AS dep_at, n.id AS notif_id, n.event, n.status, n.channel, n.inserted_at AS notif_at, round(extract(epoch from (n.inserted_at - d.inserted_at))::numeric,3) AS lag_s FROM deployments d JOIN sites s ON s.id=d.site_id LEFT JOIN LATERAL (SELECT * FROM notification_deliveries nd WHERE nd.team_id=s.team_id AND nd.event='deployment_failed' AND nd.inserted_at BETWEEN d.inserted_at AND d.inserted_at + interval '5 seconds' ORDER BY nd.inserted_at LIMIT 1) n ON true WHERE d.failure_reason LIKE '%rebuilds in a row for this site%' ORDER BY d.inserted_at;" | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'
```

Sanity totals (so an empty result would be provably empty):
`SELECT count(*) FROM notification_deliveries;` -> 3042.
`SELECT event, count(*) FROM notification_deliveries GROUP BY 1;` -> deployment_failed 2318.

## (b) Classification of the 7 real rows

The local checkout has no `cloud/lib/barkpark_cloud/deploy_ledger.ex` (221 behind) and no
`deploy_ledger_test.exs`, so the brief's `mix test cloud/test/.../deploy_ledger_test.exs`
cannot run here. Instead compile origin/main's module standalone against the existing
test-env ebin paths and feed it the LIVE strings:

```
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex > /tmp/deploy_ledger.ex
# export rows: SELECT d.id||E'\t'||coalesce(d.stage,'NULL')||E'\t'||replace(d.failure_reason,E'\n',' ')
#   FROM deployments d WHERE d.failure_reason LIKE '%rebuilds in a row for this site%' ORDER BY d.inserted_at;  (psql -At)
# script: Enum.each(Path.wildcard(".../cloud/_build/test/lib/*/ebin"), &Code.prepend_path/1)
#         Code.compile_file("/tmp/deploy_ledger.ex"); DeployLedger.classify(stage, reason)
cd /Volumes/SATECHI/github/barkpark/cloud && MIX_ENV=test elixir /tmp/run_classify.exs
```

Result: 1x ABANDONED_BOX_STUCK (already_running, 6 refusals, 08-05) + 6x ABANDONED_AT_CAPACITY
(box_at_capacity, 12 refusals, 08-07). ZERO UNCLASSIFIED.

## Whole-failed-corpus census through the same classifier

Export `count(*), stage, failure_reason` grouped for `status='failed'` (1,344 distinct shapes,
18,641 rows) and classify locally. Live UNCLASSIFIED = 8 rows / 6 shapes; PROCESS_DIED = 40
(38 BARE + 2 with detail, matching the SQL split); ABANDONED_* = 7.

## What this settles

- "No alert" is FALSE: the abandonment rides the generic `deployment_failed` edge
  (registry.ex `maybe_dispatch_deployment_failed/2`), and `FailureCopy.humanize/1` is the
  IDENTITY on these strings, so the full "refused N rebuilds in a row" prose is in the body.
- What is missing is a DISTINCT event/subject + a counter + reach: `ABANDONED_AT_CAPACITY`
  appears in exactly 2 code files repo-wide (`git grep -l ABANDONED_AT_CAPACITY origin/main`).
