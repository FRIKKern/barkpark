defmodule BarkparkWeb.Studio.SignoutChromeTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @admin_token "signout-chrome-test-token"

  setup do
    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "test admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  test "renders Sign out form when session has api_token", %{conn: conn} do
    conn = init_test_session(conn, %{"api_token" => @admin_token})
    {:ok, view, html} = live(conn, scoped_studio("/d/production/studio"))
    assert html =~ "Sign out"
    # The element itself, not a string match: the root stylesheet also holds
    # the text `form[action="/logout"]` in a selector (task-74466450563fcc21).
    assert has_element?(
             view,
             ~s|form[action="/logout"][method="post"] button[aria-label="Sign out"]|
           )
  end

  test "renders no Sign out form without a session (nothing to end)", %{conn: conn} do
    # The behaviour that replaced "chrome always shows it": studio.html.heex
    # renders the sign-out form only for a token session (`:api_token`) or an
    # account session (`:current_user`). A socket with neither has nothing to
    # end. The old test matched the text `action="/logout"`, which on main at
    # d43298a8e it found only in the root stylesheet's `form[action="/logout"]`
    # selector, never in an element (task-74466450563fcc21).
    conn = init_test_session(conn, %{})
    {:ok, view, _html} = live(conn, scoped_studio("/d/production/studio"))
    refute has_element?(view, ~s|form[action="/logout"]|)
    assert has_element?(view, "#studio-theme-toggle")
  end

  test "POST /logout via the button form clears session", %{conn: conn} do
    # Seed a logged-in session by going through the real login flow so
    # CSRF token state is established naturally — mirrors the recycle()
    # pattern from SessionControllerTest's "POST /logout" describe block.
    logged_in = post(conn, "/login", %{"token" => @admin_token})
    # Ruling #16 rework half (task-57f23825b18ab55d): a token sign-in no
    # longer puts the raw bearer in the session — only an opaque
    # TokenSession id. Resolve it rather than comparing the cookie directly.
    session_id = get_session(logged_in, "api_token_session")
    assert is_binary(session_id)

    assert {:ok, %Auth.ApiToken{}, @admin_token} =
             Auth.resolve_session_credential(session_id, nil)

    logged_out =
      logged_in
      |> recycle()
      |> post("/logout")

    assert redirected_to(logged_out, 302) == "/studio"

    next = recycle(logged_out) |> get("/login")
    assert get_session(next, "api_token") == nil
    assert get_session(next, "api_token_session") == nil
  end
end
