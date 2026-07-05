defmodule BarkparkWeb.StudioUserLoginTest do
  @moduledoc """
  studio-user-login — the Studio front door rides the core auth system.

  Covers: the /login/account email+password flow (with the TOTP/recovery
  second step and the org-require-MFA block), user-principal access to the
  flat and scoped Studio, the LiveAuth admin gate's user arm, SSO callback
  browser-vs-API content negotiation, and logout revocation. The legacy
  token-paste and ticket flows are regression-pinned by session_controller
  tests; here we assert they still coexist.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp login_account(conn, email, password \\ @password) do
    post(conn, "/login/account", %{"email" => email, "password" => password})
  end

  defp workspace!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "main", name: "main"})
    ws
  end

  defp member!(ws, user, role \\ "member") do
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    :ok
  end

  defp enroll_totp!(user) do
    secret = NimbleTOTP.secret()

    {:ok, user, _recovery_codes} =
      Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

    {user, secret}
  end

  describe "account sign-in (email + password)" do
    test "signs in and lands on /studio with a user_session cookie", %{conn: conn} do
      register!("dana@example.com")

      conn = login_account(conn, "dana@example.com")
      assert redirected_to(conn) == "/studio"
      assert is_binary(get_session(conn, "user_session"))
    end

    test "wrong password re-renders with the generic error, no session", %{conn: conn} do
      register!("erin@example.com")

      conn = login_account(conn, "erin@example.com", "wrong-password")
      assert html_response(conn, 200) =~ "Email or password is incorrect"
      refute get_session(conn, "user_session")
    end

    test "a TOTP-armed user gets the second step; a valid code completes sign-in",
         %{conn: conn} do
      user = register!("mfa@example.com")
      {_user, secret} = enroll_totp!(user)

      conn = login_account(conn, "mfa@example.com")
      assert html_response(conn, 200) =~ "Two-factor code"
      refute get_session(conn, "user_session")

      conn =
        post(conn, "/login/mfa", %{"code" => NimbleTOTP.verification_code(secret)})

      assert redirected_to(conn) == "/studio"
      assert is_binary(get_session(conn, "user_session"))
    end

    test "a wrong code re-renders the step; a stale pending marker restarts",
         %{conn: conn} do
      user = register!("mfa2@example.com")
      enroll_totp!(user)

      conn = login_account(conn, "mfa2@example.com")
      conn = post(conn, "/login/mfa", %{"code" => "000000"})
      assert html_response(conn, 200) =~ "didn&#39;t work"

      # no pending marker at all → back to /login
      fresh = build_conn() |> post("/login/mfa", %{"code" => "123456"})
      assert redirected_to(fresh) == "/login"
    end

    test "org-require-MFA blocks a governed factor-less user at the door", %{conn: conn} do
      user = register!("governed@example.com")
      {:ok, org} = Tenancy.create_organization(%{slug: "strict-co", name: "strict-co"})
      {:ok, org} = Tenancy.set_organization_require_mfa(org.id, true)
      ws = workspace!("strict-co-ws")
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      member!(ws, user)

      conn = login_account(conn, "governed@example.com")
      assert html_response(conn, 200) =~ "organization requires MFA"
      refute get_session(conn, "user_session")
    end

    test "logout revokes the account session server-side", %{conn: conn} do
      register!("bye@example.com")
      conn = login_account(conn, "bye@example.com")
      token = get_session(conn, "user_session")

      conn = post(conn, "/logout")
      assert redirected_to(conn) == "/studio"
      assert Accounts.verify_user_session(token) == nil
    end

    test "the token-paste form still works alongside", %{conn: conn} do
      raw = "studio-login-coexist-raw-token"
      {:ok, _} = Barkpark.Auth.create_token(raw, "t", "production", ["read"])

      conn = post(conn, "/login", %{"token" => raw})
      assert redirected_to(conn) == "/studio"
      assert get_session(conn, "api_token") == raw
    end
  end

  describe "user principal in Studio" do
    test "a member's account session mounts the scoped Studio", %{conn: conn} do
      user = register!("member@example.com")
      ws = workspace!("userco")
      member!(ws, user)

      conn = login_account(conn, "member@example.com")

      assert {:ok, _view, html} =
               conn
               |> recycle()
               |> live("/w/userco/p/main/d/production/studio")

      assert html =~ "userco"
    end

    test "a signed-in non-member is fail-closed on a foreign scope", %{conn: conn} do
      register!("outsider@example.com")
      workspace!("privateco")

      conn = login_account(conn, "outsider@example.com")

      # dead render: ResolveWorkspace rejects the non-member before the LV
      resp = conn |> recycle() |> get("/w/privateco/p/main/d/production/studio")
      assert resp.status == 403
    end

    test "an owner-in-Default user passes the LiveAuth admin gate", %{conn: conn} do
      user = register!("rootadmin@example.com")
      %{id: default_ws_id} = Tenancy.get_default_workspace()
      {:ok, _} = TenancyAuth.create_membership(default_ws_id, user.id, "owner", "user")

      conn = login_account(conn, "rootadmin@example.com")

      assert {:ok, _view, html} = conn |> recycle() |> live("/studio/org-admin")
      assert html =~ "Organization Admin"
    end

    test "a plain member user is denied the admin gate", %{conn: conn} do
      user = register!("plain@example.com")
      %{id: default_ws_id} = Tenancy.get_default_workspace()
      {:ok, _} = TenancyAuth.create_membership(default_ws_id, user.id, "member", "user")

      conn = login_account(conn, "plain@example.com")

      assert {:error, {:redirect, %{to: "/studio"}}} =
               conn |> recycle() |> live("/studio/org-admin")
    end
  end

  describe "SSO callback content negotiation" do
    test "a non-HTML caller keeps the JSON contract on OIDC errors", %{conn: conn} do
      # No connection for the org — the JSON error arm must be unchanged for
      # API-shaped callers (the Keycloak interop suite depends on it).
      resp = get(conn, "/v1/auth/oidc/no-such-org/callback", %{code: "x", state: "y"})
      assert json_response(resp, 404)["error"] =~ "no OIDC connection"
    end
  end
end
