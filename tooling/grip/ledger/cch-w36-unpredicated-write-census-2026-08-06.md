# cch-w36 — the un-predicated elevated-write census (re-derivation recipe)

Derived on `origin/main 070c7584b`. Every number below is reproduced by the
commands here; nothing is quoted from a prior wave.

## The population, in one command

```
cd $(git rev-parse --show-toplevel) \
  && git show origin/main:cloud/priv/static/app.js  > /tmp/w36-app.js \
  && git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/w36-router.ex \
  && grep -cE 'api\(\s*"(POST|PUT|PATCH|DELETE)"' /tmp/w36-app.js
```

`79` write `api()` call sites (55 POST / 14 DELETE / 7 PUT / 3 PATCH):

```
grep -oE 'api\(\s*"(POST|PUT|PATCH|DELETE)"' /tmp/w36-app.js | sort | uniq -c
```

## The server half nobody had built

The authority tier per route is ALREADY machine-derivable from the router's
`@moduledoc` route table (the AUTH column), and that column is already pinned to
the route bodies by `cloud/test/barkpark_cloud/web/router_moduledoc_table_test.exs`
(the "tier census", `@resolved_floor 161`).

```
grep -nE '^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)\s+(\S+)' /tmp/w36-router.ex | wc -l
```

BUT the AUTH column UNDER-REPORTS for seven routes that call `Auth.require_user`
(tier `user`) and then 403 non-admins in an inline `cond`:

```
grep -n 'Accounts.team_admin?(conn.assigns.current_user' /tmp/w36-router.ex
# 2027 POST /v1/fleet/supports      (row says `user`)
# 2191 DELETE /v1/fleet/supports/:id (row says `user`)
# 4271 POST /v1/env-vars            (row says `user`)
# 4329 DELETE /v1/env-vars/:id      (row says `user`)
# 8051 go_live  => POST /v1/launch + POST /v1/go-live  (rows say `user`)
# 8254 POST /v1/resurrect           (row says `user`)
```

This is ALREADY FILED as `task-78c7fdb9783e3459` (gh #9636, open, priority 2) —
"Post-guard cond gates make the route-table tier census under-report". The
unpredicated-write census must consume its widened lens or hard-code the seven,
not re-file it.

## The refusal evidence, per route

```
grep -n '403, %{error: "forbidden"}' /tmp/w36-router.ex | wc -l   # 12 bare literals
grep -c 'Auth.forbidden' /tmp/w36-router.ex                       # 0
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'forbidden('
```

`Auth.forbidden/2` (auth.ex:502) carries `required`/`scope`/`reason`; the router
never calls it. So the `Auth.require_*` routes refuse WITH evidence and the 12
inline-`cond` routes refuse WITHOUT it — including `go_live` (8055), the crown's
own first refusal.

## Counts (final.mjs shape)

| bucket | n |
|---|---|
| write `api()` call sites | 79 |
| effective-authority > member (elevated) | 40 |
| — of those, documented elevated (admin/owner/operator) | 34 |
| — of those, UNDER-documented (`user` row, admin body) | 6 |
| elevated WITH a client predicate (positive controls) | 21 |
| **elevated with NO client predicate** | **19** |
| member-tier writes (no authority gate — out of population) | 39 |

The 19: app.js 1870, 2810, 6644, 6670, 6688, 6724, 6787, 6848, 7139, 7531,
12134, 12150, 12946, 12997, 16009, 16045, 16768, 16805, 16916.
(Line numbers are for orientation only — briefs must carry greps, per this
wave's standing law. Re-derive with the `final.mjs` table.)

The 6 predicate families that DO suppress (positive controls):
`providerCanWrite` (3 sites), `notifCanManage` (6), `canManageOnboarding` (1),
`billingIsOwner` via `renderBilling`'s `if (!billingIsOwner()) renderBillingReadOnly` (3),
`assignableRoles(ctx.role)` (6), plus `applyOperatorGate` (2 operator sites).

## Fixture corpus gap

```
node -e 'import("./cloud/priv/static/__preview__/scenarios.mjs").then(m=>{
 const n=Object.keys(m.SCENARIOS);
 console.log(n.length, n.filter(k=>JSON.stringify(m.SCENARIOS[k]).includes("\"role\":\"member\"")));})'
```

98 scenarios; 6 true plain-member ones (`members-member`, `env-member`,
`tokens-member`, `billing-member`, `providers-member`, `notif-member`) — which
are EXACTLY the six predicated surfaces. There is no plain-member scenario for
any of the 19 un-predicated sites. The fixture corpus was built from the
already-fixed half.

## Reachability of the crown (one click, admin)

app.js:12946 `POST /v1/launch` -> `if (r.status === 402) renderLaunchPlan(...)`
-> the plan picker's `.new-plan` click -> app.js:12997 `POST /v1/billing/checkout`
(owner-only, `Auth.require_primary_team_owner`, router.ex:5082). go_live is
TEAM-ADMIN (router.ex:8051) and its 402 hands back `checkout_path` (8082/8264).
So a team ADMIN is walked into an owner-only refusal by the control plane's own
payload. Twin at app.js:16009 -> 16045 on `/new`, where the 403 arm hardcodes
the title "Plan limit reached" (app.js:16016).

## Existing tests checked (none pins this)

- `cloud/test/barkpark_cloud/accounts/authz_test.exs` — unit tests of
  `Authz.role/team_admin?/team_owner?/authorize/can_grant?` only. No route census.
- `cloud/test/barkpark_cloud/web/router_ability_matrix_test.exs` — **DOES NOT EXIST**
- `cloud/test/barkpark_cloud/web/role_agreement_census_test.exs` — **DOES NOT EXIST**
- `cloud/priv/static/__app.test.mjs` — 721 tests pass; pins `operatorVisible`,
  `memberRowHtml`, `billingCanManage`, `assignableRoles` individually. No
  call-site -> route -> gate triple anywhere.
