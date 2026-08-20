# w48 verify — `#site-github`: gate, member render, blast radius, and the typed cost of a member site scenario

Baseline tree: `git archive origin/main` at **fc27f0d7499046c2a5d511f2334f3fe1bc5878f7** (never the primary checkout).

    D=$(mktemp -d); git archive origin/main | tar -x -C $D

## 1. Is `#site-github` gated on `configured?` or on role? — NO to both

    git show origin/main:cloud/priv/static/app.js | sed -n '11576p;11605,11607p;11629p'
    # 11576  function siteDetailHtml(site, bp, deployments, domain, previews)   ← 5 params, no authority
    # 11605  var githubLabel = site.github_repo ? '<span class="mono">'+esc(site.github_repo)+"</span>" : "Connect GitHub repo";
    # 11629  '<button class="btn btn-ghost btn-sm" id="site-github" type="button">' + githubLabel + "</button>"

No `authority` / `canWrite` / `role` / `configured` token inside the function body:

    awk 'NR>=11576 && NR<=11760' $D/cloud/priv/static/app.js | grep -n 'authority\|canWrite\|configured' ; # → no matches other than site.github_webhook_configured

## 2. Blast radius is ONE screen

    git show origin/main:cloud/priv/static/app.js | grep -n 'site-github'
    # 11468, 11469, 11629 — all inside siteDetailHtml / wireSite (#view-site)

`globalSiteRow` (:11365, the `#sites` list) and `siteRow` (:9275, the instance-workspace `.inst-sites-card`)
paint only a read-only `Auto-deploy | Manual` badge and a repo string. Neither emits `#site-github`.
`SCENARIOS["sites-on-instance"].deepLink === "#instance/5b2c1e00-0000-4000-8000-0000000000a1"`.

## 3. The route gates (order matters)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4138,4150p;7086,7098p;7116,7118p'
    # GET    /v1/github/repos          → require_user  THEN `not GitHub.configured?() -> 503`
    # POST   /v1/sites/:id/github/connect → require_team_admin FIRST, then 503 configured?
    # DELETE /v1/sites/:id/github        → require_team_admin, NO configured? arm at all

So on an UNCONFIGURED deployment the modal's own 503 arm (app.js:12921) fires for every actor
(honest copy, "GitHub isn't configured on this deployment yet."). The member-specific 403 needs
`configured? == true` AND a recorded installation.

## 4. There is no member actor on `#site/` anywhere in the corpus

    cd $D/cloud/priv/static/__preview__ && node -e 'import("./scenarios.mjs").then(m=>{for(const[k,v]of Object.entries(m.SCENARIOS)){const r=v.data&&(v.data.role||(v.data.me&&v.data.me.role));if(String(v.deepLink||"").startsWith("#site/"))console.log(k,r)}})'
    # all 12 → owner
    # the 9 non-owner scenarios: panel-overview-member, members-member, members-admin-actor,
    #   env-member, timeline-events-only, tokens-member, billing-member, providers-member, notif-member

## 5. TYPED COST of minting one member site-detail scenario — measured, not estimated

Insert into `scenarios.mjs` (9 lines, `me(team, onb, role)` — role is the 3rd arg):

    "site-member-probe": { label, authed:true, deepLink:"#site/"+IDS.siteWeb,
      data:{ me: me("Acme Inc",{instance:true},"member"), barkparks:[liveInstance],
             subscription:activeSub, sites:[webSite], audit:[] } },

Bare insert → `node --test breakpoint-sweep.test.mjs` = **54 tests / 50 pass / 4 fail**
(#17 coverageReport clean, #21 the import proof, #44 the census pin `108 !== 109`,
#50 the by-name allowlist refusal). `coverageReport` folds `scenarioReport` in via its
`scenarios` key, which is why the CSS/HTML legs red on a JS-fixture change.

Full green needs SEVEN edits — one residue entry, two prose counts, three integers, plus the scenario:

| file | line (origin/main) | edit |
|---|---|---|
| `__preview__/scenarios.mjs` | ~2907 | +9 lines, the scenario |
| `__preview__/breakpoint-sweep.mjs` | 371 | `These 9 vary binding/verify` → `These 10` |
| `__preview__/breakpoint-sweep.mjs` | 494 | `// hash:#site — 9` → `— 10` |
| `__preview__/breakpoint-sweep.mjs` | 495 | +1 residue entry `"<name>": "hash:#site",` |
| `__preview__/breakpoint-sweep.test.mjs` | 596 | `r.total, 108` → `109` |
| `__preview__/breakpoint-sweep.test.mjs` | 599 | `r.residue, 83` (+ its message) → `84` |
| `__preview__/breakpoint-sweep.test.mjs` | 602 | `Object.keys(SCENARIO_RESIDUE).length, 83` → `84` |

After all seven: `node --test breakpoint-sweep.test.mjs` → **54/54/0**, `node __app.test.mjs` → **988/988/0**.

## 6. The smoke census makes the assertion MANDATORY (good news)

With the scenario committed but no expectation:

    cd $D/cloud/priv/static/__preview__ && node --test smoke.mjs
    # CENSUS: 1 committed scenario(s) have NO expectation and were never run —
    #   site-member-probe
    # census guard failed — every scenario needs an expectation, both ways   → tests 1 / fail 1

So the builder cannot land a member site scenario without an assertion on it.

## 7. Ready-made authority input

`providerCanWrite()` (app.js:2590) already reads `meCache.role` and is the predicate the census
recognises by name at app.js:3004/:3054. No new payload is needed to fence `#site-github`.

## 8. Census independently names both site-github writes

    cd $D/cloud/priv/static && node __binding_census.mjs | grep 'sites/:\*/github'
    # app.js:12992  POST   /v1/sites/:*/github/connect   ELEVATED!  NONE — a member can click it
    # app.js:13008  DELETE /v1/sites/:*/github           ELEVATED!  NONE — a member can click it
    # tail: 79 call sites, 40 elevated, 16 unpredicated, rc 0
