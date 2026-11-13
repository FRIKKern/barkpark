defmodule BarkparkWeb.Studio.StudioLongDatasetTest do
  @moduledoc """
  task-7be4fec187490906: a dataset segment longer than any name can be names
  no dataset on any Studio page. It is a 404, where the media and API pages
  raised Regex.CompileError and the Studio root Plug.Conn.CookieOverflowError,
  and a live patch to one took the desk page down.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "studio-long-#{System.unique_integer([:positive])}"
    perms = ~w(read write admin)
    {:ok, _} = Barkpark.Auth.create_token(raw, "studio-long", "production", perms, ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     scope: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  test "a very long dataset segment is a 404 on every Studio page", %{conn: conn, scope: scope} do
    for bytes <- [100_000, 256], page <- ["", "/media", "/api-tester", "/post/post-01"] do
      long = String.duplicate("a", bytes)
      assert_error_sent(404, fn -> get(conn, "#{scope}/d/#{long}/studio#{page}") end)
    end

    # The longest name there can be, and a real one, answer as before.
    longest = String.duplicate("a", 255)

    for page <- ["/media", "/api-tester"] do
      assert html_response(get(conn, "#{scope}/d/#{longest}/studio#{page}"), 200)
      assert html_response(get(conn, "#{scope}/d/production/studio#{page}"), 200)
    end

    assert html_response(get(conn, "#{scope}/d/production/studio"), 200)
  end

  @tag capture_log: true
  test "a live patch on the desk to a very long dataset goes back to the desk it left", %{
    conn: conn,
    scope: scope
  } do
    base = "#{scope}/d/production/studio/_desk"
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)

    render_patch(view, "#{scope}/d/#{String.duplicate("a", 100_000)}/studio/_desk")
    assert_redirect(view, base)
  end
end
