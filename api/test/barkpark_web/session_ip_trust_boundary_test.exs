defmodule BarkparkWeb.SessionIpTrustBoundaryTest do
  @moduledoc """
  The TRUST BOUNDARY on `user_sessions.ip_address` — the only IP column in
  `api/`, and therefore the whole of the login audit trail.

  Every session-minting path used to resolve the actor's address with its own
  one-liner:

      defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  Behind the co-located Caddy (`reverse_proxy localhost:4000`) `conn.remote_ip`
  is ALWAYS the loopback hop, so every row recorded `127.0.0.1` and the trail
  could not distinguish one actor from another — it answered nothing, while
  looking perfectly valid (populated column, well-formed address, no error).

  The fix routes all of them through `Barkpark.RateLimiter.client_ip/1`, the
  canonical `rate-limit-client-ip` resolver, which walks the chain RIGHT-to-left
  past trusted hops and falls back to the verified peer.

  PROTECTIVE, not vacuous — the mutations that flip this suite RED:

    * restore the one-liner above at any of the mint sites, and every
      "records the client, not the proxy" test fails with `127.0.0.1`;
    * "fix" it the naive way instead —
      `get_req_header(conn, "x-forwarded-for") |> hd() |> String.split(",") |> hd()`
      — and the FORGERY tests fail: an untrusted direct caller gets its
      invented address written into the audit trail, which is strictly worse
      than the uniform value it replaced, because it will be believed;
    * walk the chain leftmost-first, and "a caller-supplied PREFIX behind our
      own front is discarded" fails;
    * drop the `ip_source` stamp, and the provenance tests fail — a reader can
      no longer tell a derived client address from a raw peer, so the
      permanently-degraded case (guard never fires, every row is the proxy)
      becomes an inference again instead of a query.

  `async: false`: the suite moves the global `:trusted_proxies` config.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Repo

  @password "correct-horse-battery"

  # The loopback front: Caddy is co-located on the box and dials
  # localhost:4000, so this is the peer EVERY production request presents.
  @front_peer {127, 0, 0, 1}

  # A public, routable address standing in for a caller that reached the box
  # directly, bypassing the front — NOT loopback, NOT in the allowlist, so its
  # header carries no authority whatsoever.
  @direct_peer {203, 0, 113, 66}
  @direct_peer_string "203.0.113.66"

  # The real client, as our own front would append it.
  @client_ip "198.51.100.23"

  # What an attacker would like the audit trail to say instead.
  @forged_ip "9.9.9.9"

  setup do
    original = Application.get_env(:barkpark, :trusted_proxies)
    on_exit(fn -> Application.put_env(:barkpark, :trusted_proxies, original || []) end)
    Application.put_env(:barkpark, :trusted_proxies, [])
    :ok
  end

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # A conn whose TCP peer is `peer`, optionally carrying a forwarded chain.
  defp from(conn, peer, forwarded \\ nil) do
    conn = %{conn | remote_ip: peer}
    if forwarded, do: put_req_header(conn, "x-forwarded-for", forwarded), else: conn
  end

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")

  # POST /v1/auth/login — the API arm, minting through `BarkparkWeb.SessionIssuer`.
  defp api_login(conn, email) do
    conn
    |> json_conn()
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  # POST /login/account — the browser arm, minting through
  # `SessionController.mint_user_session/4`.
  defp browser_login(conn, email) do
    conn
    |> post("/login/account", %{"email" => email, "password" => @password})
    |> get_session("user_session")
  end

  # The row the login actually wrote.
  defp session_row!(token) do
    Repo.get_by!(Accounts.UserSession, token_hash: Accounts.UserSession.hash_token(token))
  end

  describe "SessionIssuer (POST /v1/auth/login)" do
    test "records the CLIENT address, not the front it arrived through", %{conn: conn} do
      register!("issuer-client@example.com")

      token =
        conn
        |> from(@front_peer, @client_ip)
        |> api_login("issuer-client@example.com")

      assert session_row!(token).ip_address == @client_ip,
             "the session row must name the actor, not the proxy every request shares"
    end

    test "a caller-supplied PREFIX behind our own front is discarded", %{conn: conn} do
      register!("issuer-prefix@example.com")

      # Caddy APPENDS the address it actually saw at the RIGHT end, so the
      # left-hand hop is whatever the caller invented.
      token =
        conn
        |> from(@front_peer, "#{@forged_ip}, #{@client_ip}")
        |> api_login("issuer-prefix@example.com")

      assert session_row!(token).ip_address == @client_ip
    end

    test "a spoofed chain from an UNTRUSTED peer is ignored — the peer is recorded",
         %{conn: conn} do
      register!("issuer-forged@example.com")

      token =
        conn
        |> from(@direct_peer, @forged_ip)
        |> api_login("issuer-forged@example.com")

      row = session_row!(token)

      refute row.ip_address == @forged_ip,
             "an attacker-chosen address must never reach the audit trail"

      assert row.ip_address == @direct_peer_string
    end

    test "a malformed chain from a trusted front falls back to the peer", %{conn: conn} do
      register!("issuer-malformed@example.com")

      token =
        conn
        |> from(@front_peer, "not-an-ip-address")
        |> api_login("issuer-malformed@example.com")

      assert session_row!(token).ip_address == "127.0.0.1"
    end

    test "a non-loopback front is believed only once it is configured", %{conn: conn} do
      register!("issuer-relay-a@example.com")

      # Unlisted: the relay's own address is what we can verify, so that is
      # what the trail records.
      unlisted =
        conn
        |> from(@direct_peer, @client_ip)
        |> api_login("issuer-relay-a@example.com")

      assert session_row!(unlisted).ip_address == @direct_peer_string

      Application.put_env(:barkpark, :trusted_proxies, [@direct_peer])
      register!("issuer-relay-b@example.com")

      listed =
        build_conn()
        |> from(@direct_peer, @client_ip)
        |> api_login("issuer-relay-b@example.com")

      assert session_row!(listed).ip_address == @client_ip
    end
  end

  describe "SessionController (POST /login/account)" do
    test "records the CLIENT address, not the front it arrived through", %{conn: conn} do
      register!("browser-client@example.com")

      token =
        conn
        |> from(@front_peer, @client_ip)
        |> browser_login("browser-client@example.com")

      assert session_row!(token).ip_address == @client_ip
    end

    test "a spoofed chain from an UNTRUSTED peer is ignored — the peer is recorded",
         %{conn: conn} do
      register!("browser-forged@example.com")

      token =
        conn
        |> from(@direct_peer, @forged_ip)
        |> browser_login("browser-forged@example.com")

      row = session_row!(token)

      refute row.ip_address == @forged_ip
      assert row.ip_address == @direct_peer_string
    end
  end

  describe "provenance — the row says which value it recorded" do
    test "a derived client address is stamped `forwarded`", %{conn: conn} do
      register!("source-forwarded@example.com")

      token =
        conn
        |> from(@front_peer, @client_ip)
        |> api_login("source-forwarded@example.com")

      assert session_row!(token).ip_source == "forwarded"
    end

    test "a raw peer address is stamped `peer`", %{conn: conn} do
      register!("source-peer@example.com")

      token =
        conn
        |> from(@direct_peer, @forged_ip)
        |> api_login("source-peer@example.com")

      assert session_row!(token).ip_source == "peer"
    end

    test "a request with no chain at all is stamped `peer`", %{conn: conn} do
      register!("source-bare@example.com")

      token =
        conn
        |> from(@front_peer)
        |> api_login("source-bare@example.com")

      row = session_row!(token)

      assert row.ip_address == "127.0.0.1"

      assert row.ip_source == "peer",
             "a loopback row that is genuinely the peer must be distinguishable " <>
               "from a loopback row that means the boundary silently stopped firing"
    end
  end
end
