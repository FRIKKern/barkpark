<!-- doc-tier: cold | canonical-for: none | budget: 400tok -->

# V3 — dispatch_site_event per-alert Repo.get: SAFE-bounded (2026-08-18)

VERDICT: SAFE pattern, cited. NOT a finding. Closes the last open Ecto-efficiency thread.

CLAIM (digest): registry.ex:7464 Enum.each(send_now, dispatch_deployment_failed) → Notifications.dispatch_site_event does Repo.get(Site,id) per alert — batchable N+1?

RE-DERIVATION (origin/main):

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n 'reap_alert_cap'
    # 95:  @reap_alert_cap 25
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '7458,7488p'
    # 7462: {send_now, dropped} = Enum.split(alerts, @reap_alert_cap)
    # 7464: Enum.each(send_now, fn {site_id, reason, identity} -> dispatch_deployment_failed(...) end)
    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '723,726p'
    # 725: %Site{...} when is_binary(team_id) <- Repo.get(Site, id)  (guarded by Repo.uuid_or_nil)

WHY SAFE:
- send_now is HARD-CAPPED at @reap_alert_cap = 25 by Enum.split. The per-item Repo.get loop is bounded at 25 indexed PK lookups per reaper sweep — a constant, not N-in-input.
- The Repo.get is a single-key primary-key lookup, UUID-guarded (Repo.uuid_or_nil) — the known CastError class does NOT apply.
- The authors ALREADY recognized the N-query concern: the DROPPED tail (record_withheld_reap_alerts) is deliberately batched — "One batched lookup, not one per dropped alert — a mass reap is exactly the moment not to fire N queries." The per-item send_now path was consciously left per-call because the cap makes it cheap.
- The fix would land cross-fence in notifications.ex, changing dispatch_site_event's public API to accept a pre-resolved team/name — a cross-fence public-API change to shave a 25-query ceiling on a cron path. Not worth it.

SCENARIO CHECK: no input can push send_now above 25; other callers (transition_deployment_fenced, create_failed_deployment) dispatch a SINGLE event = 1 query, not a loop. No wrong-output / crash path exists.
