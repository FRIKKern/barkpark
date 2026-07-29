# ssw9 — transport-hop-decision: re-derivation recipes

Site Spawner Wave 9 verifier. Every claim below re-derives from scratch on a clean checkout.
Run from repo root unless noted.

## The box's parser ceiling for a base64'd artifact (option A)

    git show origin/main:api/lib/barkpark_web/endpoint.ex | sed -n '115,148p'

Then the RUN proof (real bodies through the exact same Plug.Parsers config):

    cd api && CC=clang MIX_ENV=test mix run --no-start /path/to/parse.exs

parse.exs body:

    opts = Plug.Parsers.init(parsers: [:urlencoded, :multipart, :json], pass: ["*/*"],
      json_decoder: Jason, length: 100_000_000,
      body_reader: {BarkparkWeb.Plugs.CacheBodyReader, :read_body, []})
    raw  = :crypto.strong_rand_bytes(n)
    json = Jason.encode!(%{"slug"=>"demo","build_id"=>"b1","mode"=>"deploy","artifact_b64"=>Base.encode64(raw)})
    conn = Plug.Test.conn(:post, "/v1/admin/site-deploy", json)
           |> Plug.Conn.put_req_header("content-type", "application/json")
    Plug.Parsers.call(conn, opts)   # rescue Plug.Parsers.RequestTooLargeError

Expected: 16KB→4ms ok · 1MB→1ms ok · 18MB→33ms ok · 76MB→RequestTooLargeError.
Raw-artifact ceiling = 100_000_000 * 3/4 = 75_000_000 B.

## base64 + JSON round-trip cost

    cd api && CC=clang MIX_ENV=test mix run --no-start /path/to/b64.exs

Expected inflation ×1.333 exactly; 18MB: encode64 32ms / Jason.encode 84ms /
Jason.decode 52ms / decode64 127ms (≈300ms CPU per hop, ×2 hops).

## Unknown DeployRequest fields are SILENTLY DROPPED (the green-lie trap)

    cd api && CC=clang MIX_ENV=test mix run --no-start -e '
    {:ok, r} = Barkpark.Sites.DeployRequest.new(%{"slug"=>"demo","mode"=>"deploy","build_id"=>"b1","artifact_b64"=>"AAAA"})
    IO.inspect(r)'

Expected: no :artifact_b64 in the struct. Contrast with an unknown `env` key,
which 400s `invalid_env`. The top-level map has no allow-list.

## The relay transport's hard timeout

    git show origin/main:cloud/lib/barkpark_cloud/billing/http_client.ex | sed -n '40,50p;180,197p'
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '2992,3000p'

Expected: `@timeout 15_000`, `@connect_timeout 10_000`, default module
`BarkparkCloud.Billing.HttpClient` (verified-TLS :httpc).

## The CP has NO durable filesystem (kills `file://` and any CP-side artifact dir)

    git show origin/main:cloud/docker-compose.yml | grep -n "volumes:" -A 4
    git show origin/main:cloud/config/runtime.exs | sed -n '244,255p'

Expected: `x-control-plane` anchor declares NO `volumes:` key at all; only `db`
and `postfix` mount volumes. `artifact_dir` defaults to
`/var/lib/barkpark-cloud/artifacts` — inside the container's ephemeral layer,
and blue/green runs the two slots as DIFFERENT containers.

## Nothing on the box consumes an artifact

    git grep -n "artifact" origin/main -- api/lib/barkpark/sites/ deploy/
    git grep -rn "internal/builder" origin/main -- '*.go'

Expected: zero hits under api/lib/barkpark/sites/ and deploy/ (prose only);
internal/builder imported ONLY by cmd/barkpark-builder.

## The upload route is session-only (no PAT)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9973,9995p'

Expected: `with_team_site(conn, fun)` → `:session` → `Auth.require_user`.
`/deploy` uses `{:ability, "write"}` → `require_user_or_pat`.

## Box-side controller suite still green

    cd api && CC=clang MIX_ENV=test mix test test/barkpark_web/controllers/site_deploy_controller_test.exs

Expected: `23 tests, 0 failures`.
