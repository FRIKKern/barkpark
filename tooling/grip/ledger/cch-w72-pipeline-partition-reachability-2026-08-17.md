<!-- doc-tier: cold | canonical-for: cch-w72-pipeline-partition-rederivation | budget: 2000tok -->
# cch-w72 pipeline-partition reachability re-derivation

Verifier: pipeline-partition (wave 72). All reads from `origin/main`. Router = `cloud/lib/barkpark_cloud/web/router.ex`, console = `cloud/priv/static/app.js`.

## Denominator dumps
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/router.ex
    git show origin/main:cloud/priv/static/app.js > /tmp/app.js

## Per-code gate walk (route macro + first Auth.require_ / with_team_site in body)
    for L in <code-line>; do
      awk -v t=$L 'NR<=t && /^  (get|post|put|patch|delete)[ (]/ {r=NR": "$0} END{print r}' /tmp/router.ex
      awk -v t=$L '/^  (get|post|put|patch|delete)[ (]/ {s=NR} NR>=s&&NR<=t&&(/Auth\.require_/||/with_team_site/){g=NR": "$0} END{print g}' /tmp/router.ex
    done
Helper-resident codes (13xxx / 9xxx): find enclosing `defp` then its caller —
    grep -n '<helper>(' /tmp/router.ex   # exclude the "defp <helper>" definition line

## Console-caller presence (reachability)
    grep -nc 'push-relay' /tmp/app.js            # 0  → instance_refused no console caller
    grep -n  '/artifact' /tmp/app.js             # empty → artifact chain CLI-only
    grep -nE '/domains"|sites/.*domains' /tmp/app.js   # empty → POST /v1/sites/:id/domains CLI-only
    grep -nc '/v1/internal\|/v1/builder' /tmp/app.js   # 0  → all 33 require_worker routes unreachable
    grep -nE 'api\("DELETE".*app-token' /tmp/app.js    # empty → DELETE app-token (instance_rate_limited) no console caller
    grep -nE 'POST", "/v1/resurrect' /tmp/app.js       # 2306 → resurrect reachable

## Worker-only mass (33 routes / 20 distinct codes)
    python3: iterate route macros, gate = first `conn = Auth.require_(\w+)` in body,
    collect `error: "..."` where gate=='worker'.  (script in verifier transcript)

## Key gate map (line → route → gate → console class)
    12011/12029/12045/12100 cloudflare_* → deploy_static_site ⇐ POST /v1/sites/:id/deploy (ability write) BUT app.js never sends via=cloudflare → CLI-only
    12143 instance_not_live, 12212 deploy_not_started → deploy_static_site, ability write → NON-ADMIN console (detail dropped by friendly fallback)
    13923 deploy_not_started → start_prebuilt_deploy ⇐ POST .../artifact → CLI-only
    3220 instance_refused → POST /v1/barkparks/:id/push-relay, require_team_admin, no console caller → no caller
    9197 live_twin / 9308 enqueue_failed → resurrect ⇐ POST /v1/resurrect, require_user → NON-ADMIN console (generic fallback)
    7605 domain_required / 7633 domain_taken → POST /v1/sites/:id/domains (with_team_site :session), no console caller → CLI-only
    4215 domain_required (+invalid_domain, domain_not_pointed) → POST /v1/barkparks/:id/domain, require_primary_team_admin, app.js 7912 → ADMIN console; ALL 422≠no_team collapse to one false sentence (flagship cch-w40-bl-attach-domain-422)
    13260 instance_rate_limited → revoke_app_token_on_instance ⇐ DELETE /v1/barkparks/:id/app-token, require_user, no console caller → no caller
    4718 github_error → GET /v1/github/repos, require_user, app.js 14513 → NON-ADMIN console
    4911 github_error → POST /v1/github/repos, require_team_admin, app.js 20159 → ADMIN console
    13315 repo_full_name_required / 13363 repo_not_in_installation / 13366 github_error → connect_site_github ⇐ POST /v1/sites/:id/github/connect, require_team_admin, app.js 14586 → ADMIN console
    operator codes (invalid_window/read_failed/unavailable/no_team) → /v1/operator/*, require_platform_operator, app.js OPERATOR_* section → ADMIN console (platform-operator; PLATFORM_ADMIN_EMAILS unset on prod → dark)
    require_agent family (illegal_transition/no_pending/stale_epoch/observed_epoch_required/worker_id_required/invalid/not_found) → /v1/agent* + builder transition, agent token → UNREACHABLE from browser session
