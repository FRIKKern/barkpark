<!-- doc-tier: cold | canonical-for: cch-w70-d846-fence-slug-census | budget: 1200tok -->

# cch-w70 · D846 fenced-rung slug census (re-derivation recipe)

Anchor commit: `d020382028` (origin/main at survey).

## The eight singular-detail refusal slugs (POST /v1/sites, PATCH settings, POST deploy)

Re-derive the router emitters:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/r.ex
    sed -n '6817,6960p' /tmp/r.ex   # POST /v1/sites (create)
    sed -n '7012,7103p' /tmp/r.ex   # PATCH /v1/sites/:id (settings)
    sed -n '7168,7289p' /tmp/r.ex   # POST /v1/sites/:id/deploy (deploy)

| # | slug | route | status | detail source | class |
|---|------|-------|--------|---------------|-------|
| 1 | barkpark_required | create | 422 | static server sentence | RELAY (INCLUDE) |
| 2 | content_binding_required | create | 422 | embeds `--dataset` CLI flag | EXCLUDE-CLI-voiced |
| 3 | node_ports_exhausted | create | 503 | static server sentence | EXCLUDE-5xx-borne |
| 4 | read_token_mint_failed | create | 502 | mint_failure_copy → raw upstream body["error"/"detail"/"reason"] | EXCLUDE-5xx-borne (raw-upstream hazard) |
| 5 | content_binding_empty | create | 422 | refuse_empty_binding → embeds `bp cloud site create …` re-run | EXCLUDE-CLI-voiced |
| 6 | deploy_ability_required | settings | 403 | static server sentence | RELAY (INCLUDE) |
| 7 | nothing_to_update | settings | 422 | static server sentence | RELAY (INCLUDE) |
| 8 | no_build_source | deploy | 422 | embeds `bp deploy` re-run | EXCLUDE-CLI-voiced |

Excluded as NOT singular-detail-string: name_required / no_team / barkpark_not_found (no detail key);
invalid_settings (7075) and every `errors(cs)` arm (detail/details is a per-field MAP, not a string).

## INCLUDE set for D846's fence (friendly() singular-detail rung)

    barkpark_required        (create)
    deploy_ability_required  (settings)
    nothing_to_update        (settings)

Why exactly these three: friendly()'s precedence is curated ERRORS → details(map) → fallback (app.js:346-388, @d020382).
None of the three is an ERRORS key (grep the ERRORS block, app.js:179-…), and friendly() reads only `data.details`
(a map), never the `detail` STRING — so today each drops to `key.replace(/_/g," ")` and the box's measured words vanish.

    git show origin/main:cloud/priv/static/app.js | sed -n '179,240p'   # ERRORS keys
    git show origin/main:cloud/priv/static/app.js | sed -n '346,388p'   # friendly() precedence

## #11783 local-arm coverage (siteCreateFailureCopy, app.js:9707-9761)

Local arms handle create-path slugs BEFORE friendly() sees them:
content_binding_empty, content_binding_required, barkpark_not_found, node_ports_exhausted, read_token_mint_failed.
All FOUR detail-bearing ones are ALREADY excluded from the fence (CLI-voiced or 5xx) → local arms and the fence are DISJOINT.
barkpark_required is create-path but deliberately gets NO local arm (app.js:9702 comment) → it reaches friendly(),
so the fence claims it. deploy_ability_required + nothing_to_update are settings-path with no interceptor.
=> The rung claims all three INCLUDE slugs; none are pre-covered by #11783.

An over-wide fence (adding the 502/CLI slugs) re-opens the cch-w48-s2 raw-upstream-slug class via read_token_mint_failed.
