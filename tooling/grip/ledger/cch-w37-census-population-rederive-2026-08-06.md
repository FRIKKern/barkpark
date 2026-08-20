# cch-w37 — slice 4 census population, re-derived at origin/main bf97452bb (2026-08-06)

Every integer below is re-derived from a command. Nothing is quoted from D409.

## Base

```
cd /Volumes/SATECHI/github/barkpark && git rev-parse origin/main
# bf97452bb38488d04cfbb596c2528a3f34ad5baf
```

## 1. Total write api() call sites — 79 (unchanged)

```
git show origin/main:cloud/priv/static/app.js | grep -cE 'api\("(POST|DELETE|PUT|PATCH)"'
# 79
```

## 2. The 13 non-literal-path sites (hazard a) — 79 lines, only 66 literal

```
git show origin/main:cloud/priv/static/app.js | grep -nE 'api\("(POST|DELETE|PUT|PATCH)"' \
  | grep -vE 'api\("(POST|DELETE|PUT|PATCH)", *"'
```

| line | expression | resolves to | elevated? |
|---|---|---|---|
| 4597 | `path` (login\|register) | POST /v1/auth/{login,register} | no — anonymous, `noAuth` |
| 7732 | `path` = OPERATOR_AUTOUPDATE + halt\|resume | POST /v1/operator/autoupdate/* | **YES — operator** |
| 8107 | OPERATOR_AUTOUPDATE + "/halt" | POST /v1/operator/autoupdate/halt | **YES — operator** |
| 9142 | whPath(...test-send) | POST /v1/barkparks/:id/api/webhooks/:webhook_id/test-send | no — `Auth.require_user` only |
| 9189 | whPath(id) | PUT .../webhooks/:webhook_id | no |
| 9211 | whPath(...rotate) | POST .../rotate | no |
| 9340 | whPath(id) | PUT .../webhooks/:webhook_id | no |
| 9370 | whPath("") | POST /v1/barkparks/:id/api/webhooks | no |
| 9411 | whPath(id) | DELETE .../webhooks/:webhook_id | no |
| 9472 | whPath(...replay) | POST .../deliveries/:event_id/replay | no |
| 11437 | promotePath(siteId, depId) | POST /v1/sites/:id/deployments/:dep_id/promote | no — `require_ability("write")`, a no-op for a root session |
| 11649 | siteRollbackPath(siteId) | POST /v1/sites/:id/rollback | no — `with_team_site(conn, {:ability,"write"}, …)` |
| 16240 | `path` (login\|register) | POST /v1/auth/{login,register} | no — anonymous |

A **14th** hazard the "13" misses: `app.js:18710` builds
`"/v1/auth/device/" + decision` — a LITERAL prefix with a variable last segment,
so a literal extractor accepts it and yields the un-routable path
`/v1/auth/device/`.

Helper definitions: `whPath` app.js:9007, `promotePath` :11292,
`siteRollbackPath` :11517, `OPERATOR_AUTOUPDATE` :7664.

## 3. The split — 40 elevated / 22 predicated / 18 unpredicated

Elevated = requires a role above plain member (admin/owner) or a platform tier
(operator). `require_ability` is NOT elevated for the console: a session carries
`["root"]` (router.ex go_live comment, ~:8075), so the ability check is a no-op
for every session-authed call site.

- 40 ELEVATED — 16 `require_team_admin`, 7 `require_primary_team_admin`,
  4 `with_team_role:admin`, 4 inline `Accounts.team_admin?` (7245, 18474, 18502,
  1938/resurrect), 2 admin-by-go_live (13129, 16345), 5 `require_primary_team_owner`,
  2 `require_platform_operator`.
- 39 NOT elevated — 20 plain `require_user`, 6 anonymous auth, 7 webhook proxy
  (`proxy_instance_webhook` → `Auth.require_user` only, router.ex:9918),
  6 site writes behind `{:ability,"write"}`.
- 22 PREDICATED: providers page 2744, 2794 (`providerCanWrite` :2351 via
  `renderProviderPage(list, providerCanWrite())` :2639); notifications 3683,
  3720, 3740, 3742, 3788, 3798 (`notifCanManage` :3490 via :3508); onboarding
  6230 (`canManageOnboarding` :6018 via :6214); billing 13222, 13513, 13621,
  13781 (`billingIsOwner` :13318 via :13377) and 16410
  (`launchCheckoutAuthority` :13171 via :16390); operator 7732, 8107
  (`operatorVisible` :4877); teams 18126, 18186, 18233, 18261 and env-vars
  18474, 18502 (`assignableRoles(ctx.role).length > 0`, :18383 and the members
  page).
- 18 UNPREDICATED: 1938, 2313, 2878, 6750, 6776, 6794, 6830, 6893, 6954, 7245,
  7637, 12317, 12333, 13129, 16345, 17136, 17173, 17284.

D409's 40 reproduces exactly. Its 21/19 does not, for two identified reasons:
(a) wave 36's s1 merged, moving the two checkout plan grids from unpredicated to
predicated; (b) **line 2313 is unpredicated while 2744 is predicated** —
both are `POST /v1/providers`. 2313 is reached from the launch wizard's
`.launch-connect-provider` button, rendered unconditionally at app.js:12887 →
`openProviderCredential` (:12933) → `submitProviderCred` (:2293).

## 4. Route-keying collapses the population — key by CALL SITE

79 call sites → 67 distinct (verb, path) keys. 11 keys carry >1 site:

```
2 DELETE /v1/barkparks/:id          6750, 6794
2 POST   /v1/auth/login|register    4597, 16240
2 POST   /v1/barkparks/:id/retry    6776, 17284
2 POST   /v1/barkparks/:id/studio-link 5544, 12689
3 POST   /v1/billing/checkout       13222, 13781, 16410
2 POST   /v1/launch                 13129, 16345
2 POST   /v1/notifications/test     3788, 3798
2 POST   /v1/providers              2313, 2744
2 POST   /v1/sites/:id/deploy       12059, 12223
2 PUT    .../webhooks/:webhook_id   9189, 9340
2 PUT    /v1/notifications/settings 3683, 3740
```

`POST /v1/providers` is the decisive one: one site is predicated and the other is
not, so a route-keyed census scores the route "predicated" and the real gap at
2313 becomes invisible. The two `DELETE /v1/barkparks/:id` sites (6750, 6794)
also collapse — both unpredicated, so the census would under-count by one.

## 5. Hazard (b) — the "seven post-guard inline-cond routes" is six by the
prescribed grep, seven by content, and the seventh is not a refusal

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
  | grep -n 'Accounts.team_admin?(conn.assigns.current_user'
# 2058 2222 4302 4360 8082 8290   → SIX
```

The seventh site exists but binds locals first:

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'Accounts.team_admin?'
# ... 4653:        admin? = Accounts.team_admin?(user, team)
```

router.ex:4653 is `GET /v1/notifications/deliveries` — a READ, and the value is a
**self-scope narrowing** (`recipient: if(admin?, do: nil, else: user.email)`),
not a refusal. Of the six refusal sites, 8082 is already named
(`Auth.forbidden(conn, required: "admin", scope: "team")`, landed by #9848);
2058, 2222, 4302, 4360, 8290 still emit a bare `%{error: "forbidden"}`.

## 6. Hazard (c) — router_moduledoc_table_test.exs still carries @guard_tier, RUNS GREEN

```
T=$(mktemp -d); git archive origin/main cloud | tar -x -C $T
cd $T/cloud && CC=clang mix test test/barkpark_cloud/web/router_moduledoc_table_test.exs
# tier-bearing rows examined : 162  (user|admin subset: 112)
# guard RESOLVED             : 161
# guard UNRESOLVED (consented): 1
# 6 tests, 0 failures
```

`@guard_tier` is at test:126; `@unresolved_consent` at :146; `@resolved_floor 161`
at :157. It is consumable — but it is keyed by `{METHOD, literal path}` from the
router declaration, so joining a client call site to it requires normalising
`encodeURIComponent(...)` segments to `:param` first, and it says nothing about
the SIX inline-cond sites (they resolve to their outer guard, `require_user`).

## 7. canMintAnyAbility has no router-level authority

```
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | grep -n pat_abilities_allowed
# 865:    if pat_abilities_allowed?(Authz.role(user, team), requested) do
# 873:  defp pat_abilities_allowed?(role, _requested) when role in ~w(owner admin), do: true
```

`POST /v1/tokens` (app.js:4044) resolves to `Auth.require_user` — tier `user`.
`canMintAnyAbility` (app.js:3918) asserts owner|admin. A census schema with only
an `auth_fn` slot therefore has two wrong answers and no right one: DRIFT reds
falsely (predicate stricter than the router guard), or the row asserts "any
member may mint any ability" — false, because the refusal lives in
`Accounts.pat_abilities_allowed?/2`, below the router. The schema needs a
`context_fn` slot (or an explicit BELOW-ROUTER class) before this row can be pinned.

## 8. Extractor hazard found while building the resolver

Naive delegation-following mis-tiers `POST /v1/launch` as `worker`: `go_live/1`
transitively reaches a helper that mentions `Auth.require_worker`. The real gate
at router.ex:8082 is the inline `Accounts.team_admin?` / `require_ability("deploy")`
pair — ADMIN. Any resolver that follows `foo(conn)` calls must stop at the first
guard, not union the transitive closure.
