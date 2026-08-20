# Finding #15 (Studio media library 403s for non-admin) — re-derivation recipe

Baseline: origin/main `a07a0baa138d628987706e94a31329379410f23a` (the charter's
pinned `6f724edfd8` is two heads stale).

VERDICT: #15 is NOT M1 (AssignDefaultScope) and NOT a sixth tenancy mechanism.
It is the M6 principal-kind asymmetry expressed at the Studio -> Web-Component
-> HTTP token handoff, mis-labelled "non-admin" by a misleading 403 hint.

## The chain (each link independently re-derivable)

1. Route: `live("/media", MediaLive)` exists ONLY under the `:scoped_studio`
   live_session, on_mount `{LiveAuth, :fetch_api_token}` — NOT `:admin`.
       git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1435,1455p'
2. `MediaLive` has no gate; it renders `<bp-asset-explorer data-token={assigns[:api_token_raw] || ""}>`.
       git show origin/main:api/lib/barkpark_web/live/studio/media_live.ex
3. `LiveAuth.on_mount(:fetch_api_token, …)` sources the raw token ONLY from
   `session["api_token"]`, else `dev_browser_token_fallback()` which is
   `if Mix.env() == :dev`. A USER-session principal therefore gets `""`.
       git show origin/main:api/lib/barkpark_web/live_auth.ex | sed -n '110,166p'
4. No user-login path ever sets `session["api_token"]`. Only SessionController
   `create/2` (pasted token) and the api_token arm of `ticket/2` do.
       grep -rn 'put_session("api_token"' api/lib      # 2 hits, both session_controller.ex
       grep -rn 'put_session("user_session"' api/lib   # 6 hits, none set api_token
5. The explorer lists via `_mediaBase()` = `scope_prefix + "/v1/media/" + dataset`
   with `Authorization: Bearer <data-token>` only when the attribute is non-empty.
       sed -n '425,450p;620,630p' api/priv/static/assets/bp-asset-explorer.js
6. `GET /w/:ws/p/:proj/v1/media/:dataset` rides `:scoped_api`, which has NO
   `fetch_session` and NO `OptionalSessionToken` — so `conn.assigns[:current_user]`
   is structurally always nil there and ResolveWorkspace's `%User{}` membership
   arm is unreachable on this pipeline.
       git show origin/main:api/lib/barkpark_web/router.ex | sed -n '/pipeline :scoped_api do/,/^  end/p'
       git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2504,2517p'
7. ResolveWorkspace with token=nil and user=nil falls to `true -> halt_envelope
   {:error, :forbidden}` (no `allow_anonymous_default` opt on `:scoped_api`).
       git show origin/main:api/lib/barkpark_web/plugs/resolve_workspace.ex | sed -n '80,130p'

## The black-box proof (no credentials needed)

    curl -s -o /dev/null -w '%{http_code}\n' http://89.167.28.206/v1/media/production
    # 200  (flat route, :api + AssignDefaultScope)
    curl -s http://89.167.28.206/w/default/p/default/v1/media/production
    # 403 {"error":{"code":"forbidden","message":"token lacks required permission",
    #      "hint":"Use a token with write/admin permission that is a member of this workspace."}}

The 403 arm reached is the SAME arm a signed-in user-session operator reaches
(token nil, user nil). The flat 200 refutes M1 for this finding.

## Why the report says "non-admin"

`api/lib/barkpark/content/errors.ex:308` renders every `:forbidden` as
"token lacks required permission" + "Use a token with write/admin permission".
The actual gate is `TenancyAuth.authorize(token, ws, :read)` — a MEMBERSHIP
(and, here, an AUTHENTICATION) failure, not a permission tier. An operator
whose admin colleague pasted an api_token at `/login` (works) and whose
non-admin colleagues signed in with an account (403) reads that hint and files
"403s for non-admin".

    grep -rn 'token lacks required permission' api/lib

## The precedent that makes the fix cheap

The media WRITE pipeline already solved exactly this:
`:scoped_media_mutate` = `fetch_session` + `OptionalSessionToken` + ResolveWorkspace
(router.ex:288-318), with the comment "so the membership gate below sees a
session-only browser member too". `:shared_media_api`, `:scoped_browser` and
`:shared_studio_browser` carry the same shape. `:scoped_api` — which serves the
media READ — does not. Media writes authenticate a browser session; media reads
do not. That is finding #5's "write-allowed / read-denied" signature.

ORDERING HAZARD (separate, unreported): the collections/checkout routes at
router.ex:2523 use `pipe_through([:scoped_api, :media_mutate])`, so
`:scoped_api`'s ResolveWorkspace runs BEFORE `:media_mutate`'s fetch_session +
OptionalSessionToken — those routes 403 a session-only member too, and adding
OptionalSessionToken to `:scoped_api` fixes them by construction.

## Why the suite never saw it

    mix test test/barkpark_web/live/studio/media_live_test.exs   # 3 tests, 0 failures
    grep -n 'init_test_session' test/barkpark_web/live/studio/media_live_test.exs
    #  9:  |> Plug.Test.init_test_session(%{"api_token" => "barkpark-dev-token"})

Every Studio media test seeds a TOKEN principal. There is no user-session arm,
so the suite is structurally blind to #15. Locally it is doubly invisible:
`dev_browser_token_fallback()` hands dev an admin token regardless of session.

## Residual (what is NOT proven)

That Gyldendal's non-admins were account/SSO logins rather than token logins.
Prod credentials were not available; the mechanism is proven from the code path
plus the anonymous arm, which is the identical `cond` branch. Ask Gyldendal how
their non-admin users signed in before building a permission-tier fix.

## Do NOT build

Do not port an AssignDefaultScope / DeriveWorkspaceFromToken change to #15 —
`:scoped_api` never runs AssignDefaultScope, and the flat 200 above proves the
Default pinning is what makes the flat surface WORK. A D6 regression risk.
