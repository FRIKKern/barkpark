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

  # The SAME defect the block above closes for the IP half, on the token half:
  # the bucket key must not be a function of a string the caller writes. Every
  # test ABOVE presents a bearer that exists nowhere in the database, so none of
  # them could ever distinguish "keyed on the raw header" from "keyed on the
  # resolved principal" — they all pin a SINGLE spelling and check that repeats
  # of it share a bucket. The adversary varies the spelling.
  #
  # PROTECTIVE, not vacuous. The mutation these exist to catch is the code they
  # replaced, `token_id = Barkpark.Auth.ApiToken.hash_token(raw)` with no
  # verification: restore it and "a rotating bearer cannot mint a fresh bucket"
  # REDS on the very first over-limit request, because the attacker's third
  # spelling is a third full bucket.
  describe "a bearer that resolves to no principal (the caller-chosen key)" do
    @attacker_peer {198, 51, 100, 200}

    defp attack(bearer, peer \\ @attacker_peer) do
      build(:post, "/v1/auth/request-reset", %{}, [{"authorization", "Bearer " <> bearer}])
      |> Map.put(:remote_ip, peer)
    end

    defp admitted?(conn), do: not RateLimit.call(conn, RateLimit.init([])).halted

    test "a rotating bearer cannot mint a fresh bucket — the limit still binds" do
      with_limits(read_per_minute: 1, write_per_minute: 2)

      # Three DIFFERENT random bearers, one attacker, one meter. This is the
      # /v1/auth/request-reset shape: `:user_auth` mounts this plug as its only
      # throttle, and each admitted request sends one email to an address the
      # caller names.
      bearers = for _ <- 1..3, do: Base.encode16(:crypto.strong_rand_bytes(16))

      # The premise, asserted rather than assumed: if the bearers were ever
      # equal this test would be measuring the ordinary same-token path.
      assert length(Enum.uniq(bearers)) == 3

      [b1, b2, b3] = bearers

      assert admitted?(attack(b1))
      assert admitted?(attack(b2))
      # write_per_minute is 2 and the budget is SHARED, so the third spelling
      # buys nothing. Before the fix each of these was a fresh 2-token bucket
      # and this line — and any number after it — was `true`.
      refute admitted?(attack(b3))
    end

    test "an unresolvable bearer lands in the SAME bucket as no bearer at all" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      anonymous =
        build(:post, "/v1/auth/request-reset", %{})
        |> Map.put(:remote_ip, @attacker_peer)

      # The anonymous request spends the one write token for this address...
      assert admitted?(anonymous)
      # ...and adding a bearer does not buy a second budget. A bearer nobody
      # vouched for is worth exactly what no bearer is worth.
      refute admitted?(attack(Base.encode16(:crypto.strong_rand_bytes(16))))
    end

    test "a REVOKED bearer falls back to the IP bucket" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      raw = "revoked-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      {:ok, token} = Barkpark.Auth.create_token(raw, "revoked", "production", ["read"])

      {:ok, _} =
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Barkpark.Repo.update()

      # `verify_token/1` refuses it, so it is not a principal — and a token the
      # server has stopped honouring must not keep a private budget.
      assert admitted?(attack(raw))
      refute admitted?(attack(raw))
    end
  end

  # A SCIM bearer is a `Barkpark.Scim.Token`, NOT an `ApiToken`, so
  # `Auth.verify_token/1` cannot resolve it — and `pipeline :scim` meters BEFORE
  # `RequireScimToken` resolves anything. The first cut of this fix therefore
  # sent every SCIM request to the IP bucket and collapsed an entire IdP's
  # provisioning traffic (many requests from ONE egress address is SCIM's normal
  # operating mode) into the anonymous per-IP budget: 18 SCIM tests went 429 in
  # CI, and production provisioning would have followed.
  #
  # Nothing in this file could have caught that, because nothing here knew a
  # second credential kind existed. That is the whole reason this block is here.
  describe "a SCIM bearer (a credential of a DIFFERENT kind)" do
    @idp_peer {198, 51, 100, 77}

    defp scim_token(slug) do
      {:ok, org} = Barkpark.Tenancy.create_organization(%{slug: slug, name: slug})
      {:ok, {raw, _tok}} = Barkpark.Scim.mint_token(org.id, "rate-limit-test")
      raw
    end

    defp scim_write(raw) do
      build(:post, "/scim/v2/Groups", %{}, [{"authorization", "Bearer " <> raw}])
      |> Map.put(:remote_ip, @idp_peer)
    end

    defp passes?(conn), do: not RateLimit.call(conn, RateLimit.init([])).halted

    test "two SCIM tokens from ONE address keep independent budgets" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      idp_a =
        scim_token("rl-scim-a-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))

      idp_b =
        scim_token("rl-scim-b-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))

      assert passes?(scim_write(idp_a))
      # A has spent its own 1/min budget...
      refute passes?(scim_write(idp_a))
      # ...and B, provisioning through the SAME egress address, still has all of
      # its own. Keyed on the IP this line reds, which is exactly the 429 CI saw.
      assert passes?(scim_write(idp_b))
    end

    test "one SCIM token's repeated requests still share ITS bucket" do
      with_limits(read_per_minute: 1, write_per_minute: 2)

      # Guards the lazy way to pass the test above — a verified SCIM caller is
      # still metered, it simply is not metered as an anonymous one.
      raw = scim_token("rl-scim-c-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))

      assert passes?(scim_write(raw))
      assert passes?(scim_write(raw))
      refute passes?(scim_write(raw))
    end

    test "a REVOKED SCIM token falls back to the IP bucket" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      slug = "rl-scim-d-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, org} = Barkpark.Tenancy.create_organization(%{slug: slug, name: slug})
      {:ok, {raw, tok}} = Barkpark.Scim.mint_token(org.id, "revoked")

      {:ok, _} =
        tok
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Barkpark.Repo.update()

      assert passes?(scim_write(raw))
      refute passes?(scim_write(raw))
    end
  end

  # Criterion 3: the fix must not cost a legitimate caller its own bucket.
  # Nothing in the file above proves this, because nothing above mints a token
  # that actually EXISTS — so IP fallback alone would have passed every one.
  describe "a bearer that DOES resolve to a principal" do
    @shared_peer {198, 51, 100, 30}

    defp mint(label) do
      raw = label <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      {:ok, _token} = Barkpark.Auth.create_token(raw, label, "production", ["read"])
      raw
    end

    defp read_with(raw) do
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer " <> raw}
      ])
      |> Map.put(:remote_ip, @shared_peer)
    end

    test "two live tokens from ONE address keep independent buckets" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      a = mint("tenant-a")
      b = mint("tenant-b")

      assert not RateLimit.call(read_with(a), RateLimit.init([])).halted
      # A has spent its own 1/min budget...
      assert RateLimit.call(read_with(a), RateLimit.init([])).halted
      # ...and B, sharing A's egress address, still has all of its own. If the
      # fix had simply deleted token keying, this line would red.
      assert not RateLimit.call(read_with(b), RateLimit.init([])).halted
    end

    test "one live token's repeated requests still share ITS bucket" do
      with_limits(read_per_minute: 2, write_per_minute: 1)

      raw = mint("tenant-c")

      assert not RateLimit.call(read_with(raw), RateLimit.init([])).halted
      assert not RateLimit.call(read_with(raw), RateLimit.init([])).halted
      assert RateLimit.call(read_with(raw), RateLimit.init([])).halted
    end
  end
end
