# Deploy fan-out & capacity — re-derivation recipes (2026-08-05)

Verifier lane `fanout-capacity`, wave `deploy-truth-wave-1-2026-08-05`.
All commands are read-only. `CLOUD_TOKEN` = `cloud_token` in `~/.config/barkpark/config.json`.

## 1. Site bindings (13 sites, one dataset)

```bash
export CLOUD_TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
for S in $(curl -s -H "Authorization: Bearer $CLOUD_TOKEN" https://api.barkpark.cloud/v1/sites \
  | python3 -c "import json,sys;[print(s['id']) for s in json.load(sys.stdin)['sites']]"); do
  curl -s -H "Authorization: Bearer $CLOUD_TOKEN" "https://api.barkpark.cloud/v1/sites/$S" \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['site'];print(d['slug'],d.get('workspace'),d.get('project'),d.get('dataset'),d.get('doc_type'),d.get('framework'),d.get('template'))"
done
```

## 2. The real fan-out is 5, not 12 (content-hooked sites only)

```bash
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select s.slug, d.trigger, count(*) from deployments d join sites s on s.id=d.site_id group by 1,2 order by 1,3 desc;\""
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select slug,(content_webhook_secret_encrypted is not null) hook from sites order by 1;\""
```

## 3. 90% of every deploy trigger is `task` traffic (the bp ledger)

```bash
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select e.type, count(*) deliveries, count(distinct e.id) events from webhook_deliveries d join mutation_events e on e.id=d.event_id where d.inserted_at > '2026-07-26' group by 1 order by 2 desc;\""
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select name,types,events from webhooks;\""
```

`types = {}` on all five `site-autodeploy-*` rows = no doc-type filter.
Dispatcher DOES honour it: `git show origin/main:api/lib/barkpark/webhooks.ex | sed -n 197p`.
Registrar omits it: `git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n 4505,4515p`.

## 4. Debounce-window counterfactual (all types vs paper-only)

```bash
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod \
 -c \"select count(distinct date_trunc('minute',inserted_at)) from mutation_events where inserted_at>'2026-07-26' and dataset='production';\" \
 -c \"select count(distinct date_trunc('minute',inserted_at)) from mutation_events where inserted_at>'2026-07-26' and dataset='production' and type='paper';\""
```

## 5. Contention curve (build duration vs hourly deploy volume)

```bash
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
with h as (select date_trunc('hour',inserted_at) hh, count(*) starts from deployments group by 1)
select s.slug, case when h.starts<=20 then 'LOW<=20/hr' when h.starts<=120 then 'MID' else 'HIGH>120/hr' end band,
 count(*) n, round(percentile_cont(0.5) within group (order by extract(epoch from (d.became_live_at-d.inserted_at)))::numeric,1) p50_s,
 round(percentile_cont(0.9) within group (order by extract(epoch from (d.became_live_at-d.inserted_at)))::numeric,1) p90_s
from deployments d join sites s on s.id=d.site_id join h on h.hh=date_trunc('hour',d.inserted_at)
where d.status='live' and d.became_live_at>d.inserted_at group by 1,2 order by 1,2;\""
```

## 6. Debounce override on the CONTROL PLANE (there is none)

```bash
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'for c in $(docker ps --format "{{.Names}}"); do echo "== $c"; docker exec $c env | grep -i debounce; done'
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'sed -n "95,120p" /opt/barkpark/cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex'
```

## 7. Full-scale taxonomy (raw failure_reason, 26,423 rows)

```bash
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select count(*) filter (where failure_reason like '%409%') n409, count(*) filter (where failure_reason like '%500%') n500, count(*) filter (where failure_reason like '%bp-doc-id%') ndocid, count(*) filter (where failure_reason like '%403%') n403, count(*) total from deployments where status='failed';\""
```
