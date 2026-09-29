defmodule BarkparkWeb.Plugs.IdempotencyBodyStateGuardTest do
  @moduledoc """
  TRIPWIRE for acpc-bl-idempotency-chunked-trap.

  `Idempotency.register_complete/3` caches `sent.resp_body` from a
  `register_before_send/2` callback. Plug runs that callback for FOUR distinct
  send shapes, stamping a different `conn.state` on each
  (`deps/plug/lib/plug/conn.ex`):

      444  run_before_send(conn, :set)           # send_resp/3      — body is a term
      495  run_before_send(%{... resp_body: nil}, :set_file)     # send_file/3..5
      526  run_before_send(conn, :set_chunked)   # send_chunked/2   — resp_body nil'd at :525
      1474 run_before_send(%{... status: 101}, :set_upgrade)     # upgrade_adapter/3

  Only `:set` carries a body. Under the other three the plug would cache an
  EMPTY body against a live idempotency key and replay an empty 200 for the
  lifetime of that key.

  No such route exists today — both Idempotency mounts (router.ex:456 in the
  scoped write chain, router.ex:1113 pipeline `:idempotent`) are JSON mutate
  pipelines, and every `send_chunked/2` in the tree is a GET/SSE action. These
  tests are the tripwire that makes the FIRST streaming or file-sending mutate
  route red loudly in test instead of poisoning keys in prod.
  """

  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Idempotency
  alias BarkparkWeb.Plugs.Idempotency, as: Plug

  @path "/v1/data/mutate/production"

  setup do
    {:ok, token} = Auth.create_token("idem-body-state-token", "test", "dev", ["read", "write"])
    %{token: token}
  end

  defp claimed_conn(token, key) do
    conn =
      build_conn(:post, @path, "")
      |> assign(:api_token, token)
      |> put_req_header("idempotency-key", key)

    c = Plug.call(conn, Plug.init([]))
    refute c.halted, "the plug should have CLAIMED this key, not halted it"
    c
  end

  defp hash_for(token, key), do: Idempotency.hash_key(key, token.id, "POST", @path)

  # RED on the unguarded plug: no raise at all, and the key is left holding a
  # `completed` row whose body is "" — every later request with this key
  # replays an empty 200.
  test "a chunked response under an idempotency key REFUSES to cache", %{token: token} do
    key = "chunked-guard-key"
    c = claimed_conn(token, key)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/:set_chunked/, fn ->
          send_chunked(c, 200)
        end
      end)

    assert log =~ "Idempotency refused to cache",
           "the guard must report the invariant violation, not fail silently"

    assert :miss = Idempotency.lookup(hash_for(token, key))
  end

  # The consequence stated as its own assertion, so the RED reads as the bug and
  # not merely as a missing raise: on the unguarded plug this is
  #   {:ok, %{status: 200, body: ""}}
  test "a chunked response never leaves an EMPTY body replayable under the key", %{token: token} do
    key = "chunked-empty-body-key"
    c = claimed_conn(token, key)

    _ =
      capture_log(fn ->
        try do
          send_chunked(c, 200)
        rescue
          _ -> :refused
        end
      end)

    # Bind FIRST, then assert: `assert pattern = expr, message` would die of a
    # MatchError before the message is ever reached (scripts/unreachable-assert-message-check.sh).
    cached = Idempotency.lookup(hash_for(token, key))

    assert cached == :miss,
           "a chunked send must leave NO cache entry — an empty-bodied entry replays " <>
             "an empty 200 for the key's lifetime. Got: #{inspect(cached)}"
  end

  # THE ARM THE FILING MISSED. `send_file/3..5` also nils `resp_body` before
  # running before_send (conn.ex:495), so it is the same trap with a different
  # state. An allowlist on `:set` covers it; a `:set_chunked`-only denylist
  # would not.
  test "a send_file response under an idempotency key REFUSES to cache", %{token: token} do
    key = "sendfile-guard-key"
    c = claimed_conn(token, key)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/:set_file/, fn ->
          send_file(c, 200, __ENV__.file)
        end
      end)

    assert log =~ "Idempotency refused to cache"
    assert :miss = Idempotency.lookup(hash_for(token, key))
  end

  # The claim must be RELEASED, not wedged: the refusal is a programming error
  # on the server, and the key must not 409 forever after it.
  test "the refused claim is released so the key is not wedged", %{token: token} do
    key = "chunked-release-key"
    c = claimed_conn(token, key)

    _ =
      capture_log(fn ->
        try do
          send_chunked(c, 200)
        rescue
          _ -> :refused
        end
      end)

    retry = claimed_conn(token, key)
    refute retry.halted
  end

  # CONTROL — the guard is an allowlist on `:set`, so the ordinary JSON path is
  # untouched: it still caches and still replays. If this test ever fails
  # alongside the ones above, the guard is over-broad, not correct.
  test "CONTROL: a normal JSON send under the same shape still caches and replays", %{
    token: token
  } do
    key = "control-json-key"
    body = ~s({"transactionId":"tx-control","results":[]})

    c = claimed_conn(token, key)

    sent =
      c
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)

    assert sent.status == 200
    assert {:ok, %{status: 200, body: ^body}} = Idempotency.lookup(hash_for(token, key))

    replay =
      build_conn(:post, @path, "")
      |> assign(:api_token, token)
      |> put_req_header("idempotency-key", key)
      |> Plug.call(Plug.init([]))

    assert replay.halted
    assert replay.status == 200
    assert replay.resp_body == body
  end
end
