# ssw8 — real-router certification + minted/revoked live probe (2026-08-17)

Re-derivation recipes for the ssw8 verifier verdicts. Every line below was run
against `origin/main` @ `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2` and live
`https://guerrilla.barkpark.cloud`.

## R1 — the enforcement suite is green and drives the REAL Endpoint

    cd /Volumes/SATECHI/github/barkpark/api && \
      mix test test/barkpark_web/integration/public_read_enforcement_test.exs 2>&1 | tail -4
    # => 22 tests, 0 failures

    git show origin/main:api/test/support/conn_case.ex | grep -n '@endpoint\|Phoenix.ConnTest'
    # => 23:  @endpoint BarkparkWeb.Endpoint   (ConnCase = real router/endpoint)

Non-vacuity anchor: the `a read token still gets 200 on export` case asserts
`content-type == ["application/x-ndjson; charset=utf-8"]`, which only
ExportController through the router can produce.

## R2 — the scoped-`listen` 403 arm is ABSENT from the suite

    git show origin/main:api/test/barkpark_web/integration/public_read_enforcement_test.exs \
      | grep -n 'leak_routes' -A 8
    # @leak_routes = export | analytics | history | revision   (each FLAT + SCOPED)

    git show origin/main:api/test/barkpark_web/integration/public_read_enforcement_test.exs \
      | grep -n 'listen'
    # only ONE listen test, on /v1/data/listen/... (FLAT). No scoped mirror.

The scoped route EXISTS and rides the clamped pipeline:

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2332,2341p'
    # scope "/w/:workspace_slug/p/:project_slug" ; pipe_through([:scoped_api, :require_token])
    #   get("/v1/data/listen/:dataset", ListenController, :listen)

    git show origin/main:api/lib/barkpark_web/router.ex | awk '/pipeline :require_token do/,/^  end/'
    # plug(BarkparkWeb.Plugs.RequireToken) ; plug(BarkparkWeb.Plugs.PublicRead)

Verdict: TEST-COVERAGE hole, not a runtime hole (R4 proves scoped listen 403s live).

## R3 — public_read_test.exs really is hand-built-conn unit territory

    git show origin/main:api/test/barkpark_web/plugs/public_read_test.exs | grep -n 'build_conn'
    # every case is `build_conn(...) |> run(token)`, i.e. PublicRead.call/2 direct.
    # Lines 115/125/135/144 are the query/doc/mutate cases; 133/143 are their tails.
    # Lines 154-160 are the comment recording that the listen + schemas cases were
    # MOVED out of this file to the real endpoint precisely because they were vacuous.

## R4 — live mint → 10-arm probe → admin-bearer revoke → dead

    A=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    H=https://guerrilla.barkpark.cloud

    # mint
    P=$(curl -s -X POST $H/w/default/p/default/v1/tokens \
          -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
          -d '{"label":"verify-ssw8","permissions":["public-read"]}' \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

    # LIVENESS FIRST — otherwise a dead token 403s everything and the probe is vacuous
    curl -s -o /dev/null -w 'task %{http_code}\n' -H "Authorization: Bearer $P" \
      "$H/v1/data/query/production/task?limit=1"        # => 200

    # 10 arms: 5 routes x {flat, scoped}
    for p in /v1/data/export/production /v1/data/analytics/production \
             /v1/data/listen/production /v1/data/history/production/post/p1 \
             /v1/data/revision/production/00000000-0000-4000-8000-000000000000; do
      curl -s --max-time 8 -o /dev/null -w "FLAT   $p %{http_code}\n" -H "Authorization: Bearer $P" "$H$p"
      curl -s --max-time 8 -o /dev/null -w "SCOPED $p %{http_code}\n" -H "Authorization: Bearer $P" "$H/w/default/p/default$p"
    done
    # => 403 on all ten

    # TEARDOWN — the wave-8 SELF-revoke recipe is now 403'd by the very clamp:
    curl -s -X DELETE $H/v1/auth/app-tokens/current -H "Authorization: Bearer $P"
    # => 403 forbidden "public-read tokens may only read published public documents"

    # USE THE ADMIN-BEARER BODY REVOKE INSTEAD (router.ex:851):
    curl -s -X DELETE $H/v1/auth/app-tokens -H "Authorization: Bearer $A" \
      -H 'Content-Type: application/json' -d "{\"token\":\"$P\"}"
    # => {"id":"157cdfb1-...","revoked":true,"revoked_at":"2026-08-17T06:56:06Z"}

    # DEAD-CHECK MUST USE A BEARER-GATED ROUTE:
    curl -s -o /dev/null -w 'dead export %{http_code}\n' -H "Authorization: Bearer $P" "$H/v1/data/export/production"
    # => 401 unauthorized  (correct dead signal)

### TRAP — do not dead-check on /v1/data/query

    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $P" "$H/v1/data/query/production/task?limit=1"   # 200
    curl -s -o /dev/null -w '%{http_code}\n' "$H/v1/data/query/production/task?limit=1"                                  # 200 (anonymous)
    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer bp_totally_invalid_xyz" "$H/v1/data/query/production/task?limit=1"  # 200

A revoked token still gets 200 there because the route is ANONYMOUS-readable
(the pdf-bl-anon door). A dead-check on `query` reports FALSE ALIVE.

## Prior-art correction

`dr-bl-token-revoke-route-missing` / `task-1a9b89e4be002159` claim a minted
scoped token can never be revoked. As of this run that is STALE for the admin
path: `DELETE /v1/auth/app-tokens` with an admin bearer and `{"token": raw}`
revoked a live token and the token went 401. The remaining true gap is
SELF-revoke for a public-read holder, which the clamp now forbids.
