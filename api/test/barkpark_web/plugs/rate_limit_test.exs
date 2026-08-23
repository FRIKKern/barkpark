defmodule BarkparkWeb.Plugs.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias BarkparkWeb.Plugs.RateLimit

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  defp with_limits(overrides) do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(
        [read_per_minute: 300, write_per_minute: 60, datasets: %{}],
        overrides
      )
    )
  end

  defp build(method, path, path_params \\ %{}, headers \\ []) do
    conn = build_conn(method, path, "")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    %{conn | path_params: path_params}
  end

  test "GETs are billed against the read bucket (burst = read_per_minute)" do
    with_limits(read_per_minute: 2, write_per_minute: 1)

    c1 =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer get-token"}
      ])

    refute RateLimit.call(c1, RateLimit.init([])).halted
    refute RateLimit.call(c1, RateLimit.init([])).halted
    out = RateLimit.call(c1, RateLimit.init([]))
    assert out.halted
    assert out.status == 429
  end

  test "POSTs have their own bucket (GET exhaustion does not affect POST)" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    get_conn =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer same-token"}
      ])

    post_conn =
      build(:post, "/v1/data/mutate/production", %{"dataset" => "production"}, [
        {"authorization", "Bearer same-token"}
      ])

    assert RateLimit.call(get_conn, RateLimit.init([])).halted == false
    assert RateLimit.call(get_conn, RateLimit.init([])).halted == true

    # The POST bucket is untouched — still has its allowance
    assert RateLimit.call(post_conn, RateLimit.init([])).halted == false
  end

  test "429 response uses retry_after envelope and header" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn =
      build(:post, "/v1/data/mutate/production", %{"dataset" => "production"}, [
        {"authorization", "Bearer retry-token"}
      ])

    _ = RateLimit.call(conn, RateLimit.init([]))
    denied = RateLimit.call(conn, RateLimit.init([]))

    assert denied.halted
    assert denied.status == 429

    [retry_after_hdr] = Plug.Conn.get_resp_header(denied, "retry-after")
    assert retry_after_hdr == "60"

    body = Jason.decode!(denied.resp_body)
    assert body["error"]["code"] == "rate_limited"
    assert body["error"]["details"]["retry_after"] == 60
  end

  test "per-dataset override wins over defaults" do
    with_limits(
      read_per_minute: 1,
      write_per_minute: 1,
      datasets: %{"staging" => %{read: 3}}
    )

    conn =
      build(:get, "/v1/data/query/staging/post", %{"dataset" => "staging"}, [
        {"authorization", "Bearer ds-token"}
      ])

    # Default read would allow 1; override bumps it to 3
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == true
  end

  test "unauthenticated callers are bucketed by IP" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})

    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == true
  end

  test "different IPs have independent buckets" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn_a = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})
    conn_a = %{conn_a | remote_ip: {10, 0, 0, 1}}
    conn_b = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})
    conn_b = %{conn_b | remote_ip: {10, 0, 0, 2}}

    assert RateLimit.call(conn_a, RateLimit.init([])).halted == false
    assert RateLimit.call(conn_a, RateLimit.init([])).halted == true
    assert RateLimit.call(conn_b, RateLimit.init([])).halted == false
  end

  test "ConnCase private scopes isolate otherwise identical token buckets" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn_a =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer scoped-token"}
      ])
      |> put_private(:barkpark_rate_limit_scope, "test-a")

    conn_b =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer scoped-token"}
      ])
      |> put_private(:barkpark_rate_limit_scope, "test-b")

    refute RateLimit.call(conn_a, RateLimit.init([])).halted
    assert RateLimit.call(conn_a, RateLimit.init([])).halted

    refute RateLimit.call(conn_b, RateLimit.init([])).halted
    assert RateLimit.call(conn_b, RateLimit.init([])).halted
  end

  test "ConnCase assigns a server-owned limiter scope", %{conn: conn} do
    assert is_binary(conn.private[:barkpark_rate_limit_scope])
  end

  # The shape every production instance actually runs: Caddy sits on the box and
  # reverse-proxies `localhost:4000`, so for ANONYMOUS traffic `conn.remote_ip`
  # is always 127.0.0.1 and the caller's real address exists only in the chain
  # Caddy appended. "different IPs have independent buckets" above never catches
  # that — it hands the plug two distinct non-loopback PEERS, which is a shape no
  # proxied deployment produces. Keying on the peer therefore shipped
  # BARKPARK_RATE_LIMIT_READ (300/min) and _WRITE (60/min) as ONE global budget
  # for the entire anonymous internet, and one caller could starve every other.
  #
  # PROTECTIVE, not vacuous — the two mutations these tests exist to catch:
  #
  #   1. the defect itself, `ip = conn.remote_ip |> :inet.ntoa() |> to_string()`
  #      → "two anonymous callers ... do NOT share a bucket" REDS (B is refused
  #      on its first request because A already spent the one loopback bucket);
  #   2. the NAIVE over-fix, reading the first `x-forwarded-for` hop directly
  #      instead of going through the trust boundary → "a direct caller's forged
  #      chain cannot mint a fresh bucket" REDS (the forger gets a new budget per
  #      spelling, i.e. no limit at all).
  describe "behind the co-located Caddy (the shape every prod instance runs)" do
    # Loopback is trusted UNCONDITIONALLY by Barkpark.RateLimiter (never listed in
    # BARKPARK_TRUSTED_PROXIES) precisely because Caddy is co-located — so these
    # fixtures need no config setup to be the real prod shape.
    @front_peer {127, 0, 0, 1}

    # TEST-NET-2: two distinct anonymous callers arriving through that one front.
    @caller_a "198.51.100.10"
    @caller_b "198.51.100.11"

    # A caller that reached the box DIRECTLY — public, untrusted, so whatever it
    # writes into the chain carries no authority.
    @direct_peer {203, 0, 113, 66}

    defp proxied(chain, peer \\ @front_peer) do
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})
      |> Map.put(:remote_ip, peer)
      |> put_req_header("x-forwarded-for", chain)
    end

    defp allowed?(conn), do: not RateLimit.call(conn, RateLimit.init([])).halted

    test "two anonymous callers through the same trusted front do NOT share a bucket" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      a = proxied(@caller_a)
      b = proxied(@caller_b)

      # The premise, asserted rather than assumed: both requests present the SAME
      # loopback peer. If this ever stops holding the test is measuring nothing.
      assert a.remote_ip == @front_peer
      assert b.remote_ip == @front_peer

      assert allowed?(a)
      # A has spent its own 1/min budget...
      refute allowed?(a)
      # ...and B, behind the identical front, still has all of its own.
      assert allowed?(b)
    end

    test "one caller's repeated requests still share ITS bucket (the cap is real)" do
      with_limits(read_per_minute: 2, write_per_minute: 1)

      # Guards the lazy way to pass the test above: minting a fresh key per
      # request would give independent buckets AND no rate limit whatsoever.
      assert allowed?(proxied(@caller_a))
      assert allowed?(proxied(@caller_a))
      refute allowed?(proxied(@caller_a))
    end

    test "a caller-supplied PREFIX behind our own front is discarded" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      # Caddy APPENDS the address it actually saw, so the rightmost hop is the
      # only trustworthy one. A caller that pre-seeds the header still keys on
      # the address Caddy observed — it cannot rotate its own bucket.
      assert allowed?(proxied("9.9.9.9, #{@caller_a}"))
      refute allowed?(proxied("1.1.1.1, #{@caller_a}"))
    end

    test "a direct caller's forged chain cannot mint a fresh bucket" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      # Peer is untrusted, so the header is ignored entirely and both requests
      # key on the verified peer address.
      assert allowed?(proxied("9.9.9.9", @direct_peer))
      refute allowed?(proxied("8.8.8.8", @direct_peer))
    end
  end
end
