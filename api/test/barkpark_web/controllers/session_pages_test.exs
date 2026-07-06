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
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts

  @password "correct-horse-battery"

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
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
end
