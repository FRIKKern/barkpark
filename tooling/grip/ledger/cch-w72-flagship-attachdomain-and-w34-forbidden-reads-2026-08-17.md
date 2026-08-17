<!-- doc-tier: cold | canonical-for: cch-w72-flagship-attachdomain-w34-forbidden-reads | budget: 2000tok -->
# cch-w72 verifier re-derivation recipes — flagship attachDomain 422 shape + w34 bare-forbidden reads

Written by the wave-72 flagship-shape verifier. NOT committed by me — Decide commits one phase later. Every row is a command that re-derives a load-bearing fact from origin/main.

## Flagship: attachDomain 422 arm (four slugs collapse, no_team already carved)

- attachDomain body on origin/main (locate then read):
  `git show origin/main:cloud/priv/static/app.js | grep -n 'function attachDomain'`  → 7901
  `git show origin/main:cloud/priv/static/app.js | sed -n '7901,7942p'`
  The 422 arm is INLINE in the `.then` handler: `(r.status === 422 && code !== "no_team") ? "Only <name>.barkpark.cloud domains are supported for now." : friendly(r.data, ...)`. no_team is ALREADY carved to friendly() (wave 38 / cch-w38-s1 comment in body).

- Client-side empty guard (proves domain_required UNREACHABLE from the modal):
  top of attachDomain: `var value = (($("#domain-input")||{}).value||"").trim(); if (!value) { ... return; }` — returns before POST, so the server's domain_required arm (nil/"" domain) is never reachable from this modal.

- Route 422 slug set (attach_custom_domain):
  `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4196,4300p'`
  Distinct 422 codes: no_team (require_primary_team_admin, carved), domain_required (4215), domain_not_pointed+expected_ip+observed (4243), invalid_domain (4251 & 4297), invalid (4290). FOUR domain slugs collapse today; task title's "five" double-counts invalid_domain's two emit sites (or the pre-wave-38 no_team).
  External FQDNs ARE supported → `DomainOwnership.pointed_at?` branch (4237) — so "only barkpark.cloud subdomains" is FALSE for domain_not_pointed.

- FailureCopy+__bpTestHook peers to model attachDomainFailureCopy(status,data) on:
  `git show origin/main:cloud/priv/static/app.js | grep -n 'FailureCopy\|deployRefusalCopy'` → siteCreateFailureCopy 9737, siteThemeFailureCopy 12468, siteDeleteFailureCopy 13548, deployRefusalCopy 12935.

## w40 task: enumeration matches four-collapsing-plus-no_team

- `bp task get cch-w40-bl-attach-domain-422-collapses-five-server-slugs-into-one-false-sentence -o json`
  Criterion 3 enumerates domain_required, domain_not_pointed, invalid_domain(x2), invalid — FOUR distinct slugs at five router sites. Stale line refs (router.ex:3616 etc.) predate the web/router.ex split. GATE criterion (PR #9955) long merged; attachDomain moved 6998→7901.

## w34: four bare esc(friendly(r.data)) read sites are SAFE (no billing-sentence leak)

- The bare sites (no fallback):
  `git show origin/main:cloud/priv/static/app.js | grep -n 'friendly(r\.data))'` → 6290 loadFleet, 6817 loadOverview, 12081 loadSites, 17131 loadActivity. FOUR, not five (assignment's "five" is off by one on origin/main).

- Driven render (node:vm) of {error:'forbidden',required:'owner',reason:'billing'} through friendly():
  extract esc (58-63) + ERRORS..friendly (179-419), define BIDI_CONTROLS, run. All four render "You need the owner role on this team — only the team owner can grant it." (forbiddenEvidenceCopy: reason 'billing' unmapped → required 'owner' → FORBIDDEN_ROLE_COPY.owner). Controls: bare {error:'forbidden'} → generic D447 sentence; {reason:'billing'} → generic.

- Legacy billing sentence is comment/static-label only, NOT error copy:
  `git show origin/main:cloud/priv/static/app.js | grep -n 'Only the team owner can manage billing'` → 210/334/9469/15870/15881 comments; 15980 is a static #set-purpose label on the billing panel (honest there). No friendly()-reachable render.

- Reachability of the one reachable 403 (activity=/v1/audit, require_primary_team_admin → required:"admin"): renders honest "You need the admin role…". /v1/sites & /v1/barkparks use require_ability("read") + browser root ability → teamless returns 200 [], not 403. Verdict: CLOSE w34 by evidence; residual = bare sites can't name WHICH read was refused (mild copy gap, not a false sentence).
