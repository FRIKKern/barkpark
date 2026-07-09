defmodule BarkparkWeb.Studio.ScopedAdminFamilyTest do
  @moduledoc """
  bp-studio-deep-link wave 1 slice `sdl-w1-admin-canonical` (charter D4):
  the scoped-in-substance admin surfaces move under the canonical
  `/w/:ws/p/:proj/...` grammar, with the flat spellings 302ing back-compat.

  Two surfaces:

    * `SettingsLive` → `/w/:ws/p/:proj/studio/settings` (dataset-less,
      workspace-level). `LiveScope` binds the panel to the URL workspace —
      the bug was that the flat route silently pinned the seeded Default,
      so a user in workspace B edited Default's settings.
    * `PluginsLive` / `PluginSettingsLive` →
      `/w/:ws/p/:proj/d/:ds/studio/_plugins[/:plugin/settings]`, declared
      BEFORE the `:scoped_studio` `/*path` catch-all.

  The adversarial gate is the SUBSTANCE test: with two workspaces, the
  settings written under workspace B land on B and NEVER on Default.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()

    ws_b = create_workspace!("scoped-admin-b")
    proj_b = create_project!(ws_b, "scoped-admin-pb")

    # An admin token that is a MEMBER of workspace B only. It carries the
    # global "admin" permission (LiveAuth.:admin gate) AND an owner membership
    # in B (LiveScope's per-workspace read gate on the scoped settings route).
    raw = "scoped-admin-test-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "scoped-admin-owner-b",
        dataset: @dataset,
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "owner")

    admin_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     admin_conn: admin_conn,
     raw: raw,
     default_ws: default_ws,
     default_proj: default_proj,
     ws_b: ws_b,
     proj_b: proj_b}
  end

  defp settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"
  defp plugins_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_plugins"

  describe "scoped mounts live (routes declared before the :scoped_studio catch-all)" do
    test "settings mounts SettingsLive bound to the URL workspace", %{
      admin_conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      # If the route were absent (or the `/w/:ws/p/:proj/studio/:dataset`
      # wildcard swallowed `/settings` as dataset="settings") this would 302
      # instead of mounting — so a live mount that renders SettingsLive proves
      # both the route AND its ordering.
      {:ok, _view, html} = live(conn, settings_url(ws_b, proj_b))

      assert html =~ "Workspace Settings"
      assert html =~ "Plugin credentials"
      # LiveScope bound current_workspace to the URL workspace (B), not Default.
      assert html =~ ws_b.name
    end

    test "_plugins mounts PluginsLive, NOT StudioLive (not swallowed by /*path)", %{
      admin_conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, view, html} = live(conn, plugins_url(ws_b, proj_b))

      # `data-test-id="plugins-admin"` is emitted ONLY by PluginsLive. Had
      # `:scoped_studio`'s `/*path` caught this URL, StudioLive would render its
      # pane board and this element would be absent — so its presence is the
      # ORDERING kill shot ("pane-layout" itself is in the shared chrome shell,
      # so it can't discriminate).
      assert has_element?(view, "[data-test-id=plugins-admin]")
      assert html =~ "Plugins"
      assert has_element?(view, "[data-test-id=plugin-cards], [data-test-id=plugins-empty]")
    end

    test "_plugins/:plugin/settings mounts PluginSettingsLive", %{
      admin_conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      # onixedit is registered at app boot and declares a settings schema.
      {:ok, view, _html} =
        live(conn, plugins_url(ws_b, proj_b) <> "/onixedit/settings")

      assert has_element?(view, "[data-test-id=plugin-settings]")
      # Its own "Back to plugins" link is now the scoped canonical, not flat.
      assert has_element?(
               view,
               ~s|a[href="#{plugins_url(ws_b, proj_b)}"]|
             )
    end
  end

  describe "SUBSTANCE: settings under workspace B write to B, never to Default" do
    test "toggling a plugin under B persists on B and leaves Default untouched", %{
      admin_conn: conn,
      default_ws: default_ws,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      name = pick_plugin()

      # Default's plugin settings BEFORE — the invariant is that this surface
      # never touches them, whatever their starting state.
      default_before =
        Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(default_ws.id))

      {:ok, view, _html} = live(conn, settings_url(ws_b, proj_b))
      render_click(view, "toggle_plugin", %{"plugin" => name})

      # Workspace B GOT the override…
      ws_b_plugins =
        Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(ws_b.id))

      assert Map.has_key?(ws_b_plugins, name)
      assert is_boolean(ws_b_plugins[name]["enabled"])

      # …and the seeded Default workspace is byte-identical (no teleport write).
      default_after =
        Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(default_ws.id))

      assert default_after == default_before
    end

    test "setting the workspace theme under B persists on B, not Default", %{
      admin_conn: conn,
      default_ws: default_ws,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      default_theme_before =
        Tenancy.get_workspace_by_id(default_ws.id).settings["theme"]

      theme = List.first(Tenancy.known_themes())

      {:ok, view, _html} = live(conn, settings_url(ws_b, proj_b))

      render_change(element(view, "form[phx-change=set_workspace_theme]"), %{theme: theme})

      # B's theme is now persisted server-side.
      assert Tenancy.workspace_theme(Tenancy.get_workspace_by_id(ws_b.id)) == theme

      # Default's stored theme key never changed (the flat route would have
      # written it — that is the bug this slice closes).
      assert Tenancy.get_workspace_by_id(default_ws.id).settings["theme"] ==
               default_theme_before
    end
  end

  describe "back-compat: flat admin spellings 302 to the scoped canonical" do
    test "flat /studio/settings 302s to the scoped settings canonical", %{
      raw: raw,
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      # The token is a member of B only → first-membership resolves B/proj_b.
      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/studio/settings")

      assert redirected_to(conn, 302) == settings_url(ws_b, proj_b)
    end

    test "flat /studio/settings preserves the query string", %{
      raw: raw,
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/studio/settings?tab=theme&x=1")

      assert redirected_to(conn, 302) == settings_url(ws_b, proj_b) <> "?tab=theme&x=1"
    end

    test "flat /studio/:dataset/_plugins 302s to the scoped plugins canonical", %{
      raw: raw,
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/studio/#{@dataset}/_plugins")

      assert redirected_to(conn, 302) == plugins_url(ws_b, proj_b)
    end

    test "flat /studio/:dataset/_plugins/:plugin/settings 302s, tail preserved", %{
      raw: raw,
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/studio/#{@dataset}/_plugins/onixedit/settings")

      assert redirected_to(conn, 302) ==
               plugins_url(ws_b, proj_b) <> "/onixedit/settings"
    end

    test "anonymous flat /studio/settings 302s to the Default scoped canonical", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      # No token → first-membership falls back to the seeded Default workspace,
      # made VISIBLE in the address bar (the whole point of the funnel).
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get("/studio/settings")

      assert redirected_to(conn, 302) == settings_url(default_ws, default_proj)
    end
  end

  defp pick_plugin do
    Barkpark.Plugins.Registry.all()
    |> Enum.map(& &1.name)
    |> Enum.sort()
    |> List.first()
  end
end
