defmodule BarkparkCloud.Web.RouterTwoFactorTest do
  @moduledoc """
  HTTP-level coverage of the two-factor-auth surface: the two-phase login, the
  challenge endpoint (OTP + recovery + rate limit), and the account
  enroll/confirm/disable/status routes. Drives the router directly via Plug.Test
  exactly like router_test.exs.
  """
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    # async: false because the ETS rate limiter is a process-wide singleton.
    TwoFactorRateLimiter.reset()
    :ok
  end

  ## Fixtures / helpers

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {Accounts.get_user(user.id), team}
  end

  defp call(method, path, body, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Log a user in (no 2FA) and return their session token.
  defp login_token(user) do
    conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
    json_body(conn)["token"]
  end

  # Fully enable 2FA over HTTP; return {recovery_codes, raw_secret, session_token}.
  # The token is the session minted BEFORE 2FA was confirmed — still valid, and
  # the only way to call account routes once login starts returning challenges.
  defp enable_two_factor(user) do
    token = login_token(user)
    enroll = call(:post, "/v1/account/two-factor/enroll", %{}, token)
    %{"secret" => b32} = json_body(enroll)
    {:ok, secret} = Base.decode32(b32, padding: false)

    confirm =
      call(
        :post,
        "/v1/account/two-factor/confirm",
        %{code: totp_code_stable!(secret)},
        token
      )

    {json_body(confirm)["recovery_codes"], secret, token}
  end

  ## Two-phase login

  describe "POST /v1/auth/login with 2FA" do
    test "a non-2FA user gets the UNCHANGED {token, team_id} shape" do
      {user, team} = user_with_team()
      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      body = json_body(conn)

      assert conn.status == 200
      assert is_binary(body["token"])
      assert body["team_id"] == team.id
      refute Map.has_key?(body, "two_factor_required")
    end

    test "a 2FA user gets {two_factor_required, challenge_token} and NO session token" do
      {user, _team} = user_with_team()
      {_codes, _secret, _t} = enable_two_factor(user)

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      body = json_body(conn)

      assert conn.status == 200
      assert body["two_factor_required"] == true
      assert is_binary(body["challenge_token"])
      refute Map.has_key?(body, "token")
      # The challenge token does NOT authenticate /v1/me.
      assert call(:get, "/v1/me", nil, body["challenge_token"]).status == 401
    end
  end

  ## Challenge endpoint

  describe "POST /v1/auth/two-factor-challenge" do
    test "the right OTP mints a session that authenticates /v1/me" do
      {user, team} = user_with_team()
      {_codes, secret, _t} = enable_two_factor(user)

      login = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      challenge = json_body(login)["challenge_token"]

      conn =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge,
          # Next window past the spent enrollment step (confirm consumed it).
          code: code_for_period_offset!(secret, +1)
        })

      body = json_body(conn)
      assert conn.status == 200
      assert is_binary(body["token"])
      assert body["team_id"] == team.id

      me = call(:get, "/v1/me", nil, body["token"])
      assert me.status == 200
      assert json_body(me)["user"]["two_factor_enabled"] == true
    end

    test "a recovery code works and cannot be reused" do
      {user, _team} = user_with_team()
      {codes, _secret, _t} = enable_two_factor(user)
      [recovery | _] = codes

      challenge1 =
        call(:post, "/v1/auth/login", %{email: user.email, password: @password})
        |> json_body()
        |> Map.fetch!("challenge_token")

      ok =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge1,
          recovery_code: recovery
        })

      assert ok.status == 200
      assert is_binary(json_body(ok)["token"])

      # Reusing the same recovery code on a fresh challenge fails.
      challenge2 =
        call(:post, "/v1/auth/login", %{email: user.email, password: @password})
        |> json_body()
        |> Map.fetch!("challenge_token")

      reuse =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge2,
          recovery_code: recovery
        })

      assert reuse.status == 401
      assert json_body(reuse)["error"] == "invalid_code"
    end

    test "a bad code → 401 and the pending token does not upgrade" do
      {user, _team} = user_with_team()
      {_codes, _secret, _t} = enable_two_factor(user)

      challenge =
        call(:post, "/v1/auth/login", %{email: user.email, password: @password})
        |> json_body()
        |> Map.fetch!("challenge_token")

      conn =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge,
          code: "000000"
        })

      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_code"
    end

    test "more than 5 attempts/min → 429 rate_limited" do
      {user, _team} = user_with_team()
      {_codes, _secret, _t} = enable_two_factor(user)

      challenge =
        call(:post, "/v1/auth/login", %{email: user.email, password: @password})
        |> json_body()
        |> Map.fetch!("challenge_token")

      # 5 allowed (wrong) attempts, then the 6th is rate-limited.
      for _ <- 1..5 do
        conn =
          call(:post, "/v1/auth/two-factor-challenge", %{
            challenge_token: challenge,
            code: "000000"
          })

        assert conn.status == 401
      end

      sixth =
        call(:post, "/v1/auth/two-factor-challenge", %{challenge_token: challenge, code: "000000"})

      assert sixth.status == 429
      body = json_body(sixth)
      assert body["error"] == "rate_limited"

      # The 429 carries a REAL countdown, not an opaque "try again later": the
      # remainder of the limiter's 60s fixed window, so the SPA can render a
      # timer. Bounded rather than pinned because the window boundary moves with
      # wall-clock time here (the exact arithmetic is pinned, with an injected
      # clock, in two_factor_rate_limiter_test.exs).
      assert is_integer(body["retry_after"])
      assert body["retry_after"] >= 1 and body["retry_after"] <= 60
    end
  end

  ## Account routes

  describe "/v1/account/two-factor" do
    test "enroll → confirm flips /v1/me, DELETE flips it back" do
      {user, _team} = user_with_team()
      token = login_token(user)

      assert json_body(call(:get, "/v1/account/two-factor", nil, token))["enabled"] == false

      enroll = call(:post, "/v1/account/two-factor/enroll", %{}, token)
      assert enroll.status == 200
      %{"otpauth_uri" => uri, "secret" => b32} = json_body(enroll)
      assert String.starts_with?(uri, "otpauth://totp/")
      {:ok, secret} = Base.decode32(b32, padding: false)

      confirm =
        call(
          :post,
          "/v1/account/two-factor/confirm",
          %{code: totp_code_stable!(secret)},
          token
        )

      assert confirm.status == 200
      assert length(json_body(confirm)["recovery_codes"]) == 8

      assert json_body(call(:get, "/v1/me", nil, token))["user"]["two_factor_enabled"] == true

      del = call(:delete, "/v1/account/two-factor", nil, token)
      assert del.status == 200
      assert json_body(call(:get, "/v1/me", nil, token))["user"]["two_factor_enabled"] == false
    end

    test "confirm with a wrong code → 422 invalid_otp" do
      {user, _team} = user_with_team()
      token = login_token(user)
      call(:post, "/v1/account/two-factor/enroll", %{}, token)

      conn = call(:post, "/v1/account/two-factor/confirm", %{code: "000000"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_otp"
    end

    test "the account routes require authentication" do
      assert call(:post, "/v1/account/two-factor/enroll", %{}).status == 401
      assert call(:get, "/v1/account/two-factor", nil).status == 401
      assert call(:delete, "/v1/account/two-factor", nil).status == 401
    end

    test "regenerate recovery codes invalidates the old set" do
      {user, _team} = user_with_team()
      # The session minted before confirm stays valid; login now returns a
      # challenge (2FA is on), so reuse that token for the account route.
      {old_codes, _secret, token} = enable_two_factor(user)

      conn = call(:post, "/v1/account/two-factor/recovery-codes", %{}, token)
      assert conn.status == 200
      new_codes = json_body(conn)["recovery_codes"]
      assert length(new_codes) == 8
      assert MapSet.disjoint?(MapSet.new(old_codes), MapSet.new(new_codes))
    end
  end
end
