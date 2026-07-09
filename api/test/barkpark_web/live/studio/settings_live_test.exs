defmodule BarkparkWeb.Studio.SettingsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Plugins.SettingsAudit
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Ecto.Query

  @admin_token "admin-test-token"
  @junior_token "junior-test-token"

  # ssp-w3, charter D15: Workspace Settings is Scoped-by-URL. The canonical
  # address for the seeded Default workspace's Settings panel — the flat
  # `/studio/settings` compat entry 302s here.
  defp scoped_settings_path do
    ws = Tenancy.get_default_workspace()
    proj = Tenancy.get_default_project()
    "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio/settings"
  end

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio when no session token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/settings")
    end

    test "redirects to /studio when token lacks admin permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/settings")
    end

    test "renders form for admin token on the scoped Settings URL", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_settings_path())
      # Reframed page: "Workspace Settings" with credentials demoted to a
      # labelled sub-section (still carrying the "Plugin name" input).
      assert html =~ "Workspace Settings"
      assert html =~ "Plugin credentials"
      assert html =~ "Plugin name"

      # D15: the admin top-menu carries a scope-prefixed Settings tab, active
      # here (the tab addresses the SAME scoped Settings URL the page is on).
      assert html =~ ~s(href="#{scoped_settings_path()}" class="studio-tab active")
      assert html =~ ">Settings</a>"
    end

    test "flat /studio/settings redirects an admin to the canonical scoped URL (D15)",
         %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      # The flat compat entry resolves the Default scope and 302s to the scoped
      # Settings route — the panel is ALWAYS URL-bound, never mount-pinned.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/studio/settings")
      assert to == scoped_settings_path()
    end

    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, scoped_settings_path())

      render_hook(view, "totally-unknown-stale-event", %{})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end
  end

  describe "workspace theme picker (ts-w4e)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, scoped_settings_path())
      {:ok, view: view, html: html}
    end

    test "renders the theme section, the current selection, and the mirror", %{html: html} do
      assert html =~ "Workspace theme"
      # The hidden mirror the BpThemeMirror hook reads.
      assert html =~ ~s(id="bp-theme-mirror")
      assert html =~ ~s(phx-hook="BpThemeMirror")
      # StudioChrome pins the seeded Default workspace → default theme is the
      # option AND is the selected one (HEEx renders the boolean attr bare).
      assert html =~ ~s(<option value="evergreen")
      assert html =~ ~r/<option value="evergreen"[^>]*selected/
    end

    test "picking a theme persists it on the current workspace and previews it",
         %{view: view} do
      ws = Barkpark.Tenancy.get_default_workspace()
      assert ws

      html =
        render_change(element(view, "form[phx-change=set_workspace_theme]"), %{theme: "evergreen"})

      # Feedback + persisted server-side.
      assert html =~ "Workspace theme set to evergreen"

      assert Barkpark.Tenancy.workspace_theme(Barkpark.Tenancy.get_workspace_by_id(ws.id)) ==
               "evergreen"

      # Mirror carries the live value for the hook to stamp.
      assert html =~ ~s(data-bp-theme="evergreen")
    end

    test "a forged unknown theme is rejected server-side", %{view: view} do
      html =
        render_change(element(view, "form[phx-change=set_workspace_theme]"), %{
          theme: "forged-9000"
        })

      assert html =~ "Unknown theme"
    end
  end

  describe "load / save / reveal / delete" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, scoped_settings_path())
      {:ok, view: view}
    end

    test "save valid JSON stores settings and emits write audit", %{view: view} do
      json = ~s({"api_key": "supersecret-1234", "url": "https://x.example"})

      # First set the plugin_name in the LV state via the load form's
      # phx-change="update_name" — LiveView 1.1+ rejects test forms that
      # override a hidden input's server-rendered value, so we sync state
      # before submitting save.
      view
      |> form("form[phx-submit=load]", %{plugin_name: "myplug"})
      |> render_change()

      view
      |> form("form[phx-submit=save]", %{settings_json: json})
      |> render_submit()

      # row exists
      assert {:ok, %{"api_key" => "supersecret-1234"}} = Settings.reveal("myplug")

      # write audit row
      assert audited?("myplug", "write")
    end

    test "load shows masked values", %{view: view} do
      Settings.put("masktest", %{"api_key" => "longsecretvalue"})

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "masktest"})
        |> render_submit()

      # last 4 chars exposed, prefix masked
      assert html =~ "********alue"
      refute html =~ "longsecretvalue"
    end

    test "reveal fetches unmasked + writes reveal audit", %{view: view} do
      Settings.put("revealme", %{"api_key" => "longsecretvalue"})

      view
      |> form("form[phx-submit=load]", %{plugin_name: "revealme"})
      |> render_submit()

      html = render_click(view, "reveal", %{"plugin_name" => "revealme"})

      assert html =~ "longsecretvalue"
      assert audited?("revealme", "reveal")
    end

    test "delete removes row + writes delete audit", %{view: view} do
      Settings.put("zapme", %{"k" => "v"})

      view
      |> form("form[phx-submit=load]", %{plugin_name: "zapme"})
      |> render_submit()

      render_click(view, "delete", %{"plugin_name" => "zapme"})

      assert {:error, :not_found} = Settings.get("zapme")
      assert audited?("zapme", "delete")
    end

    test "generic save with untouched masked JSON preserves stored secrets", %{view: view} do
      original = %{"api_key" => "supersecret-1234", "url" => "https://x.example"}
      Settings.put("jsonplug", original)

      view
      |> form("form[phx-submit=load]", %{plugin_name: "jsonplug"})
      |> render_submit()

      # Re-submit the masked JSON exactly as it was loaded (user edited nothing).
      masked_json = Jason.encode!(Masking.mask(original), pretty: true)

      view
      |> form("form[phx-submit=save]", %{settings_json: masked_json})
      |> render_submit()

      assert {:ok, stored} = Settings.get("jsonplug")
      assert stored["api_key"] == "supersecret-1234"
      assert stored["url"] == "https://x.example"
    end
  end

  describe "typed renderer driven by settings_schema/0 (bokbasen example)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      prev = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prev),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end)

      {:ok, conn: conn}
    end

    test "loading bokbasen renders 5 typed inputs (no raw textarea)", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_settings_path())

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
        |> render_submit()

      assert html =~ ~s(data-preset="bokbasen")
      assert html =~ ~s(name="api_base")
      assert html =~ ~s(name="oauth_token_url")
      assert html =~ ~s(name="client_id")
      assert html =~ ~s(name="client_secret")
      assert html =~ ~s(name="client_role")
      assert html =~ ~s(type="password")
      refute html =~ ~s(id="settings_json")
    end

    test "submitting the typed form persists via Settings.put", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_settings_path())

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      view
      |> form(~s(form[data-preset="bokbasen"]), %{
        api_base: "https://api.bokbasen.io",
        oauth_token_url: "https://login.bokbasen.io/oauth2/token",
        client_id: "ui-client-id",
        client_secret: "ui-secret-value",
        client_role: "publisher"
      })
      |> render_submit()

      assert {:ok,
              %{
                "client_id" => "ui-client-id",
                "client_secret" => "ui-secret-value",
                "api_base" => "https://api.bokbasen.io",
                "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
                "client_role" => "publisher"
              }} = Settings.reveal("bokbasen")
    end

    test "loading bokbasen masks secrets but shows URL + role plain", %{conn: conn} do
      Settings.put("bokbasen", %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "longclientidvalue",
        "client_secret" => "longsecretvalue",
        "client_role" => "publisher"
      })

      {:ok, view, _html} = live(conn, scoped_settings_path())

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
        |> render_submit()

      refute html =~ "longclientidvalue"
      refute html =~ "longsecretvalue"
      assert html =~ "********alue"
      assert html =~ "https://api.bokbasen.io"
      assert html =~ ~s(value="publisher")
    end

    test "rejects submit with missing required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_settings_path())

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      html =
        view
        |> form(~s(form[data-preset="bokbasen"]), %{
          api_base: "",
          oauth_token_url: "",
          client_id: "x",
          client_secret: "y",
          client_role: "publisher"
        })
        |> render_submit()

      assert html =~ "Missing or invalid"
      assert {:error, :not_found} = Settings.get("bokbasen")
    end

    test "save with untouched masked secrets preserves the stored credentials", %{conn: conn} do
      Settings.put("bokbasen", %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "longclientidvalue",
        "client_secret" => "longsecretvalue",
        "client_role" => "publisher"
      })

      {:ok, view, _html} = live(conn, scoped_settings_path())

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      # Change only the (non-secret) role; leave both masked inputs at the
      # placeholder the server rendered.
      view
      |> form(~s(form[data-preset="bokbasen"]), %{
        api_base: "https://api.bokbasen.io",
        oauth_token_url: "https://login.bokbasen.io/oauth2/token",
        client_id: Masking.mask("longclientidvalue"),
        client_secret: Masking.mask("longsecretvalue"),
        client_role: "distributor"
      })
      |> render_submit()

      assert {:ok, stored} = Settings.get("bokbasen")
      assert stored["client_secret"] == "longsecretvalue"
      assert stored["client_id"] == "longclientidvalue"
      assert stored["client_role"] == "distributor"
    end

    test "save with a newly typed secret persists the new value", %{conn: conn} do
      Settings.put("bokbasen", %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "longclientidvalue",
        "client_secret" => "longsecretvalue",
        "client_role" => "publisher"
      })

      {:ok, view, _html} = live(conn, scoped_settings_path())

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      view
      |> form(~s(form[data-preset="bokbasen"]), %{
        api_base: "https://api.bokbasen.io",
        oauth_token_url: "https://login.bokbasen.io/oauth2/token",
        client_id: Masking.mask("longclientidvalue"),
        client_secret: "brand-new-secret-9999",
        client_role: "publisher"
      })
      |> render_submit()

      assert {:ok, stored} = Settings.get("bokbasen")
      # a value that does not equal the mask is a real edit → persisted
      assert stored["client_secret"] == "brand-new-secret-9999"
      # the untouched masked id stays at the stored value
      assert stored["client_id"] == "longclientidvalue"
    end
  end

  describe "plugins section (studio-structure-polish D2/D4/D10)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, scoped_settings_path())
      {:ok, view: view, html: html}
    end

    test "lists installed plugins, each row carrying a default badge when no override exists",
         %{html: html} do
      assert html =~ ">Plugins<"

      installed = Barkpark.Plugins.Registry.all()
      assert installed != []

      name = pick_plugin()
      # The plugin's row is present, marked as having NO workspace override, so a
      # 'default' badge renders (surfacing the declaration default).
      assert html =~ ~s(data-plugin="#{name}")
      assert html =~ ~s(data-has-override="false")
      # The badge chip itself + the declaration-default microcopy ("… by default").
      assert html =~ "by default"

      # Honest, non-destructive microcopy near the toggles.
      assert html =~ "…Rest"
    end

    test "toggling a plugin persists into settings[\"plugins\"] and preserves the theme key",
         %{view: view} do
      ws = Barkpark.Tenancy.get_default_workspace()
      assert ws

      # Seed a theme so we can prove the persist MERGES rather than clobbers.
      {:ok, _} = Barkpark.Tenancy.set_workspace_theme(ws.id, "evergreen")

      name = pick_plugin()

      render_click(view, "toggle_plugin", %{"plugin" => name})

      fresh = Barkpark.Tenancy.get_workspace_by_id(ws.id)
      plugins = Barkpark.Tenancy.workspace_plugin_settings(fresh)

      assert Map.has_key?(plugins, name)
      assert is_boolean(plugins[name]["enabled"])
      # The theme key survives the plugins write (merge, not replace).
      assert fresh.settings["theme"] == "evergreen"
    end

    test "a workspace override wins over the declaration default and drops the badge",
         %{conn: conn} do
      ws = Barkpark.Tenancy.get_default_workspace()
      name = pick_plugin()

      # Force the plugin OFF via the accessor, independent of its declaration
      # default, THEN mount fresh so the row reflects the persisted override.
      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{name => %{"enabled" => false}})

      effective = Barkpark.Plugins.Enablement.effective(ws.id)
      assert effective[name].enabled == false

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_settings_path())

      # The row now advertises an override (no 'default' badge) and Disabled state.
      # Placement is left to whatever the declaration default resolves to.
      assert Regex.match?(
               ~r/data-plugin="#{Regex.escape(name)}" data-enabled="false" data-placement="[a-z_]+" data-has-override="true"/,
               html
             )
    end

    test "placement change persists to settings[\"plugins\"] and re-resolves via Enablement",
         %{view: view} do
      ws = Barkpark.Tenancy.get_default_workspace()
      name = pick_plugin()

      render_change(view, "set_plugin_placement", %{"plugin" => name, "placement" => "main"})

      fresh = Barkpark.Tenancy.get_workspace_by_id(ws.id)
      plugins = Barkpark.Tenancy.workspace_plugin_settings(fresh)
      assert plugins[name]["placement"] == "main"

      effective = Barkpark.Plugins.Enablement.effective(ws.id)
      assert effective[name].placement == :main
    end

    test "a forged placement is ignored (unknown value never persists)", %{view: view} do
      ws = Barkpark.Tenancy.get_default_workspace()
      name = pick_plugin()

      render_change(view, "set_plugin_placement", %{
        "plugin" => name,
        "placement" => "forged-9000"
      })

      fresh = Barkpark.Tenancy.get_workspace_by_id(ws.id)
      plugins = Barkpark.Tenancy.workspace_plugin_settings(fresh)
      refute get_in(plugins, [name, "placement"]) == "forged-9000"
    end
  end

  # ── Scoped-by-URL write hazard is closed (ssp-w3, charter D15/D17) ────────
  #
  # THE epic's only known real defect: Workspace Settings bound its workspace at
  # mount (always the seeded Default) and ignored the scope switcher, so a toggle
  # wrote to the WRONG workspace. After D15 the panel is URL-scoped; a scope
  # switch RE-BINDS it, and the fail-closed guard refuses a visibly-stale write.
  describe "scoped-by-URL write hazard closed (D15/D17)" do
    setup %{conn: conn} do
      {:ok, token} = Auth.verify_token(@admin_token)

      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "ssp-wa", name: "SSP Workspace A"})
      {:ok, proj_a} = Tenancy.create_project_with_dataset(ws_a, %{name: "PA"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "ssp-wb", name: "SSP Workspace B"})
      {:ok, proj_b} = Tenancy.create_project_with_dataset(ws_b, %{name: "PB"})

      # The admin token must be a MEMBER of both scopes for LiveScope to resolve
      # them (membership + the token's :read permission).
      {:ok, _} = TenancyAuth.create_membership(ws_a.id, token.id, "admin")
      {:ok, _} = TenancyAuth.create_membership(ws_b.id, token.id, "admin")

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
    end

    defp settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio/settings"

    test "the panel binds its workspace FROM the URL (not the seeded Default)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, view, html} = live(conn, settings_url(ws_a, proj_a))

      # URL-bound, not Default-pinned.
      assert :sys.get_state(view.pid).socket.assigns.current_workspace.id == ws_a.id
      # The header names the bound workspace prominently.
      assert html =~ ~s(data-test-id="settings-bound-workspace")
      assert html =~ ~s(data-workspace-id="#{ws_a.id}")
      assert html =~ ws_a.name
    end

    test "a scope switch FROM Settings lands on the NEW scope's Settings, and writes land there — not the old (D16)",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, settings_url(ws_a, proj_a))
      assert :sys.get_state(view.pid).socket.assigns.current_workspace.id == ws_a.id

      # Switching to B from Settings navigates to B's SETTINGS URL (scope_subpath
      # seam), never the desk root.
      render_click(view, "scope-open", %{
        "ws" => ws_b.slug,
        "proj" => proj_b.slug,
        "ds" => "production"
      })

      assert_redirect(view, settings_url(ws_b, proj_b))

      # Under B's Settings, a toggle writes to B — and A stays untouched.
      {:ok, view_b, _html} = live(conn, settings_url(ws_b, proj_b))
      name = pick_plugin()
      render_click(view_b, "toggle_plugin", %{"plugin" => name, "ws" => ws_b.id})

      assert Map.has_key?(
               Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(ws_b.id)),
               name
             ),
             "the write must land on the URL-bound workspace B"

      refute Map.has_key?(
               Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(ws_a.id)),
               name
             ),
             "the write must NOT leak into workspace A (the old mount-pinned hazard)"
    end

    test "a toggle carrying a forged ws id (≠ the URL-bound scope) is REFUSED — no write", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {:ok, view, _html} = live(conn, settings_url(ws_a, proj_a))
      name = pick_plugin()

      # Forge B's id into a control rendered under A's scope: the guard compares
      # it to the URL-bound A and refuses.
      html = render_click(view, "toggle_plugin", %{"plugin" => name, "ws" => ws_b.id})

      assert html =~ "Scope changed"

      refute Map.has_key?(
               Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(ws_a.id)),
               name
             ),
             "a forged-scope toggle must not persist on the bound workspace"

      refute Map.has_key?(
               Tenancy.workspace_plugin_settings(Tenancy.get_workspace_by_id(ws_b.id)),
               name
             ),
             "a forged-scope toggle must not persist on the forged workspace either"
    end

    test "a set_workspace_theme carrying a forged ws id is REFUSED — theme unchanged", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {:ok, view, _html} = live(conn, settings_url(ws_a, proj_a))

      before_a = Tenancy.workspace_theme(Tenancy.get_workspace_by_id(ws_a.id))

      html =
        render_change(view, "set_workspace_theme", %{"theme" => "evergreen", "ws" => ws_b.id})

      assert html =~ "Scope changed"

      assert Tenancy.workspace_theme(Tenancy.get_workspace_by_id(ws_a.id)) == before_a,
             "a forged-scope theme write must not change the bound workspace's theme"
    end
  end

  defp pick_plugin do
    Barkpark.Plugins.Registry.all()
    |> Enum.map(& &1.name)
    |> Enum.sort()
    |> List.first()
  end

  defp audited?(plugin, action) do
    Repo.exists?(
      from a in SettingsAudit,
        where: a.plugin_name == ^plugin and a.action == ^action
    )
  end
end
