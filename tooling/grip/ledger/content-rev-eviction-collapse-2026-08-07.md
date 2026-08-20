# content_rev eviction + collapse — re-derivation recipe (2026-08-07, deploy-reliability wave 11)

Claim under test: `published_events/2` (`cloud/lib/barkpark_cloud/sites/deploy.ex`) filters a
DATASET-WIDE, ALL-TYPES last-50 mutation window down to one `doc_type`, so churn of any other
type moves `content_rev` with zero publishes of the bound type — contradicting the function's
own docstring ("a draft edit or another type's churn cannot move it").

VERDICT: CONFIRMED, and it is worse than filed — eviction both INFLATES and COLLAPSES the
revision key, and the collapse is the entire source of revision-keyed latency inflation.

## 1. The window is dataset-wide and all-types (code)

    git show origin/main:api/lib/barkpark/content/analytics.ex | sed -n '86,107p'
    git show origin/main:api/lib/barkpark_web/controllers/analytics_controller.ex
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '466,540p'

`recent_activity/2`: `MutationEvent` scoped to dataset + workspace/project only, `order_by
desc: inserted_at`, `limit ^limit` (default 50). No type predicate. The controller passes only
`scope_opts(conn)` — never `:limit` — so the wire window is exactly 50 events, all types.

## 2. The window composition, live (guerrilla content DB)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select type, count(*) from (select type from mutation_events where dataset='production' order by inserted_at desc limit 50) w group by 1 order by 2 desc;\""

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select type, count(*) ev_7d, round(count(*)/168.0,1) per_hour from mutation_events where dataset='production' and inserted_at >= now()-interval '7 days' group by 1 order by 2 desc limit 10;\""

## 3. The eviction, demonstrated on history (no publish between two samples)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"
    with p as (select inserted_at as ts from mutation_events where dataset='production' and type='paper' and doc_id not like 'drafts.%' and mutation='publish' and inserted_at < now()-interval '3 hours' order by inserted_at desc limit 1)
    select lbl, ts, proj_events, proj_hash from (
     select 'T1' as lbl, (select ts from p)+interval '1 second' as ts union all
     select 'T2', (select ts from p)+interval '20 minutes' union all
     select 'T3', (select ts from p)+interval '60 minutes') x,
    lateral (select count(*) filter (where type='paper' and doc_id not like 'drafts.%') as proj_events,
      coalesce(md5(string_agg(doc_id||'|'||mutation||'|'||inserted_at, ',' order by inserted_at desc) filter (where type='paper' and doc_id not like 'drafts.%')),'EMPTY') as proj_hash
      from (select * from mutation_events where dataset='production' and inserted_at <= x.ts order by inserted_at desc limit 50) w) agg order by lbl;\""

Reproduces the projection `published_events/2` hashes, at three offsets from one real publish.
T1 -> 1 event; T2 (+20m, zero publishes between) -> 0 events / EMPTY. Hash moved, nobody published.

## 4. Denominator inflation (cloud CP DB, 24h)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select trigger, count(*) rows, count(distinct content_rev) revs from deployments where inserted_at >= now()-interval '24 hours' group by 1 order by 2 desc;\""

Compare `revs` against published, non-draft `paper` mutation events in the SAME 24h:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select type, mutation, count(*) from mutation_events where dataset='production' and inserted_at >= now()-interval '24 hours' and doc_id not like 'drafts.%' and type in ('paper','post') group by 1,2 order by 3 desc;\""

A rev can only change when the projection changes; the projection's only inputs are the
published count of the bound type and the in-window events of that type. Distinct revs in
excess of publishes are eviction artifacts.

## 5. Collapse — the load-bearing half

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select count(*) site_rev_groups, count(*) filter (where n>1) reused, round(max(span_s)) max_span_s from (select site_id, content_rev, count(*) n, extract(epoch from (max(inserted_at)-min(inserted_at))) span_s from deployments where inserted_at >= now()-interval '7 days' and content_rev is not null group by 1,2) g;\""

An EMPTY projection with an unchanged published count is a CONSTANT rev, so distinct content
states hash to the same key. The latency consequence — run all three and compare:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"
    with g as (select site_id, content_rev, count(*) n, min(inserted_at) t0, min(became_live_at) t1 from deployments where inserted_at >= now()-interval '7 days' and content_rev is not null group by 1,2)
    select case when n=1 then 'singleton rev' else 'collapsed rev (n>1)' end k, count(*) groups, count(t1) delivered,
     round(percentile_cont(0.5) within group (order by extract(epoch from (t1-t0)))) p50,
     round(percentile_cont(0.95) within group (order by extract(epoch from (t1-t0)))) p95
    from g group by 1 union all
    select 'ALL revs', count(*), count(t1), round(percentile_cont(0.5) within group (order by extract(epoch from (t1-t0)))), round(percentile_cont(0.95) within group (order by extract(epoch from (t1-t0)))) from g;\""

If the singleton subset matches the per-attempt distribution while the collapsed subset does
not, the revision-keyed vital is measuring this bug, not the fleet.

## 6. The one clean exclusion, sized

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select count(distinct content_rev) revs_only_template from deployments d where inserted_at >= now()-interval '7 days' and trigger='template-auto' and content_rev is not null and not exists (select 1 from deployments e where e.content_rev=d.content_rev and e.trigger<>'template-auto' and e.inserted_at >= now()-interval '7 days');\""

## 7. Adjacent state to re-check before quoting any 7d number

The box-side `types` doc-type filter on the per-site autodeploy webhook HAS landed
(`Registry.ensure_content_webhook/2` -> `content_webhook_types(site)`); confirm what guerrilla
actually carries, because any 7-day window may straddle the change:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -c \"select name, types, active from webhooks where name like 'site-autodeploy-%' order by name;\""
