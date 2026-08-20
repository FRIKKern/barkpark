<!-- doc-tier: cold | canonical-for: cch-w74-fallback-render-proof | budget: 1200tok -->
# cch-w74 fallback-render-proof — re-derivation recipe (2026-08-18)

Verifier lane [fallback-render-proof]. Proves the rendered console sentence for the
12 fallback-covered slugs on origin/main, and the Cloudflare render-path answer.
NOT committed by me — Decide commits one phase later.

origin/main tip at derivation: cf07df265f88584169aa85c6d90ccac10c227569

## Re-derive the emit shapes (router.ex)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/router.ex
    grep -n 'no_content_binding\|prebuilt_not_enabled\|unknown_source\|invalid_name\|unknown_template\|cloudflare_\|no_cloudflare_provider\|already_provisioning\|invalid_settings' /tmp/router.ex

Every emit ships `detail` (singular STRING) or a bare `{error}` or `known_templates`;
NONE ships `details` (plural map). invalid_settings ships `detail: errors(cs)` — a MAP
under the SINGULAR key `detail`, still not `details`.

## Re-derive the render (node:vm probe against real app.js)

    git show origin/main:cloud/priv/static/app.js > $SCRATCH/app.js
    # probe.mjs = the __app.test.mjs sandbox (inert DOM stubs) + friendly()/siteCreateFailureCopy() from __bpTestHook
    node $SCRATCH/probe.mjs

friendly() precedence (app.js:366-447): curated ERRORS[key] -> details(PLURAL) ladder ->
singular-detail rung fenced to {barkpark_required, deploy_ability_required,
nothing_to_update, provisioning_in_progress} -> fallback || humanized-slug.
None of the 12 slugs are in ERRORS (app.js:179-272) or the 4-slug allowlist, and none
ship `details` plural -> friendly() ALWAYS returns the caller's fallback.

Proven renders:
- runDeploy fallback           -> "Please try again."
- createAndDeploy fallback      -> "The site was created — open it and press Deploy to try again."
- siteCreateFailureCopy(422)    -> "create failed (422)"
- no-fallback leg               -> humanized slug ("no content binding", ...) — no live call site hits this

## Render-path answer (the crux)

Cloudflare arms (cloudflare_domain_required/zone_missing/credential_unreadable/
no_cloudflare_provider/cloudflare_bind_failed) live in maybe_bind_cloudflare, a
SYNCHRONOUS plug step in POST /v1/sites/:id/deploy (router.ex:7201) returning
{:halt, json(...)} BEFORE deploy_static_site mints any deployment row. They surface on
the synchronous POST response via runDeploy `friendly(r.data, "Please try again.")` —
NOT via the async rail deployRefusalCopy (app.js:13008, reads a persisted row's
failure_reason; these halts never create a row).

## Reachability (decides lie-vs-honest for the CONSOLE census)

CONSOLE-UNREACHABLE (CLI/API-only) — grep app.js: no request body sets `via`, `source`,
or `prebuilt`:
- 5 cloudflare arms      — fire only on via=cloudflare
- unknown_source         — fires only on body source not in sources(); console never sends source
- prebuilt_not_enabled   — fires only on source=prebuilt
- no_content_binding     — require_content_binding("static"/"node") gates it AT CREATE
                           (router.ex:12478/6925), so a console site always has a binding
- invalid_name / unknown_template — github create-repo-from-template route has NO console caller;
                           launch template is a fixed select
- invalid_settings       — console theme PATCH sends a fixed enum via siteThemePatchBody; renders
                           via siteThemeFailureCopy->faultCopy, not the deploy fallback

Verdict: for the console surface "Please try again." is a transience-lie IF reached, but
the console cannot reach any of these — honest classification is "CLI-only / backstop
unreachable", NOT "console-reachable honest-but-unspecific" and NOT "measured lie on the
console". already_provisioning (409, console double-click reachable) rendering "Please
try again." is honest-enough (the box is coming up).
