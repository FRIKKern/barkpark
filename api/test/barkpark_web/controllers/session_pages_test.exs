defmodule BarkparkWeb.SessionPagesTest do
  @moduledoc """
  login-brand-ux — the branded auth pages and their two additions:

    * "Log in with Barkpark Cloud": renders ONLY when `:cloud_login_url` is
      configured (BARKPARK_CLOUD_URL on a cloud-managed instance), deep-links
      to the control plane's `#/instance-login` with this instance's origin,
      and survives error re-renders of :new.
    * Browser password-reset: the "Forgot password?" page (anti-enumeration
      twin of POST /v1/auth/request-reset) and the landing page for the
      emailed `/auth/reset/<token>` link, which 404'd in a browser before.
    * Browser magic-link: the request page + the `/auth/magic/<token>` landing
      (also dead in a browser before), which routes a TOTP-armed user through
      the same second step as password login.
  """
  use BarkparkWeb.ConnCase, async: false

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it (honest-gates S1).
  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @password "correct-horse-battery"

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # A live api_token whose RAW value a browser would paste into the solo login
  # form. Only the SHA-256 hash is stored; `kind` defaults to "api" so
  # `Barkpark.Auth.verify_token/1` accepts it (SessionController.create/2).
  defp mint_api_token! do
    raw = "solo-login-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "solo-login",
        permissions: ["read"]
      })
      |> Repo.insert()

    raw
  end

  defp enroll_totp!(user) do
    secret = NimbleTOTP.secret()

    {:ok, user, _codes} =
      Accounts.enable_totp(user, secret, totp_code_stable!(secret))

    {user, secret}
  end

  # The plaintext a browser would carry in the emailed /auth/magic/<token> URL
  # (only the hash is stored, so we mint it through Accounts, same as the JSON
  # magic-link suite).
  defp magic_token(email) do
    {:ok, token, _user} = Accounts.build_login_token(email)
    token
  end

  defp with_cloud_url(url) do
    previous = Application.get_env(:barkpark, :cloud_login_url)
    Application.put_env(:barkpark, :cloud_login_url, url)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark, :cloud_login_url)
        val -> Application.put_env(:barkpark, :cloud_login_url, val)
      end
    end)
  end

  describe "branded login page" do
    test "renders the brand wordmark and the account form", %{conn: conn} do
      html = conn |> get("/login") |> html_response(200)

      assert html =~ "Barkpark <b>Studio</b>"
      assert html =~ "bp-auth-card"
      assert html =~ ~s(action="/login/account")
      assert html =~ "Forgot password?"
      # The passwordless entry point is on the page.
      assert html =~ ~s(href="/login/magic")
      # Token paste stays available behind the fold.
      assert html =~ "Sign in with an API token instead"
    end

    test "no cloud button when :cloud_login_url is unset", %{conn: conn} do
      html = conn |> get("/login") |> html_response(200)
      refute html =~ "Log in with Barkpark Cloud"
    end

    test "cloud button renders with the instance-login deep link when configured",
         %{conn: conn} do
      with_cloud_url("https://barkpark.cloud/")

      html = conn |> get("/login") |> html_response(200)

      assert html =~ "Log in with Barkpark Cloud"

      own_origin = URI.encode_www_form(BarkparkWeb.Endpoint.url())
      assert html =~ "https://barkpark.cloud/#/instance-login?url=#{own_origin}"
    end

    test "cloud button survives a failed account sign-in re-render", %{conn: conn} do
      with_cloud_url("https://barkpark.cloud")

      html =
        conn
        |> post("/login/account", %{"email" => "nobody@example.com", "password" => "wrong"})
        |> html_response(200)

      assert html =~ "Log in with Barkpark Cloud"
      assert html =~ "Email or password is incorrect."
    end
  end

  describe "solo token-paste login (zero-tax behavioral no-op)" do
    # The API-token paste path (SessionController.create/2) is byte-identical
    # pre/post the enterprise-auth epic. This pins the behaviour, not the markup:
    # a bare valid token still sets the SAME `api_token` session key and lands on
    # the SAME `/studio` redirect, and the Cloud button stays absent with
    # BARKPARK_CLOUD_URL unset (mirror of the branded-page no-cloud assertion).
    test "a valid token sets the api_token session + redirects to /studio; no cloud button",
         %{conn: conn} do
      raw = mint_api_token!()

      # BARKPARK_CLOUD_URL unset in test → no Cloud button on the solo page.
      refute conn |> get("/login") |> html_response(200) =~ "Log in with Barkpark Cloud"

      conn = post(conn, "/login", %{"token" => raw})

      # SAME redirect + SAME session key the unchanged create/2 code path sets.
      assert redirected_to(conn) == "/studio"
      assert get_session(conn, "api_token") == raw
    end

    test "an invalid token re-renders the page and sets NO session (deny path)", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => "not-a-real-token"})

      assert html_response(conn, 200) =~ "Invalid API token."
      refute get_session(conn, "api_token")
    end
  end

  describe "forgot-password page" do
    test "renders the request form", %{conn: conn} do
      html = conn |> get("/login/reset") |> html_response(200)
      assert html =~ "Reset your password"
      assert html =~ ~s(action="/login/reset")
    end

    test "unknown email gets the SAME confirmation as a known one (no enumeration)",
         %{conn: conn} do
      register!("resetme@example.com")

      known =
        conn |> post("/login/reset", %{"email" => "resetme@example.com"}) |> html_response(200)

      unknown =
        conn |> post("/login/reset", %{"email" => "ghost@example.com"}) |> html_response(200)

      assert known =~ "Check your email"
      assert unknown =~ "Check your email"
    end
  end

  describe "emailed reset link landing" do
    test "GET renders the new-password form without consuming the token", %{conn: conn} do
      user = register!("landing@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      html = conn |> get("/auth/reset/#{raw}") |> html_response(200)
      assert html =~ "Set a new password"

      # Rendering must not have consumed the token — the reset still works.
      assert {:ok, _} = Accounts.reset_user_password(raw, %{password: "a-brand-new-password"})
    end

    test "POST with a valid token changes the password and redirects to /login",
         %{conn: conn} do
      user = register!("resetflow@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      conn = post(conn, "/auth/reset/#{raw}", %{"password" => "a-brand-new-password"})
      assert redirected_to(conn) == "/login"

      assert Accounts.get_user_by_email_and_password(
               "resetflow@example.com",
               "a-brand-new-password"
             )

      refute Accounts.get_user_by_email_and_password("resetflow@example.com", @password)
    end

    test "a policy-failing password re-renders and the token SURVIVES", %{conn: conn} do
      user = register!("shortpw@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      html = conn |> post("/auth/reset/#{raw}", %{"password" => "short"}) |> html_response(200)
      assert html =~ "Password"

      # Same link retried with a stronger password still works.
      assert {:ok, _} = Accounts.reset_user_password(raw, %{password: "a-brand-new-password"})
    end

    test "an invalid token redirects to the request page with the generic error",
         %{conn: conn} do
      conn = post(conn, "/auth/reset/not-a-real-token", %{"password" => "a-brand-new-password"})
      assert redirected_to(conn) == "/login/reset"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end
  end

  describe "magic-link request page" do
    test "renders the request form", %{conn: conn} do
      html = conn |> get("/login/magic") |> html_response(200)
      assert html =~ "Email me a sign-in link"
      assert html =~ ~s(action="/login/magic")
    end

    test "unknown email gets the SAME confirmation as a known one (no enumeration)",
         %{conn: conn} do
      register!("magicknown@example.com")

      known =
        conn |> post("/login/magic", %{"email" => "magicknown@example.com"}) |> html_response(200)

      unknown =
        conn |> post("/login/magic", %{"email" => "ghost@example.com"}) |> html_response(200)

      assert known =~ "Check your email"
      assert unknown =~ "Check your email"
    end
  end

  describe "emailed magic link landing" do
    test "a valid token mints a user_session and lands on /studio", %{conn: conn} do
      register!("magicin@example.com")
      token = magic_token("magicin@example.com")

      conn = get(conn, "/auth/magic/#{token}")
      assert redirected_to(conn) == "/studio"
      assert is_binary(get_session(conn, "user_session"))
    end

    test "the token is single-use — a second landing fails generically", %{conn: conn} do
      register!("magiconce@example.com")
      token = magic_token("magiconce@example.com")

      assert redirected_to(get(conn, "/auth/magic/#{token}")) == "/studio"

      conn = get(conn, "/auth/magic/#{token}")
      assert redirected_to(conn) == "/login/magic"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end

    test "a TOTP-armed user is routed through the second step, NOT signed in outright",
         %{conn: conn} do
      user = register!("magicmfa@example.com")
      enroll_totp!(user)
      token = magic_token("magicmfa@example.com")

      conn = get(conn, "/auth/magic/#{token}")
      # The MFA step, not a session — magic-link must not bypass 2FA.
      assert html_response(conn, 200) =~ "Two-step verification"
      refute get_session(conn, "user_session")
      assert get_session(conn, "studio_mfa_user") == user.id
    end

    test "an invalid token redirects to the request page with the generic error",
         %{conn: conn} do
      conn = get(conn, "/auth/magic/not-a-real-token")
      assert redirected_to(conn) == "/login/magic"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end
  end
end
