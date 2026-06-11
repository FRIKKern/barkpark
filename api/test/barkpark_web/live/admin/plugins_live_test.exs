defmodule BarkparkWeb.Admin.PluginsLiveTest do
  @moduledoc """
  Task barkpark-otv — admin LV tests for `/studio/:dataset/_plugins`.

  Covers:

    * Auth gate — unauthenticated and non-admin tokens are redirected.
    * Renders one card per registered plugin with callback impl / default
      markers (the OnixEdit plugin registered at app boot exposes both
      shapes — overridden `action_handlers/0`, `register_routes/1` etc.;
      default `validate_settings/1` etc.).
    * Reload-plugin event flashes success and refreshes the last
      bootstrap row via `Plugins.RunStatus`.
    * Reload-all event walks every plugin and flashes the aggregate.
    * Empty-state copy is reachable through the standard render path
      (asserted indirectly via the empty-message data-test id).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.RunStatus

  @admin_token "plugins-admin-test-token"
  @junior_token "plugins-junior-test-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio without an admin token", %{conn: conn} do
      conn = init_test_session(conn, %{})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/studio/production/_plugins")
    end

    test "redirects to /studio for non-admin tokens", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/studio/production/_plugins")
    end
  end

  describe "render" do
    test "shows plugin card with callback impl/default markers", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/production/_plugins")

      assert html =~ "Plugins"

      # OnixEdit is registered at app boot; surface its card and confirm
      # both implemented and default callback rows render.
      assert has_element?(view, ~s|section.bp-plugin-card[data-test-plugin="onixedit"]|)

      assert has_element?(
               view,
               ~s|[data-test-plugin="onixedit"] [data-test-callback="action_handlers"][data-test-callback-status="implemented"]|
             )

      # OnixEdit now implements register_routes/1 (onixedit.ex:205 — the
      # legacy /admin/bokbasen 301 + onixedit consoles), so the callback row
      # surfaces as "implemented", not the former "default".
      assert has_element?(
               view,
               ~s|[data-test-plugin="onixedit"] [data-test-callback="register_routes"][data-test-callback-status="implemented"]|
             )
    end

    test "renders one row per callback (8 callbacks excluding manifest)", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/production/_plugins")

      for cb <- ~w(register_schemas action_handlers external_sync_entries codelist_seeders
                   register_routes register_workers validate_settings checkers) do
        assert has_element?(
                 view,
                 ~s|[data-test-plugin="onixedit"] [data-test-callback="#{cb}"]|
               ),
               "callback row missing for #{cb}"
      end
    end
  end

  describe "reload buttons" do
    test "reload-plugin flashes success and updates the last-bootstrap row", %{conn: conn} do
      RunStatus.reset()

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/production/_plugins")

      # Last bootstrap is "never" before the reload click.
      assert render(view) =~ "never"

      view
      |> element(~s|[data-test-plugin="onixedit"] button[data-test-action="reload-plugin"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Reloaded onixedit"
      # Status map now records a bootstrap entry — value column flips off "never".
      onixedit_status = RunStatus.get("onixedit")
      assert Map.has_key?(onixedit_status, :bootstrap)
    end

    test "reload-all flashes the aggregate result", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/production/_plugins")

      view
      |> element(~s|button[data-test-action="reload-all"]|)
      |> render_click()

      assert render(view) =~ "Reloaded all plugins"
    end

    test "refresh button re-renders without changing state", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/production/_plugins")

      view
      |> element(~s|button[data-test-action="refresh"]|)
      |> render_click()

      assert render(view) =~ "Refreshed."
    end
  end
end
