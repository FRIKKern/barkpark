# v9-reconciler-reachability — re-derivation recipes (2026-08-07, origin/main 95642c550)

## R1 — the reconciler has NO production caller (test-only)
```
git grep -n 'ensure_content_webhook' origin/main -- cloud/ internal/ api/ deploy/ scripts/
```
Expect: definition + private `do_` at cloud/lib/barkpark_cloud/registry.ex:4592/4632/4633/4636/4643,
and callers ONLY in cloud/test/barkpark_cloud/registry_test.exs and
cloud/test/barkpark_cloud/sites/content_publish_receiver_test.exs. Zero mix task, zero
release verb, zero CLI verb, zero ops script.

## R2 — cloud has only two mix tasks, and Release exports only migrate/rollback
```
git ls-tree -r --name-only origin/main | grep -E '^cloud/lib/(mix|barkpark_cloud/release)'
git show origin/main:cloud/lib/barkpark_cloud/release.ex | grep -nE '^\s*def '
```

## R3 — the five live rows still carry types={} (box DB)
```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  "sudo -u postgres psql -qAt -d barkpark_prod -c \"select name, types, active from webhooks where name like 'site-autodeploy%';\""
```

## R4 — same fact through the SANCTIONED proxy path (proves the trigger is reachable)
```
bp cloud webhook list guerrilla -o json
```
Read-only. The write twin is `bp cloud webhook edit guerrilla <webhook-id> --types paper`
(internal/cli/cloud_webhook_cmd.go:194-232; PUT proxy at router.ex:91).

## R5 — the REAL doc_type delivery split (correct join; there is no webhook_events table)
`webhook_deliveries.event_id` (bigint) -> `mutation_events.id`; the type column is
`mutation_events.type`, NOT `doc_type`. `webhook_deliveries.endpoint_id` (uuid) -> `webhooks.id`.
```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -qAt -d barkpark_prod -c \"
select me.type, count(*), round(100.0*count(*)/sum(count(*)) over (),1)||'%'
from webhook_deliveries d
join mutation_events me on me.id = d.event_id
join webhooks w on w.id = d.endpoint_id
where w.name like 'site-autodeploy%'
group by 1 order by 2 desc limit 10;\""
```
All-time (2026-07-14 -> 2026-08-07): task 96480 (90.3%), paper 9829 (9.2%), tag 262 (0.2%).
1 of 106904 rows has no matching event.

## R6 — projected cut, 6 h window, per endpoint
```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -qAt -d barkpark_prod -c \"
select count(*) total, count(*) filter (where me.type='paper') paper_only,
 round(count(*)/6.0/5.0,1) all_per_hr_per_ep,
 round(count(*) filter (where me.type='paper')/6.0/5.0,1) paper_per_hr_per_ep,
 round(100.0*(count(*)-count(*) filter (where me.type='paper'))/count(*),1) pct_cut
from webhook_deliveries d join mutation_events me on me.id=d.event_id
join webhooks w on w.id=d.endpoint_id
where w.name like 'site-autodeploy%' and d.inserted_at > now() - interval '6 hours';\""
```

## R7 — every one of the five sites has doc_type='paper' (so the filter is non-empty)
```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec cloud-db-1 psql -qAt -U barkpark_cloud -d barkpark_cloud_prod -c \"select id, name, coalesce(doc_type,'<NULL>'), kind, content_webhook_secret_encrypted is not null from sites order by name;\""
```

## R8 — the CP release rpc channel works (read-only probe; do NOT run the mutating form here)
```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc 'IO.inspect(function_exported?(BarkparkCloud.Registry, :ensure_content_webhook, 2))'"
```
Expect `true`.
