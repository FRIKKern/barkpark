# cch-w36 — the admin→launch→checkout→403 chain, executed (2026-08-06)

Verifier assignment `admin-checkout-403-reachable`. Every line below is
re-derivable from `origin/main` at `070c7584b`. **The primary checkout is 490
commits behind origin/main and 48 ahead — running the probe there produced a
DIFFERENT answer (bare 403, no evidence). Use a worktree.**

## Worktree (mandatory — a stale tree silently changes the answer)

    git worktree add --detach /tmp/wt-main origin/main
    cd /tmp/wt-main/cloud
    MIX_ENV=test mix deps.get
    CC=/usr/bin/clang MIX_ENV=test mix compile     # bare `mix compile` fails:
                                                   # `cc` is the Claude wrapper,
                                                   # bcrypt_elixir's make dies

## The probe (run it, do not read it)

Write `admin_checkout_chain_test.exs` OUTSIDE the repo; `mix test <abs path>`
accepts it. Helpers copied verbatim from
`cloud/test/barkpark_cloud/web/router_launch_flow_test.exs` (`user_with_role/1`,
`exhaust_trial/1`, `call/4`). One ADMIN principal, both links:

    launch   = call(:post, "/v1/launch", %{name: "Prod", template: "blog-starter"}, token)
    checkout = call(:post, jb(launch)["checkout_path"], %{plan: "supporter"}, token)

    CC=/usr/bin/clang MIX_ENV=test mix test /abs/path/admin_checkout_chain_test.exs

Decisive output on `070c7584b`:

    LINK1 status=402 body={"error":"no_active_subscription","checkout_path":"/v1/billing/checkout"}
    LINK2 status=403 body={"error":"forbidden","scope":"primary_team","required":"owner"}
    CONTROL status=403 body={"error":"forbidden"}          # plain member, go_live's BARE literal

## Server anchors (greps, never line numbers)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'defp go_live' -A 60
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'checkout_path\|upgrade_path'
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   | grep -n 'require_primary_team_owner' -A 20
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   | grep -n 'defp forbidden(conn, evidence)' -A 2

## Client anchors

    git show origin/main:cloud/priv/static/app.js > /tmp/main_app.js   # 20545 lines
    grep -n 'function renderLaunchPlan(\|function renderNewPricing(' /tmp/main_app.js
    grep -n 'billingCanManage\|billingIsOwner()' /tmp/main_app.js
    grep -n 'meCache.role' /tmp/main_app.js        # the four owner-or-admin predicates
    grep -n 'data\.required\|data\.scope' /tmp/main_app.js   # ZERO hits — evidence discarded

## The screen sentence (node:vm, no browser)

Reuse `cloud/priv/static/__app.test.mjs`'s sandbox verbatim; grab `friendly` and
`billingCanManage` off `__bpTestHook`.

    node /tmp/probe_admin_checkout.mjs

    ADMIN billingCanManage: false
    checkout 403 -> body: "Only the team owner can manage billing."
    launch 403 -> TITLE (hardcoded): "Plan limit reached"
    launch 403 -> body: "Only the team owner can manage billing."
    limit_reached 403 -> body: "You're at your plan's instance limit."

Baseline the shipped suite first so a red is attributable:

    node --check cloud/priv/static/app.js
    node cloud/priv/static/__app.test.mjs        # 721 pass / 0 fail on 070c7584b
