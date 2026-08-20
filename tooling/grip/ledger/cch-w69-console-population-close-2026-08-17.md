# cch-w69 — console-population-close: re-derivation recipes (2026-08-17)

Verifier lane `console-population-close`, wave 69. Every fact below re-derives from
`origin/main` = `05a98dd2ca` (#11706 MERGED — the shared checkout was 4 commits BEHIND
at survey time, which is why the stale tree reports 1075 tests and main reports 1082).

## 0. Build the measurement tree (the shared checkout is not main)

    git fetch origin
    git worktree add --detach /tmp/wt-main origin/main
    cd /tmp/wt-main && git log --oneline -1     # => 05a98dd2ca

## 1. The console gate's green baseline ON MAIN (quote 1082, never 1027 or 1075)

    cd /tmp/wt-main && node --check cloud/priv/static/app.js \
      && node cloud/priv/static/__app.test.mjs 2>&1 | tail -8
    # => # tests 1082 / # pass 1082 / # fail 0

The census tests traverse the repo (`cloud/lib`, `internal/`, `design/`), so running the
suite from a copied-out directory reds 18 tests for the copy, not for the code.

## 2. None of the refusal slugs is registered in ERRORS

    grep -n 'nothing_to_update\|invalid_settings\|no_content_binding\|not_deployable\
    \|deploy_ability_required\|content_binding_empty\|prebuilt_not_enabled\|instance_not_live' \
      cloud/priv/static/app.js
    # => only 2 hits, both COMMENTS (9682, 14018). Zero ERRORS entries, zero render arms.

## 3. The sentence a person actually reads (execute, never read)

Reuse the suite's own vm sandbox (test lines 31-82) + `__bpTestHook`:

    { echo 'import vm from "node:vm"; import fs from "node:fs"; import os from "node:os"; import { spawnSync } from "node:child_process";'; \
      sed -n '31,82p' /tmp/wt-main/cloud/priv/static/__app.test.mjs; } > /tmp/m/probe.mjs
    cp /tmp/wt-main/cloud/priv/static/app.js /tmp/m/app.js   # probe reads ./app.js
    # then call hooks.friendly / hooks.siteCreateFailureCopy / hooks.siteThemeFailureCopy
    # / hooks.promoteFailure and print the returned string.

Measured, all eight slugs:
- `friendly(data)` with NO fallback -> humanized slug ("content binding empty").
- `friendly(data, <any fallback>)` -> THE FALLBACK, always. `data.detail` (singular) is never read.
- `siteCreateFailureCopy({status:422,...})` -> `"create failed (422)"` for all eight.
- theme PATCH -> `"We couldn't set the theme. Try again in a moment."` (422) /
  `"Something broke on our side — not your input. Try again in a moment."` (5xx).
- deploy -> `"Please try again."` (runDeploy) /
  `"The site was created — open it and press Deploy to try again."` (createAndDeploy).
- the honest twin: `promoteFailure(422, {error:"no_build_source"}).message` ->
  `"This deployment has no stored artifact and the site has no connected repo, so there's nothing to rebuild from."`

## 4. The dead menu clause (key mismatch, both halves in one command)

    grep -n -A16 'defp maybe_put_menu' cloud/lib/barkpark_cloud/web/router.ex   # => :readable_types
    grep -n 'readable_types\|known_templates' cloud/priv/static/app.js         # => known_templates only (9651, 9660)
    grep -n '\.menu\b\|"menu"' cloud/priv/static/app.js                        # => ZERO

Probe proof: `readable_types` payload -> `"create failed (422)"` (no suffix);
`known_templates` payload -> `"create failed (422) — templates: a, b"`.

## 5. The create-copy slice's whole test burden

    grep -c 'siteCreateFailureCopy' cloud/priv/static/__app.test.mjs   # => 1
    grep -n 'create failed (' cloud/priv/static/__app.test.mjs         # => 18131 only

One block: `cch-w37-s1: creating a site stops rendering the bare token \`invalid\``
(test lines 18120-18134, six assertions). The arity pin lives elsewhere:

    grep -n 'friendly.length' cloud/priv/static/__app.test.mjs   # => 18107, pins arity 2

## 6. Route ownership of the slugs (the direction mis-assigned three)

    R=cloud/lib/barkpark_cloud/web/router.ex
    awk -v L=<line> 'NR<=L && /^  (get|post|put|patch|delete|match) /{r=NR": "$0} NR==L{print r}' $R

- `nothing_to_update` (7027), `invalid_settings` (7044), `deploy_ability_required` (7017)
  all belong to **PATCH /v1/sites/:id** — not the deploy route.
- `not_deployable` (4369) belongs to **POST /v1/barkparks/:id/vercel-deploy**.
- `no_content_binding` (12061) is in `deploy_static_site/2`, reached from
  **POST /v1/sites/:id/deploy** (7137) — the only one of the three that is on that route.
