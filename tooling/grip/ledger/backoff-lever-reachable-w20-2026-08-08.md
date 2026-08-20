# backoff-lever-reachable — re-derivation recipe (deploy-reliability W20)

Row: `dr-w20-refusal-backoff-depth-derived`. Window pinned `2026-08-05 21:27:11`
(full) and `2026-08-07 10:12:35` (post `deferral_cause`-writer boundary).

## 1. The unique-conflict question is definitional, not empirical

`git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | sed -n '85,140p'`

`@unique [keys: [:site_id], states: [:available, :scheduled], period: 300]` —
an enqueue that HITS the constraint conflicts with an `:available`/`:scheduled`
sibling **by construction**. `:executing` cannot be the conflicting state.

## 2. The measurable form: the `:executing` sliver

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select round(percentile_cont(0.5) within group (order by extract(epoch from (scheduled_at-inserted_at)))::numeric,2) p50_window, round(percentile_cont(0.5) within group (order by extract(epoch from (attempted_at-scheduled_at)))::numeric,2) p50_avail, round(percentile_cont(0.5) within group (order by extract(epoch from (completed_at-attempted_at)))::numeric,2) p50_exec from oban_jobs where worker like '%AutoDeployWorker%' and inserted_at >= '2026-08-05 21:27:11'\""

60.00 / 0.73 / 0.30 → cycle ≈ 61.0 s, of which `:executing` is 0.49 %.
The job spawns a supervised driver and returns; it does NOT hold `:executing`
during the box build.

## 3. Cadence vs deferral chain — the decomposition that decides the lever

    ... -c \"with r as (select content_rev, site_id, count(*) rows, count(*) filter (where status='deferred') def from deployments where inserted_at >= '2026-08-05 21:27:11' and content_rev is not null group by 1,2) select (def>0) had_deferral, count(*) pairs, round(avg(rows),2) rows_per_site_per_rev from r group by 1\"

no deferral → 1.26 rows/site/rev (n=856); with deferral → 4.04 (n=818).
Debounce cadence alone is near the floor of 1. The amplification lives in the
deferral re-queue chain (`Deploy` → `requeue_rebuild/1` →
`AutoDeployWorker.enqueue/1`, `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1330,1382p'`).

## 4. Demand vs supply

Supply: 1 build slot, p50 deployment `updated_at-inserted_at` 63.2 s → ~0.95
builds/min. Demand at W=60 over 5 auto-publishing sites → ~5 builds/min.
~5.3x oversubscribed; measured deferral share 68.3 % post-boundary.

## 5. Config truth

`AUTODEPLOY_DEBOUNCE_S` is UNSET in `cloud-control_plane_blue-1` → the live
window is `@schedule_in_default 60`, corroborated by p50_window = 60.00.
