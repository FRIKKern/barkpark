# Re-derivation recipe — /v1/access crash reachability (tenancy-auth totality wave)

Verifier lane: access-endpoints-live-reachability. Measured 2026-08-19 against a
LOCAL dev server (`mix phx.server`, cwd `/Volumes/SATECHI/github/barkpark/api`),
whose `api/lib/barkpark/tenancy/`, `access_controller.ex`, `access.ex` and
`router.ex` are byte-identical to `origin/main` (bf499f54) — verified with
`git diff --stat origin/main..HEAD -- <those paths>` → empty.

## VERDICT: finding CONFIRMED as reachable, PREMISE CORRECTED on the status code

Both `/v1/access` endpoints crash inside `Barkpark.Tenancy.Auth`, reachable by
the weakest possible principal (any non-`public-read` api_token, no membership
required). But the response is **HTTP 400, not 500** — `phoenix_ecto` ships a
`Plug.Exception` impl mapping `Ecto.Query.CastError → 400`.

## Recipe

1. Confirm the running server matches origin/main for the fenced paths:

       git diff --stat origin/main..HEAD -- api/lib/barkpark/tenancy/ \
         api/lib/barkpark_web/controllers/access_controller.ex \
         api/lib/barkpark/access.ex api/lib/barkpark_web/router.ex

2. Mint a plain NON-ADMIN token (`permissions: ["read"]`); note the arity —
   `create_token/5` is `(raw_token, label, dataset, permissions, workspace_id \\ nil)`,
   NOT the `create_token("probe", ["read"])` shape some briefs quote:

       cd api && MIX_ENV=dev mix run -e '
         raw = "probe_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
         {:ok, t} = Barkpark.Auth.create_token(raw, "probe", "production", ["read"])
         IO.puts("TOKEN=" <> raw)'

3. Drive the matrix:

       curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
         'http://localhost:4000/v1/access?workspace_id=zzz'                       # 400
       curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
         'http://localhost:4000/v1/access?workspace_id='                          # 422
       curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
         'http://localhost:4000/v1/access?workspace_id=00000000-0000-0000-0000-000000000001'  # 403
       curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
         -H 'content-type: application/json' \
         -d '{"workspace_id":"zzz","grantee_email":"x@example.com","capabilities":["read"]}' \
         http://localhost:4000/v1/access                                          # 400
       # same POST with "workspace_id":""                                          # 400
       # same POST with a valid non-member uuid                                     # 403

4. The dev debug page names the exact raise site:

       ** (Ecto.Query.CastError) lib/barkpark/tenancy/auth.ex:145:
          value `"zzz"` cannot be dumped to type :binary_id
       (barkpark) lib/barkpark/tenancy/auth.ex:156: Barkpark.Tenancy.Auth.member?/2
       (barkpark) lib/barkpark/tenancy/auth.ex:172: Barkpark.Tenancy.Auth.authorize/3
       (barkpark) lib/barkpark/access.ex:479: anonymous fn/4 in Barkpark.Access.authorize_capabilities/3

## Status-code truth (the correction)

    deps/phoenix_ecto/lib/phoenix_ecto/plug.ex:2-3
      {Ecto.CastError, 400}, {Ecto.Query.CastError, 400}
    deps/plug/lib/plug/exceptions.ex:52
      def status(_), do: 500        # the Any fallback — FunctionClauseError lands here

So: non-castable STRING id → 400; nil / non-binary id (FunctionClauseError) → 500.
`GET|POST /v1/access` can only reach the STRING class (GET's
`fetch_workspace_id/1` requires `is_binary(id) and id != ""`; mint's
`fetch(attrs, :workspace_id)` requires `is_binary`), so at THESE two endpoints
the fix converts **400 → 403**, not 500 → 403. ~15 in-repo comments and the
filed task `arpss-w8-tenancy-auth-not-total` say "→ 500" for the CastError
class; that is folklore.

In prod (`debug_errors` unset outside dev) the body is
`BarkparkWeb.ErrorJSON`'s crash envelope — `code: "internal_error"` with the
fault family appended — served at HTTP 400. An `internal_error` code at a 400
status is itself the tell.

## Principal classes reaching the route

`scope "/v1"` → `pipe_through([:api, :require_token])` (router.ex:1953-1958).
`:require_token` = `RequireToken` + `PublicRead`. `PublicRead` clamps ONLY
tokens carrying `"public-read"` in `permissions`. Nothing in either pipeline
validates `workspace_id` as a UUID. Therefore: **every api_token without the
`public-read` permission reaches the crash, with no membership and no admin
role required.** Anonymous → 401 (measured).
