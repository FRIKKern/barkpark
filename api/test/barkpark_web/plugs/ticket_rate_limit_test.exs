defmodule BarkparkWeb.Plugs.TicketRateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.Plugs.TicketRateLimit

  setup do
    original = Application.get_env(:barkpark, :ticket_rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :ticket_rate_limits, original) end)
    :ok
  end

  # The RateLimiter ETS table is process-independent and lives across tests, so
  # each test uses a UNIQUE key id to keep its buckets isolated.
  defp unique_key, do: "key-" <> Integer.to_string(System.unique_integer([:positive]))

  defp with_limits(overrides) do
    Application.put_env(
      :barkpark,
      :ticket_rate_limits,
      Keyword.merge([create: 10, message: 60, attachment: 30], overrides)
    )
  end

  # A conn as it looks AFTER RequireTicketKey — the key row hand-assigned.
  defp build(method, path, key_id) do
    build_conn(method, path, "")
    |> assign(:ticket_key, %{id: key_id})
  end

  defp run(conn), do: TicketRateLimit.call(conn, TicketRateLimit.init([]))

  test "Nth create write over the limit → 429 with Retry-After header and envelope body" do
    with_limits(create: 2)
    key = unique_key()

    # Budget of 2: first two creates pass, the third is throttled.
    refute run(build(:post, "/v1/tickets", key)).halted
    refute run(build(:post, "/v1/tickets", key)).halted

    denied = run(build(:post, "/v1/tickets", key))
    assert denied.halted
    assert denied.status == 429

    # ceil(3600 / 2) = 1800 seconds to earn one token back.
    assert Plug.Conn.get_resp_header(denied, "retry-after") == ["1800"]

    body = Jason.decode!(denied.resp_body)
    assert body["error"]["code"] == "rate_limited"
    assert body["error"]["details"]["retry_after"] == 1800
  end

  test "reads always pass — the polling loop is never throttled" do
    # Even with an absurdly small budget, GET/HEAD are exempt: hammer well past
    # any conceivable write limit and nothing halts.
    with_limits(create: 1, message: 1, attachment: 1)
    key = unique_key()

    for _ <- 1..50 do
      refute run(build(:get, "/v1/tickets/abc", key)).halted
      refute run(build(:get, "/v1/tickets", key)).halted
      refute run(build(:get, "/v1/tickets/abc/attachments/asset-1", key)).halted
      refute run(build(:head, "/v1/tickets/abc", key)).halted
    end
  end

  test "distinct keys get distinct buckets" do
    with_limits(create: 1)
    key_a = unique_key()
    key_b = unique_key()

    # key_a exhausts its create budget...
    refute run(build(:post, "/v1/tickets", key_a)).halted
    assert run(build(:post, "/v1/tickets", key_a)).halted

    # ...but key_b's bucket is untouched.
    refute run(build(:post, "/v1/tickets", key_b)).halted
  end

  test "distinct classes get distinct buckets for the same key" do
    with_limits(create: 1, message: 1, attachment: 1)
    key = unique_key()

    # Exhaust the :create bucket.
    refute run(build(:post, "/v1/tickets", key)).halted
    assert run(build(:post, "/v1/tickets", key)).halted

    # :message and :attachment for the same key are independent.
    refute run(build(:post, "/v1/tickets/abc/messages", key)).halted
    refute run(build(:post, "/v1/tickets/abc/attachments", key)).halted

    # ...and each has its own budget that also exhausts independently.
    assert run(build(:post, "/v1/tickets/abc/messages", key)).halted
    assert run(build(:post, "/v1/tickets/abc/attachments", key)).halted
  end

  test "message and attachment classes carry their own Retry-After math" do
    with_limits(message: 60, attachment: 30)
    key = unique_key()

    # Exhaust message (60/hour → ceil(3600/60) = 60s).
    for _ <- 1..60, do: refute(run(build(:post, "/v1/tickets/abc/messages", key)).halted)
    msg_denied = run(build(:post, "/v1/tickets/abc/messages", key))
    assert msg_denied.halted
    assert Plug.Conn.get_resp_header(msg_denied, "retry-after") == ["60"]

    # Exhaust attachment (30/hour → ceil(3600/30) = 120s).
    for _ <- 1..30, do: refute(run(build(:post, "/v1/tickets/abc/attachments", key)).halted)
    att_denied = run(build(:post, "/v1/tickets/abc/attachments", key))
    assert att_denied.halted
    assert Plug.Conn.get_resp_header(att_denied, "retry-after") == ["120"]
  end

  test "with no resolved ticket key assigned, the plug passes through (no crash)" do
    conn = build_conn(:post, "/v1/tickets", "")
    refute run(conn).halted
  end
end
