# cch-w39 verifier v2 — re-derivation recipe: the four S1 write routes sit on the x-barkpark-team axis

Head verified: `origin/main` = `f4194c51f3294b0880cd11ce83a8f4894c02c99f` (2026-08-07).

## Claim

All four S1 surfaces' write routes resolve their team via `Auth.resolve_team/2`
(the `x-barkpark-team` header), NOT via `Auth.require_team_role/3` (the
`/v1/teams/:id/*` path-team axis that #9955's own comment fences its predicate
against). `instanceAdminAuthority()` is therefore SOUND for all four.

## Re-derive

```sh
cd /Volumes/SATECHI/github/barkpark
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/v2_router.ex
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   > /tmp/v2_auth.ex
git show origin/main:cloud/priv/static/app.js               > /tmp/v2_app.js

# 1. the four write routes and their gates
sed -n '1547,1549p;3880,3882p;3902,3904p;4456,4458p;5045,5047p' /tmp/v2_router.ex

# 2. the path-team axis has exactly ONE entry point, and it reads path_params
grep -n 'require_team_role' /tmp/v2_router.ex          # => 10856 (comment), 10859 (only call)
sed -n '10855,10862p' /tmp/v2_router.ex

# 3. every non-path gate reads current_team, filled from the header
grep -n 'x-barkpark-team' /tmp/v2_auth.ex              # => 123 (resolve_team), 403/439 (docs)
sed -n '121,130p' /tmp/v2_auth.ex

# 4. the client pins the header on every authed request
grep -n 'x-barkpark-team' /tmp/v2_app.js               # => 117

# 5. the seven client write callers all go through api()
grep -n 'api("POST", "/v1/providers"\|api("DELETE", "/v1/providers\|api("PUT", "/v1/notifications/settings"\|api("POST", "/v1/tokens"\|api("POST", "/v1/onboarding"' /tmp/v2_app.js

# 6. the token mint's role check is in the context, not the router
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '860,880p'
```

## Result table

| S1 surface | client caller (app.js) | route | server gate | team axis |
|---|---|---|---|---|
| providers connect | `submitProviderCred` :2294→:2314, `submitInlineProviderCred` :2730→:2745 | `POST /v1/providers` :3880 | `Auth.require_team_admin/2` → `gate_role/4` :483 | header |
| providers disconnect | `disconnectProvider` :2782→:2795 | `DELETE /v1/providers/:kind` :3902 | `Auth.require_team_admin/2` | header |
| notification settings write | `saveNotifEmail` :3667→:3684, `onNotifCellToggle` :3732→:3741 | `PUT /v1/notifications/settings` :4456 | `Auth.require_team_admin/2` | header |
| token mint | `submitToken` :4017→:4045 | `POST /v1/tokens` :5045 | `Auth.require_user/2` ONLY; role enforced in `Accounts.pat_abilities_allowed?/2` :873 against `Authz.role(user, current_team)` | header (`current_team` from `resolve_team/2`) |
| onboarding dismiss | `dismissRunway` :6229→:6231 | `POST /v1/onboarding` :1547 | `Auth.require_primary_team_admin/1` :414 | header (its NAME lies; doc at auth.ex:403 says so) |

`/v1/providers/:kind` is a KIND path param, not a team id — it never reaches
`require_team_role/3`.

## Two riders Decide should carry

1. **`POST /v1/tokens` has no router-level role gate.** Its 403 is
   `json(conn, 403, %{error: "forbidden"})` (router.ex:5093) — a BARE slug with
   none of the `required:` / `scope:` / `reason:` evidence `Auth.forbidden/2`
   emits (auth.ex:508+). `submitToken` (:4045) routes it into
   `faultCopy(r.status, r.data, "Check the form and try again.")`, so a member
   who mints `write` is told to check the form. Any S1 unknown/refuse arm on the
   token surface has NO server evidence to classify from, unlike the other three.
2. **The 403 body shape differs across the four.** `gate_role/4` emits
   `reason: "no_team"` for a teamless caller (auth.ex:496) while
   `require_primary_team_admin/1` emits a 422 `%{error: "no_team"}`
   (auth.ex:425) — onboarding diverges from providers/notifications on the same
   condition. (cch-w38-s2-no-team-stops-being-a-422 owns that row.)
