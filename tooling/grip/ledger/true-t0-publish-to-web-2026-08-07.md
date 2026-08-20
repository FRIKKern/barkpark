# Re-derivation recipe — the TRUE t0 for time-to-web (deploy-reliability wave 11)

Pinned windows (UTC): W24 = [2026-08-06 06:00:00, 2026-08-07 06:00:00);
W7 = [2026-07-31 06:00:00, 2026-08-07 06:00:00). Deployment export runs to
2026-08-07 08:00:00 so a publish at the window edge can still find a successor.

Two databases, two hosts. Clock skew measured < 0.6 s (see step 0).

## 0. Skew

    for h in 157.180.90.121 178.105.92.191; do \
      echo -n "$h "; ssh -i ~/.ssh/barkpark_indx root@$h 'date -u +%s.%N'; done

## 1. Content side (guerrilla, 157.180.90.121, db barkpark_prod)

Publishes of the bound doc_type, and the webhook deliveries they produced:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "sudo -u postgres psql -d barkpark_prod -c \"\\copy (select id,type,mutation,doc_id, to_char(inserted_at,'YYYY-MM-DD HH24:MI:SS.US') ev_at from mutation_events where type='paper' and mutation='publish' and inserted_at >= timestamp '2026-07-31 06:00:00' and inserted_at < timestamp '2026-08-07 06:00:00') to '/tmp/paper_pub.csv' with csv header\""
    scp -i ~/.ssh/barkpark_indx root@157.180.90.121:/tmp/paper_pub.csv .

Webhook fan-out is per SITE, five endpoints, `types={paper}`:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "sudo -u postgres psql -d barkpark_prod -c 'select id,name,types,url,active from webhooks;'"

## 2. Control plane (barkpark-cp, 178.105.92.191, container cloud-db-1)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"\\copy (select d.id,s.name site,d.site_id,d.status,d.trigger,d.source,d.environment,d.content_rev, to_char(d.inserted_at,'YYYY-MM-DD HH24:MI:SS.US') ins_at, to_char(d.became_live_at,'YYYY-MM-DD HH24:MI:SS.US') live_at from deployments d join sites s on s.id=d.site_id where d.inserted_at >= timestamp '2026-07-31 06:00:00' and d.inserted_at < timestamp '2026-08-07 08:00:00') to '/tmp/deps.csv' with csv header\"; docker cp cloud-db-1:/tmp/deps.csv /tmp/deps.csv"
    scp -i ~/.ssh/barkpark_indx root@178.105.92.191:/tmp/deps.csv .

## 3. Join (local)

For each paper publish P and each of the five webhook-bound sites S:

  * ENQUEUE LAG  = min{ d.inserted_at : d.site=S, d.inserted_at >= P } - P
  * TIME TO WEB  = min{ d.became_live_at : d.site=S, d.became_live_at >= P } - P

Bound sites (site_id -> name):

    15684026-93e9-4287-87fe-34a881ae8e6d  astro-search
    31060916-8b2e-40e2-8b5a-3b5c10b0c6c9  search-ember
    7c2025a5-4181-46df-8b00-6151fe3da9d4  search
    d8e9c2c7-df13-4edc-aa0f-4dafa48bd64f  search-capstone
    0cf76788-db52-4f04-a00d-675433796b53  live-auto

Script used: scratchpad `t0.py` / `t0b.py` / `t0c.py` (bisect over sorted
per-site timestamp lists; no imputation, censored pairs counted, never dropped).

## 4. What it returned (2026-08-07)

    ENQUEUE LAG  publish -> first deployment row
      W24  n=720  p50 61s  p95 692s  max 1550s  mean 135s  censored 0
      W7   n=3300 p50 61s  p95 185s  max 1550s  mean  72s  censored 0
    TIME TO WEB  publish -> became_live_at
      W24  n=720  p50 352s  p95 11752s  max 22291s  censored 0
      W7   n=3300 p50 32184s p95 493029s max 541084s censored 0
    ROW-KEYED (inserted_at -> became_live_at), same 5 sites
      W24  n=626  p50 74s   p95 248s   max 1420s
      W7   n=1782 p50 108s  p95 226s   max 1420s

Understatement of the row-keyed clock vs the publish clock: 4.8x at W24 p50,
298x at W7 p50. The p50 enqueue lag of 61 s is the AutoDeployWorker debounce
(`@schedule_in_default 60`, cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex),
so publish -> row is bounded below by the debounce by construction.

## 5. Side observations worth their own re-derivation

Webhook type filter leak (endpoints declare `types={paper}`, received
`type='task'` deliveries until 2026-08-07 03:46:11Z, none after):

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "sudo -u postgres psql -d barkpark_prod -c \"select w.name, e.type, count(*) from webhook_deliveries d join mutation_events e on e.id=d.event_id join webhooks w on w.id=d.endpoint_id where d.inserted_at >= timestamp '2026-08-06 06:00:00' and d.inserted_at < timestamp '2026-08-07 06:00:00' group by 1,2 order by 1,3 desc;\""

`deployments.content_rev` is NOT a document revision: it is
`binary_part(sha256(json([doc_type, published_count, published_events])),0,12)`
probed from the box (`Sites.Deploy.content_rev_probe/2`). It cannot be joined to
`mutation_events.rev` (12 hex chars vs 32) and is shared by every site with the
same bound doc_type.
