# cch-w73 — independent second review: per-emit-site disposition table (2026-08-17)

Re-derived on origin/main = 83fe72c399a895631f6e8826e17e0413ffcc49ad. Cite app.js by FUNCTION NAME;
line numbers below are for the rerun commands only and WILL drift.

## Rerun recipe

```sh
git fetch origin main -q && git rev-parse origin/main
# All emit sites for the codes in play (cloud/, tests excluded):
git grep -n 'instance_not_live\|deploy_not_started\|github_error\|installation_not_found\|repo_not_in_installation\|repo_full_name_required\|invalid_parent\|not_a_support\|domain_required' origin/main -- cloud/ | grep -v test
# Enclosing route/function per emit line (router.ex extracted to $S):
awk -v n=<LINE> 'NR<=n && ($0 ~ /^  (get|post|put|patch|delete) "/ || $0 ~ /^  defp? /) {line=NR; txt=$0} NR==n {print line": "txt}' router.ex
# Console callers per route:
git show origin/main:cloud/priv/static/app.js | grep -n '"/domain"\|/domains\|/v1/github/repos\|/v1/github/installations\|github/connect\|fleet/supports\|supports/\|artifact'
# friendly() fence (four-slug disjunction) + ERRORS map:
git show origin/main:cloud/priv/static/app.js | grep -n 'barkpark_required" || key === "deploy_ability_required\|var ERRORS'
# CLI-side reachability:
git grep -n 'fleet/supports\|/v1/sites/.*domains\|github/connect\|deployments/.*artifact' origin/main -- internal/ | grep -v _test
```

## Disposition table (verdicts)

| code @ emit fn | wire | disposition | reachability proof |
|---|---|---|---|
| instance_not_live @ deploy_static_site | 422 + detail (surface-neutral) | FENCE-ADMIT (CASE B, fifth slug, NO ERRORS entry — shadow law) | POST /v1/sites/:id/deploy is with_team_site {:ability,"write"}; console runDeploy + createAndDeploy both render friendly() directly |
| deploy_not_started @ deploy_static_site | 503 + detail + reason: inspect() | CURATED ERRORS (CASE A) | same console callers; fence-EXCLUDED twice: 5xx-borne (D855/D871 law) AND slug shared with a CLI-voiced sibling emit |
| deploy_not_started @ start_prebuilt_deploy | 503 + CLI-voiced detail | CLASSIFY (CLI-only) | artifact route has zero app.js callers; internal/cli/cloud_site_cmd.go uploads artifacts |
| github_error @ get /v1/github/repos | 502 bare | CURATED ERRORS (member-reachable: Auth.require_user; openSiteGithub → friendly) | one entry covers all three sites via the curated rung |
| github_error @ post /v1/github/repos | 502 bare | same CURATED entry (admin: require_team_admin; newCreateRepo → friendly) | |
| github_error @ connect_site_github | 502 bare | same CURATED entry (admin: require_team_admin; submitSiteGithub → friendly) | |
| installation_not_found @ post /v1/github/installations | 422 bare | CLASSIFY (unreachable from every shipped surface) | zero callers in app.js, internal/, js/ — only tests; no App-install callback exists anywhere |
| repo_full_name_required @ connect_site_github | 422 bare | CLASSIFY (guard-shielded) | submitSiteGithub's select is built only when repos.length > 0; CLI/SDK never call github/connect |
| repo_not_in_installation @ connect_site_github | 422 bare | CURATED ERRORS (TOCTOU-reachable: repo revoked between picker GET and submit POST) | |
| invalid_parent @ post /v1/fleet/supports (register arm) | 422 + detail | CLASSIFY (CLI-only: bp cloud support add sends parent_id; CLI relays detail via cloudError) | console sends mode:"provision" so never hits this arm |
| invalid_parent @ fleet_provision_support | 422 + detail | CLASSIFY (raw-API-only) | console's only POST is submitAddSupport(bp) where bp's card renders only when !isSupportBp(bp) — fleetSupportCardHtml returns "" for supports |
| not_a_support @ delete /v1/fleet/supports/:id | 409 + detail | CLASSIFY (CLI-only: cloud_support_cmd.go DELETE) | zero `supports/` callers in app.js |
| domain_required @ post /v1/barkparks/:id/domain | 422 bare | CLASSIFY (guard-shielded; already classified in shipped attachDomainFailureCopy comment) | attachDomain trims + empty-guards before POST |
| domain_required @ post /v1/sites/:id/domains | 422 bare | CLASSIFY (CLI-only: cloudclient client.go) | zero /v1/sites/:id/domains callers in app.js |

domain_required has exactly TWO emit sites (12011 is cloudflare_domain_required, a different slug).
Line drift vs charter D867/D869: deploy_not_started prebuilt emit cited there as 13923, now 13956 —
function name (start_prebuilt_deploy) is the stable citation.
