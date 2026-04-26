defmodule BarkparkWeb.Plugs.IdempotencyTest do
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.Plugs.Idempotency, as: Plug
  alias Barkpark.{Auth, Idempotency}

  setup do
    {:ok, token} = Auth.create_token("idem-test-token", "test", "dev", ["read", "write"])
    %{token: token}
  end

  defp build_mutate_conn(token, key \\ nil) do
    conn =
      build_conn(:post, "/v1/data/mutate/production", "")
      |> assign(:api_token, token)

    if key, do: put_req_header(conn, "idempotency-key", key), else: conn
  end

  test "passes through when no Idempotency-Key header is present", %{token: token} do
    conn = build_mutate_conn(token)
    result = Plug.call(conn, Plug.init([]))
    refute result.halted
    assert result.resp_body == nil
  end

  test "passes through on non-mutating methods", %{token: token} do
    conn =
      build_conn(:get, "/v1/data/query/production/post", "")
      |> assign(:api_token, token)
      |> put_req_header("idempotency-key", "k")

    result = Plug.call(conn, Plug.init([]))
    refute result.halted
  end

  test "first request stores the response; second replays it", %{token: token} do
    conn1 = build_mutate_conn(token, "key-1")
    c1 = Plug.call(conn1, Plug.init([]))
    refute c1.halted

    c1_sent =
      c1
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"transactionId":"tx1","results":[]}))

    assert c1_sent.status == 200
    assert c1_sent.resp_body == ~s({"transactionId":"tx1","results":[]})

    # Second call with same key replays
    conn2 = build_mutate_conn(token, "key-1")
    c2 = Plug.call(conn2, Plug.init([]))

    assert c2.halted
    assert c2.status == 200
    assert c2.resp_body == ~s({"transactionId":"tx1","results":[]})

    assert [{"idempotency-replay", "true"}] =
             Enum.filter(c2.resp_headers, fn {k, _} -> k == "idempotency-replay" end)
  end

  test "does not store 5xx responses", %{token: token} do
    conn = build_mutate_conn(token, "key-5xx")
    c = Plug.call(conn, Plug.init([]))
    refute c.halted

    _ = c |> send_resp(500, ~s({"error":"boom"}))

    hash = Idempotency.hash_key("key-5xx", token.id, "POST", "/v1/data/mutate/production")
    assert :miss = Idempotency.lookup(hash)
  end

  test "halts with 401 when Idempotency-Key is sent without an api_token" do
    conn =
      build_conn(:post, "/v1/data/mutate/production", "")
      |> put_req_header("idempotency-key", "k")

    c = Plug.call(conn, Plug.init([]))
    assert c.halted
    assert c.status == 401
  end
end
