defmodule BarkparkWeb.SessionControllerTest do
  @moduledoc """
  Task #6 / S3 — controller tests for the browser-facing session controller.

  Covers:
    * GET /login form render + return_to echo
    * POST /login success (default redirect, custom redirect, open-redirect defense, whitespace trim)
    * POST /login failure (invalid token, missing token) — flash + no session leak + token not echoed
    * POST /logout — drops session and redirects
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @valid_token "test-session-valid-token-12345"
  @invalid_token "this-token-does-not-exist"

  setup do
    {:ok, _} = Auth.create_token(@valid_token, "test-session", "test", ["read", "admin"])
    :ok
  end

  describe "GET /login" do
    test "renders the form (200)", %{conn: conn} do
      conn = get(conn, "/login")
      body = html_response(conn, 200)
      assert body =~ "Sign in"
      assert body =~ ~s|action="/login"|
    end

    test "echoes a safe return_to in the hidden field", %{conn: conn} do
      conn = get(conn, "/login?return_to=/studio/test/post")
      body = html_response(conn, 200)
      assert body =~ ~s|name="return_to"|
      assert body =~ ~s|value="/studio/test/post"|
    end

    test "rejects external return_to in the hidden field", %{conn: conn} do
      conn = get(conn, "/login?return_to=//evil.com/path")
      body = html_response(conn, 200)
      # Sanitized to default
      assert body =~ ~s|value="/studio"|
      refute body =~ "evil.com"
    end
  end

  describe "POST /login (success)" do
    test "valid token sets session and redirects to /studio by default", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token})
      assert redirected_to(conn, 302) == "/studio"
      assert get_session(conn, "api_token") == @valid_token
    end

    test "valid token + safe return_to redirects to that path", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "/studio/test/page"})

      assert redirected_to(conn, 302) == "/studio/test/page"
      assert get_session(conn, "api_token") == @valid_token
    end

    test "open-redirect attempt is rejected (//evil.com)", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "//evil.com"})
      assert redirected_to(conn, 302) == "/studio"
      assert get_session(conn, "api_token") == @valid_token
    end

    test "external https return_to is rejected", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "https://evil.com/x"})

      assert redirected_to(conn, 302) == "/studio"
    end

    test "trims surrounding whitespace and newlines on the token", %{conn: conn} do
      padded = "  " <> @valid_token <> "  \n"
      conn = post(conn, "/login", %{"token" => padded})
      assert redirected_to(conn, 302) == "/studio"
      # Session stores the trimmed value, not the padded one.
      assert get_session(conn, "api_token") == @valid_token
    end
  end

  describe "POST /login (failure)" do
    test "invalid token re-renders form with error flash and no session", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @invalid_token})
      body = html_response(conn, 200)
      assert body =~ "Invalid API token."
      assert get_session(conn, "api_token") == nil
      # The token must NOT be reflected back in the rendered HTML.
      refute body =~ @invalid_token
    end

    test "missing token params returns form with error flash", %{conn: conn} do
      conn = post(conn, "/login", %{})
      body = html_response(conn, 200)
      assert body =~ "Token is required."
      assert get_session(conn, "api_token") == nil
    end
  end

  describe "POST /logout" do
    test "clears the session and redirects to /studio", %{conn: conn} do
      # Seed a logged-in session by going through the real login flow.
      logged_in = post(conn, "/login", %{"token" => @valid_token})
      assert get_session(logged_in, "api_token") == @valid_token

      # POST /logout while carrying the session cookie forward.
      logged_out =
        logged_in
        |> recycle()
        |> post("/logout")

      assert redirected_to(logged_out, 302) == "/studio"

      # `configure_session(drop: true)` drops the cookie at response time,
      # so a fresh request after recycle() should see an empty session.
      next = recycle(logged_out) |> get("/login")
      assert get_session(next, "api_token") == nil
    end
  end
end
