defmodule BarkparkCloud.Web.RouterOAuthTwoFactorTest do
  @moduledoc """
  cch-w53-s6 — the OAuth legs PAIRED WITH two-factor, which nothing in cloud/test
  did before this file existed. `router_oauth_test.exs` drives OAuth against
  accounts that have no second factor; `router_two_factor_test.exs` drives the
  second factor against the password leg only. The gap between those two files is
  where `POST /v1/auth/oauth/exchange` used to mint a full 30-day session for an
  account whose owner had enrolled in TOTP.

  LATENT, IN THE PRESENT TENSE. No provider is configured on prod
  (`GET /v1/auth/oauth/providers` answers `{"providers":[]}`), so this divergence
  has zero victims today; the arming condition is exactly "set
  GITHUB_OAUTH_CLIENT_ID + GITHUB_OAUTH_CLIENT_SECRET (or the Google pair) and
  restart" — no code change, no migration. The tests below are hermetic: the test
  env configures both stub providers, and the token/userinfo legs run through
  `BarkparkCloud.OAuthStub`.

  `async: false` because the two-factor challenge is behind
  `TwoFactorRateLimiter`, a process-wide ETS singleton (same reason
  router_two_factor_test.exs is serial).
  """
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.OAuth
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The GitHub stub's verified primary email. Registering a PASSWORD account at
  # this address is what makes the linking precedence documented at accounts.ex:139
  # ("I signed up with email, now I click GitHub" CONVERGES) reach an account that
  # already has a second factor.
  @github_email "octocat@example.com"

  setup do
    TwoFactorRateLimiter.reset()
    :ok
  end

  defp call(method, path, body \\ nil, token \\ nil) do
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

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # Enrol + CONFIRM 2FA over HTTP, exactly as a real user would: the session
  # minted before confirmation is the only credential that can reach the account
  # routes once login starts answering with challenges.
  defp enable_two_factor!(user) do
    token =
      json_body(call(:post, "/v1/auth/login", %{email: user.email, password: @password}))["token"]

    %{"secret" => b32} = json_body(call(:post, "/v1/account/two-factor/enroll", %{}, token))
    {:ok, secret} = Base.decode32(b32, padding: false)

    confirm =
      call(
        :post,
        "/v1/account/two-factor/confirm",
        %{code: totp_code_stable!(secret)},
        token
      )

    assert confirm.status == 200
    assert Accounts.two_factor_enabled?(Accounts.get_user(user.id))
    secret
  end

  # Walk the IdP callback the way a browser does and hand back the one-time
  # exchange code off the redirect fragment.
  defp callback_code!(provider) do
    state = OAuth.mint_state(provider)
    conn = call(:get, "/v1/auth/oauth/#{provider}/callback?code=abc&state=#{state}")
    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    [_, frag] = String.split(loc, "#", parts: 2)
    %{"oauth_code" => code} = URI.decode_query(frag)
    code
  end

  # The enrolment `confirm` above burns the CURRENT TOTP step (matching_step
  # advances a high-water mark, so a code is single-use). Every later code in a
  # test must therefore come from the NEXT step — the same +30 router_two_factor_test
  # uses for exactly this reason.
  defp next_code(secret),
    do: code_for_period_offset!(secret, +1)

  defp session_origins(user) do
    user |> Accounts.list_user_sessions() |> Enum.map(& &1.origin)
  end

  describe "POST /v1/auth/oauth/exchange for a 2FA-enrolled account" do
    # THE MUST-FAIL-TODAY PROBE. On unmodified main this test failed with
    # "FULL SESSION MINTED for a 2FA-enrolled account via OAuth exchange
    # (status 200, keys [team_id, token])": the exchange's with-chain went
    # is_binary(code) -> consume_oauth_exchange_code -> create_user_session_token
    # with no two_factor_enabled? anywhere in it.
    test "answers a two-factor challenge instead of a session — with its own positive control" do
      user = register!(@github_email)
      enable_two_factor!(user)

      # POSITIVE CONTROL, same run: the PASSWORD leg for this identical account
      # already refuses to mint a session. A green below therefore cannot come
      # from a 2FA fixture that silently failed to enrol.
      password_leg =
        json_body(call(:post, "/v1/auth/login", %{email: @github_email, password: @password}))

      assert password_leg["two_factor_required"] == true
      refute Map.has_key?(password_leg, "token")

      conn = call(:post, "/v1/auth/oauth/exchange", %{code: callback_code!("github")})
      body = json_body(conn)

      refute Map.has_key?(body, "token"),
             "FULL SESSION MINTED for a 2FA-enrolled account via OAuth exchange " <>
               "(status #{conn.status}, keys #{inspect(Enum.sort(Map.keys(body)))})"

      # NEVER A HARD REFUSE. The same shape the password leg returns, because an
      # OAuth-born account can be passwordless with a synthetic, undeliverable
      # address — a refusal there is permanent.
      assert conn.status == 200
      assert body["two_factor_required"] == true
      assert is_binary(body["challenge_token"]) and body["challenge_token"] != ""

      # LINK-BY-EMAIL REALLY REACHED THE ENROLLED ACCOUNT: the challenge is for
      # the pre-created password user, not a second, freshly-birthed one.
      assert %{id: converged_id} =
               Accounts.verify_two_factor_pending_token(body["challenge_token"])

      assert converged_id == user.id

      # And the exchange minted NO session — the refusal is not cosmetic. The one
      # live session is the "password" one from enrolment (a real user's browser
      # would not even have that; it is an artefact of enrolling over HTTP here),
      # and crucially there is no oauth: origin.
      origins = session_origins(Accounts.get_user(user.id))
      assert origins == ["password"]
      refute Enum.any?(origins, &String.contains?(&1 || "", "oauth"))
    end

    test "the challenge round-trips: a valid TOTP code upgrades it into a working session" do
      user = register!(@github_email)
      secret = enable_two_factor!(user)

      challenge =
        json_body(call(:post, "/v1/auth/oauth/exchange", %{code: callback_code!("github")}))[
          "challenge_token"
        ]

      conn =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge,
          code: next_code(secret)
        })

      assert conn.status == 200
      token = json_body(conn)["token"]
      assert %{id: id} = Accounts.verify_user_session_token(token)
      assert id == user.id

      # The token is a REAL session, not a shape: it opens an authenticated route.
      assert call(:get, "/v1/me", nil, token).status == 200
    end

    # (a) THE ORIGIN STAYS HONEST. Routing an OAuth-minted pending token through
    # the challenge leg unchanged would stamp `origin: "two_factor"`, whose own
    # comment asserts "the password leg ALREADY passed" — false here, and the
    # sessions security panel would attribute an IdP sign-in to a password one.
    test "an OAuth-initiated challenge mints a session whose origin names the provider" do
      oauth_user = register!(@github_email)
      oauth_secret = enable_two_factor!(oauth_user)

      oauth_challenge =
        json_body(call(:post, "/v1/auth/oauth/exchange", %{code: callback_code!("github")}))[
          "challenge_token"
        ]

      # The provider survives the hop on the pending token's own sent_to, the way
      # the exchange code already carries it.
      assert Accounts.two_factor_pending_first_factor(oauth_challenge) == "oauth:github"

      assert call(:post, "/v1/auth/two-factor-challenge", %{
               challenge_token: oauth_challenge,
               code: next_code(oauth_secret)
             }).status == 200

      # (The "password" row is the enrolment session, minted before 2FA existed on
      # this account; the CHALLENGE-minted one is the new row.)
      assert session_origins(Accounts.get_user(oauth_user.id)) == [
               "oauth:github+two_factor",
               "password"
             ]

      # THE CONTRAST, in the same run: a PASSWORD-initiated challenge for a
      # different account still stamps the unqualified "two_factor". The two
      # origins differ, so the panel can tell an IdP sign-in from a password one.
      pw_user = register!("pw-#{System.unique_integer([:positive])}@example.com")
      pw_secret = enable_two_factor!(pw_user)

      pw_challenge =
        json_body(call(:post, "/v1/auth/login", %{email: pw_user.email, password: @password}))[
          "challenge_token"
        ]

      assert is_nil(Accounts.two_factor_pending_first_factor(pw_challenge))

      assert call(:post, "/v1/auth/two-factor-challenge", %{
               challenge_token: pw_challenge,
               code: next_code(pw_secret)
             }).status == 200

      # The pre-2FA enrolment session is still live for this user, so filter to
      # the challenge-minted ones.
      pw_origins = session_origins(Accounts.get_user(pw_user.id))
      assert "two_factor" in pw_origins
      refute Enum.any?(pw_origins, &String.contains?(&1 || "", "oauth:"))
    end

    # THE ORDINARY PATH DOES NOT MOVE: an account with no second factor still
    # exchanges straight into a session stamped with its provider.
    test "an account WITHOUT 2FA still gets a full session, origin oauth:github" do
      token =
        json_body(call(:post, "/v1/auth/oauth/exchange", %{code: callback_code!("github")}))[
          "token"
        ]

      assert %{} = user = Accounts.verify_user_session_token(token)
      assert user.email == @github_email
      assert session_origins(user) == ["oauth:github"]
    end
  end
end
