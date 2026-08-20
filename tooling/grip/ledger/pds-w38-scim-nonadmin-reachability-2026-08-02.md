# PDS w38 — SCIM non-admin reachability + the IdP-shaped hole in a verb-derived population

Derived at `origin/main` = `f85188bdf` (2026-08-02). Every number below is re-derivable
by the command printed beside it. Nothing here is transcribed from the wave brief.

## 0. Re-pin the base ref (do this first — main moved during the wave)

```
cd /Volumes/SATECHI/github/barkpark && git log origin/main --oneline -3
# f85188bdf docs(pds): wave 37 charter … (D517-D531) (#8971)   <-- #8971 IS MERGED
# db7ea8858 chore(cch): …
# fbc6b80a1 fix(scim,auth): two receipts … (PDS-D523) (#8993)
```

## 1. The `:scim` pipeline carries no admin plug — read the plug, not the list

```
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '87,92p'
git show origin/main:api/lib/barkpark_web/plugs/require_scim_token.ex
```

`RequireScimToken.call/2` resolves `Authorization: Bearer` → `Scim.resolve_org/1` →
assigns `:scim_org`. No `require_admin`, no user, no role. Reachability limb:

```
git show origin/main:api/lib/barkpark/scim.ex | grep -n -A8 'def mint_token'
```

Token is org-scoped, minted for an external IdP. ADMIN-MINTED, NON-ADMIN-AUTHORIZED:
the *request* carries no admin identity, and the *driver* is a third-party directory.
State it that way — "non-admin" alone under-describes it, "admin-only" is false.

## 2. Eight SCIM write routes, not three

```
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1493,1514p'
```

Users `create`:1501 `update`:1504 `replace`:1505 `delete`:1506 ·
Groups `create`:1508 `replace`:1511 `update`:1512 `delete`:1513.
`ScimUsersController.replace/2` is `def replace(conn, params), do: update(conn, params)`
— 8 routes, 7 distinct function bodies.

## 3. The three discarded-result sites are UNJUDGED, not REFUTED

```
git show origin/main:api/lib/barkpark/scim.ex | grep -n -A14 'def add_group_member\|def replace_group_members\|def remove_group_member'
```

`add_group_member/3` → `{:ok, 0}` | `{:ok, n}`. `remove_group_member/3` → same.
`replace_group_members/3` → `{:ok, %{added: _, removed: _}}` unconditionally (:445).
**No failure return exists.** So the three caller sites that discard —
`ScimGroupsController.create` (`apply_members/3`), `.update` (the `for {op,uid}` loop),
`.replace` (`Scim.replace_group_members/3`) — cannot be REFUTED. Disposition is
UNJUDGED / `unjudged_other`, and the fix (if any) is a widened CALLEE, not a caller match.

## 4. Two @roster rows are STALE ON MAIN TODAY

```
git show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '416,428p'
git show origin/main:api/lib/barkpark_web/controllers/scim_groups_controller.ex | grep -n 'PDS-D523' -B12
git show origin/main:api/lib/barkpark/accounts.ex | grep -n -A10 'def revoke_user_session_token'
git show origin/main:api/lib/barkpark_web/controllers/session_controller.ex | grep -n -A6 'revoke_user_session_token'
```

Roster says both REFUTED "at 501fb9670" with a STALE-ON-MERGE note. `#8993`/`fbc6b80a1`
LANDED: `delete_group` now cases `{:ok,_n}` / `{:error,:not_found}`;
`revoke_user_session_token/1` returns `{:ok, revoked}` and `session_controller.ex:411`
forks the flash on `n`. The obligation the note describes is now DUE, and
`ROSTER-ANCHORS-EXIST` cannot see it (the literals survive) — by the roster's own words.

## 5. Write-effecting GETs — the IdP-shaped hole in a verb-keyed population

Derivation (line-anchored router lens, action-body first-order scan):

```
python3 <scratch>/getwrites.py     # script body reproduced in §6
# total route calls parsed: 339   by verb: get 178, post 116, delete 30, put 10, patch 5
# post+put+patch+delete = 161  <-- reproduces the line-anchored 161 exactly
```

GET routes whose action body calls a session/identity write verb:

| route | {module, action} | write |
|---|---|---|
| `GET /v1/auth/oidc/:org_slug/callback` (router:1521) | `OidcController.callback` | `Accounts.create_user_session_token` (oidc_controller.ex:66), `Sso.record_login` |
| `GET /v1/auth/social/:provider/callback` (router:1529) | `SocialController.callback` | `create_user_session_token` (:57), `record_login` (:54) |
| `GET /login/ticket/:ticket` (router:802) | `SessionController.ticket` | `Sso.find_or_create_user` (:99) + `Tenancy.Auth.create_membership(ws,user,"owner")` (:141) + session token (:103) |
| `GET /auth/magic/:token` (router:797) | `SessionController.magic` | `Accounts.consume_login_token` (single-use token burn) → `complete_sign_in` |
| `GET /v1/auth/saml/:org_slug/start` (router:1536) | `SamlController.start` | redirect only — **read-only, a false positive of the loose vocab** |

`pipeline :sso_browser` (router:117-125) is `accepts / fetch_session /
put_secure_browser_headers` — **no auth plug at all**. `/login/ticket` and `/auth/magic`
ride `:browser`. All four writing GETs are UNAUTHENTICATED and mint identity.

FALSE POSITIVE, both directions, in one table: `ExportController.export` matched on
`Repo.transaction` but wraps `Repo.stream` (export_controller.ex:29,36) — read-only.
A verb lens misses the four above; a `Repo.`-verb lens flags this one.

## 6. The lens used (reproduce or replace — do not trust it blind)

`getwrites.py`: regex `^\s*(get|post|put|patch|delete)\(` over
`git show origin/main:api/lib/barkpark_web/router.ex`, then
`"path", Module, :action`; maps `BarkparkWeb.FooController` →
`api/lib/barkpark_web/controllers/foo_controller.ex`; slices the action body between
`def <action>` and the next `def`/`defp`; matches
`Repo.(insert|update|delete|*_all|transaction)` or a curated identity-write vocabulary.
KNOWN BLIND: multiline route calls, `V1.*` and plugin-macro modules (NOFILE/NOFN — 22 of
them), and any write reached through a private helper (`ensure_default_owner_membership`
was caught only because the caller also mints a token). First-order only.

## 7. What this means for L4a

If L4a keys the outside population on HTTP VERB it excludes four unauthenticated
identity-minting GETs and includes one read-only export — an IdP-shaped hole of exactly
the class the wish complains about, reproduced by the fix. Key on REACHABLE WRITE EFFECT
(or dispose GETs explicitly), not on the verb.
