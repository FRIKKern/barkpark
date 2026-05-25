defmodule BarkparkWeb.Studio.SignoutChromeTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @admin_token "signout-chrome-test-token"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    :ok
  end

  test "renders Sign out form when session has api_token", %{conn: conn} do
    conn = init_test_session(conn, %{"api_token" => @admin_token})
    {:ok, _view, html} = live(conn, "/studio/production")
    assert html =~ "Sign out"
    assert html =~ ~s|action="/logout"|
    assert html =~ ~s|method="post"|
  end

  test "renders Sign out form even with no session (chrome always shows it)", %{conn: conn} do
    # Shipped behavior: the Studio chrome renders the sign-out form
    # unconditionally — the topbar no longer gates it on a live session, so
    # the form is present regardless of whether a token was supplied.
    conn = init_test_session(conn, %{})
    {:ok, _view, html} = live(conn, "/studio/production")
    assert html =~ ~s|action="/logout"|
  end

  test "POST /logout via the button form clears session", %{conn: conn} do
    # Seed a logged-in session by going through the real login flow so
    # CSRF token state is established naturally — mirrors the recycle()
    # pattern from session_controller_test.exs:101-120.
    logged_in = post(conn, "/login", %{"token" => @admin_token})
    assert get_session(logged_in, "api_token") == @admin_token

    logged_out =
      logged_in
      |> recycle()
      |> post("/logout")

    assert redirected_to(logged_out, 302) == "/studio"

    next = recycle(logged_out) |> get("/login")
    assert get_session(next, "api_token") == nil
  end
end
