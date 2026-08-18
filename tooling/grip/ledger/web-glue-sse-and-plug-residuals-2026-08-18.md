# Re-derivation recipe — SSE double-send + plug-halt residuals (web-glue robustness wave)

Pinned tree: `origin/main` @ `228090798bf50a3ae2bb15699c04ddf65b2dcdd2`.
Verdict: **0 findings across all three residuals.** Every claim below is
re-derivable by the exact command shown.

## (a) chat_controller SSE — no double send after `send_chunked`

    git show origin/main:api/lib/barkpark_web/controllers/chat_controller.ex | sed -n '392,560p'
    git show origin/main:api/lib/barkpark_web/controllers/chat_controller.ex | sed -n '633,730p'

Both chunked actions (`events/2` L392, `fleet_events/2` L452) reach
`send_chunked(200)` only after every possible refusal (`not_found/1` on a
wrong-tenant id at L403). After `send_chunked`, EVERY write goes through
`Plug.Conn.chunk/2` inside a `case` — `chunk_or_stop/2` (L674),
`fleet_chunk_or_stop/4` (L535), `chunk_fleet/2` (L493), `stable_snapshot/2`
(L699), `replay/3` (L715). Zero `put_status` / `json` / `send_resp` exists on
any post-chunk path.

The residual hazard (a RAISE after `send_chunked` — e.g. `Jason.encode!`, or
`StudioChat.fleet_snapshot/1` inside `emit_fleet_open/6`, both of which run
post-chunk) is absorbed, not double-sent:

    grep -n "def send_chunked" -A 8 api/deps/plug/lib/plug/conn.ex     # owner && send(owner, @already_sent)
    sed -n '52,64p' api/deps/phoenix/lib/phoenix/endpoint/render_errors.ex   # receive @already_sent -> %{conn | state: :sent}

Executable probe (scratchpad, not committed):
`scratchpad/sse_double_send_probe.exs`, run as
`cd api && MIX_ENV=test mix test <probe>` → 3 tests, 0 failures. It proves
(i) `send_resp` on a `:chunked` conn DOES raise `AlreadySentError` (hazard is
real), (ii) `send_chunked` stamps `{:plug_conn, :sent}`, (iii)
`Phoenix.Endpoint.RenderErrors.__catch__/5` on a chunked conn short-circuits to
`:sent` and re-raises the original reason with no second send attempt.

## (b) resolve_workspace.ex / idempotency.ex — every response path halts

    git show origin/main:api/lib/barkpark_web/plugs/resolve_workspace.ex | sed -n '60,140p'
    git show origin/main:api/lib/barkpark_web/plugs/idempotency.ex

`ResolveWorkspace`: 3 response paths — `halt_envelope/2` from `call/2`'s
not-found arm (L76), the studio-demo `redirect |> halt()` cond arm (L124-131),
and `halt_envelope/2` from the `true ->` cond arm (L134). All halt. The other
3 cond arms are assign-only. The early clause
`call(%{assigns: %{share_public: true}} = conn, _opts), do: conn` (L66) returns
WITHOUT assigning `:current_workspace` — but all three `share_public` writers
co-assign it in the same pipe:

    git grep -n "share_public" origin/main -- api/lib
    # require_share_scope.ex:148 / :185, require_share_edit_token.ex:97

so no downstream nil. `RequireWithinQuota.call/2` additionally case-matches
`conn.assigns[:current_workspace]` with a nil catch-all.

`Idempotency`: 3 response paths — `unauthorized/1` (delegates to
`ErrorResponse.emit/3`, which halts), `in_progress/1` (json + halt),
`replay/2` (send_resp + halt).

## (c) response helpers OUTSIDE plugs/ — all halt or emit nothing

    git show origin/main:api/lib/barkpark_web/error_response.ex   # write/2 = put_status |> json |> halt
    git show origin/main:api/lib/barkpark/content/errors.ex | grep -n "send_resp\|halt(\|Phoenix.Controller.json"   # no hits
    git show origin/main:api/lib/barkpark_web/error_envelope.ex | grep -n "halt\|send_resp\|json(\|put_status"      # no hits (pure serializer)
    git grep -n "plug BarkparkWeb.FallbackController" origin/main -- api/lib                                        # no hits

`BarkparkWeb.ErrorResponse` is the only out-of-tree helper a plug delegates to
(`idempotency`, `github_webhook_signature`, `optional_user_session`,
`public_read`, `require_bearer_or_session_token`, `require_ingest_token`,
`require_media_processing_callback_token`, `require_principal_user`,
`require_ticket_key`, `require_user_session`), and its private `write/2` halts.
`BarkparkWeb.Endpoint.parse_error_json/3` (endpoint.ex:186) routes through the
same halting emitter, and `plug :parse_body` sits in a `Plug.Builder` pipeline
(endpoint.ex:114) so the halt is honoured.

## Whole-tree halt sweep (49/49 plugs)

    git ls-tree -r origin/main --name-only | grep -c '^api/lib/barkpark_web/plugs/.*\.ex$'   # 49
    for f in $(git ls-tree -r origin/main --name-only | grep '^api/lib/barkpark_web/plugs/'); do \
      body=$(git show origin/main:$f); \
      if echo "$body" | grep -qE "send_resp\(|send_chunked\(|Phoenix\.Controller\.(json|redirect|text|html)\(" \
         && ! echo "$body" | grep -q "halt()"; then echo "$f"; fi; done
    # → empty

## Green baseline (executed, not read)

    cd api && MIX_ENV=test mix test test/barkpark_web/plugs/        # 220 tests, 0 failures
    cd api && MIX_ENV=test mix test test/barkpark_web/controllers/chat_controller_test.exs \
                                   test/barkpark_web/controllers/chat_fleet_events_test.exs   # 103 tests, 0 failures

## Parked, NOT a finding

`Idempotency.register_complete/3` caches `sent.resp_body` in a
`register_before_send` callback. `send_chunked/2` also runs before_send
(`run_before_send(conn, :set_chunked)`), so a CHUNKED response under the
idempotency pipeline would cache an empty body and replay an empty 200. No such
route exists today: both mount points (router.ex:275 `:scoped_api` write chain,
router.ex:776 `:idempotent`) are JSON mutate pipelines; the only chunked actions
in the tree are GET SSE routes. Recorded so a future streaming mutate route does
not re-open it silently.
