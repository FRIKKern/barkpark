defmodule BarkparkWeb.Studio.SettingsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking
  alias Barkpark.Plugins.SettingsAudit
  alias Barkpark.Repo

  import Ecto.Query

  @admin_token "admin-test-token"
  @junior_token "junior-test-token"

  # SettingsLive moved to the workspace-scoped canonical
  # `/w/:ws/p/:proj/studio/settings` (sdl-w1-admin-canonical): LiveScope binds
  # the panel to the URL workspace instead of the seeded Default the flat route
  # pinned. `ensure_default_scope!` uses the "default"/"default" slugs.
  @settings_path "/w/default/p/default/studio/settings"

  setup %{conn: conn} do
    # Default workspace/project must exist BEFORE the token is minted:
    # `Auth.create_token` auto-binds an "admin"-perm token as an admin MEMBER of
    # the Default workspace, which is exactly the membership the scoped route's
    # LiveScope authorizes against.
    ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio when no session token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, @settings_path)
    end

    test "redirects to /studio when token lacks admin permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, @settings_path)
    end

    test "renders form for admin token", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, @settings_path)
      # Reframed page: "Workspace Settings" with credentials demoted to a
      # labelled sub-section (still carrying the "Plugin name" input).
      assert html =~ "Workspace Settings"
      assert html =~ "Plugin credentials"
      assert html =~ "Plugin name"
    end

    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @settings_path)

      render_hook(view, "totally-unknown-stale-event", %{})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end
  end

  # studio-ui-premium sup-w1 — the Settings page is rebuilt on the tokenized
  # StudioComponents.Controls kit: zero native/unthemed controls, no hardcoded
  # font, deliberate card/section-header structure. These assertions are the
  # before/after evidence for the "zero native controls" acceptance criterion.
  describe "themed controls kit (studio-ui-premium sup-w1)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @settings_path)
      # Scope the assertions to the Settings page body only — the surrounding
      # Studio chrome (top bar, layout) is not this slice's surface.
      body = view |> element("div.settings-live") |> render()
      {:ok, body: body}
    end

    test "no hardcoded native font — the page inherits the token font", %{body: body} do
      refute body =~ "ui-sans-serif"
      refute body =~ "ui-monospace"
    end

    test "every <select> is themed (.form-input) — no bare native dropdown", %{body: body} do
      # There IS at least one select in the Settings body (the theme picker +
      # per-plugin placement selects).
      assert body =~ "<select"
      # A <select> tag WITHOUT the tokenized .form-input class is a native
      # control — there must be none.
      refute body =~ ~r/<select\b(?![^>]*form-input)[^>]*>/
    end

    test "every checkbox is a themed switch — no bare native checkbox", %{body: body} do
      checkboxes = length(Regex.scan(~r/type="checkbox"/, body))
      switches = length(Regex.scan(~r/class="form-switch"/, body))
      # Plugin toggles render as switches; each checkbox is wrapped by exactly
      # one .form-switch, so the counts match (and there is at least one).
      assert checkboxes > 0
      assert checkboxes == switches
    end

    test "the tokenized primitives are present — card, section header, form-input, switch",
         %{body: body} do
      # Sections are .card surfaces with weighted .h2 headers.
      assert body =~ ~s(class="card")
      assert body =~ ~s(class="h2")
      # Themed inputs + the switch anatomy.
      assert body =~ "form-input"
      assert body =~ ~s(class="form-switch")
      assert body =~ ~s(class="form-switch-track")
      assert body =~ ~s(class="form-switch-state")
    end
  end

  describe "workspace theme picker (ts-w4e)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @settings_path)
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
      {:ok, view, _html} = live(conn, @settings_path)
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
      {:ok, view, _html} = live(conn, @settings_path)

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
      {:ok, view, _html} = live(conn, @settings_path)

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

      {:ok, view, _html} = live(conn, @settings_path)

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
      {:ok, view, _html} = live(conn, @settings_path)

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

      {:ok, view, _html} = live(conn, @settings_path)

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

      {:ok, view, _html} = live(conn, @settings_path)

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
      {:ok, view, html} = live(conn, @settings_path)
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
      {:ok, _view, html} = live(conn, @settings_path)

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

  describe "scoped-by-URL write hazard closed (D15/D17)" do
    setup %{conn: conn} do
      {:ok, token} = Auth.verify_token(@admin_token)

      {:ok, ws_a} = Barkpark.Tenancy.create_workspace(%{slug: "ssp-wa", name: "SSP Workspace A"})
      {:ok, proj_a} = Barkpark.Tenancy.create_project_with_dataset(ws_a, %{name: "PA"})
      {:ok, ws_b} = Barkpark.Tenancy.create_workspace(%{slug: "ssp-wb", name: "SSP Workspace B"})
      {:ok, proj_b} = Barkpark.Tenancy.create_project_with_dataset(ws_b, %{name: "PB"})

      # The admin token must be a MEMBER of both scopes for LiveScope to resolve
      # them (membership + the token's :read permission).
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_a.id, token.id, "admin")
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, token.id, "admin")

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
    end

    defp settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"

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
               Barkpark.Tenancy.workspace_plugin_settings(
                 Barkpark.Tenancy.get_workspace_by_id(ws_b.id)
               ),
               name
             ),
             "the write must land on the URL-bound workspace B"

      refute Map.has_key?(
               Barkpark.Tenancy.workspace_plugin_settings(
                 Barkpark.Tenancy.get_workspace_by_id(ws_a.id)
               ),
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
               Barkpark.Tenancy.workspace_plugin_settings(
                 Barkpark.Tenancy.get_workspace_by_id(ws_a.id)
               ),
               name
             ),
             "a forged-scope toggle must not persist on the bound workspace"

      refute Map.has_key?(
               Barkpark.Tenancy.workspace_plugin_settings(
                 Barkpark.Tenancy.get_workspace_by_id(ws_b.id)
               ),
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

      before_a = Barkpark.Tenancy.workspace_theme(Barkpark.Tenancy.get_workspace_by_id(ws_a.id))

      html =
        render_change(view, "set_workspace_theme", %{"theme" => "evergreen", "ws" => ws_b.id})

      assert html =~ "Scope changed"

      assert Barkpark.Tenancy.workspace_theme(Barkpark.Tenancy.get_workspace_by_id(ws_a.id)) ==
               before_a,
             "a forged-scope theme write must not change the bound workspace's theme"
    end
  end

  describe "typeless-enable feedback hint (studio-structure-polish D19)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, conn: conn}
    end

    test "an enabled plugin whose owned types are UNREGISTERED shows the 'no content types' truth",
         %{conn: conn} do
      # Remove EVERY globally-registered bulldocs schema for this test's scope,
      # so bulldocs — enabled by declaration default — owns a type registered
      # NOWHERE in this workspace. Enabling it surfaced nothing, and the row
      # says so honestly (the common Default-stamp case). One unregister per
      # owned type: leaving ANY of them registered flips the hint to the softer
      # "types registered" truth (exactly what this assertion exists to
      # distinguish).
      #
      # The list is DERIVED from `Bulldocs.register_schemas/1` — the same source
      # the LV's `Structure.owned_schema_types_map/0` reads — rather than
      # hardcoded. A hardcoded pair went stale the moment bulldocs grew a third
      # schema (`session`, session-handoff task 3) and this test failed with the
      # softer hint; deriving it means the next schema added can never do that.
      unregister_bulldocs_owned_types!()

      {:ok, view, _html} = live(conn, scoped_settings_path())

      assert has_element?(view, ~s([data-plugin-hint="bulldocs"]))

      hint = view |> element(~s([data-plugin-hint="bulldocs"])) |> render()
      assert hint =~ "Enabled — no content types in this workspace yet"
      refute hint =~ "types registered, no documents yet"
    end

    test "an enabled plugin whose owned types are REGISTERED but document-less shows the softer truth",
         %{conn: conn} do
      # Ambient test DB: `paper` is registered globally with NO documents (empty
      # census), so bulldocs' hint softens: types exist, docs don't — explicitly
      # NOT the harder 'no content types' message.
      {:ok, view, _html} = live(conn, scoped_settings_path())

      hint = view |> element(~s([data-plugin-hint="bulldocs"])) |> render()
      assert hint =~ "Enabled — types registered, no documents yet"
      refute hint =~ "no content types in this workspace yet"
    end

    test "NO hint once a document of an owned type exists (enabling it surfaced content)",
         %{conn: conn} do
      # `paper` is already registered; give it a document and the census is no
      # longer empty → bulldocs surfaced content, so no hint at all.
      insert_type_doc!("paper")

      {:ok, view, _html} = live(conn, scoped_settings_path())

      refute has_element?(view, ~s([data-plugin-hint="bulldocs"]))
    end

    test "a DISABLED plugin never shows a hint", %{conn: conn} do
      # onixedit is OFF by declaration default and owns the `book` type; a
      # disabled plugin's silence is expected, so no hint even though `book`
      # is registered-and-docless (the truth-2 predicate for an ENABLED plugin).
      {:ok, view, _html} = live(conn, scoped_settings_path())

      refute has_element?(view, ~s([data-plugin-hint="onixedit"]))
    end
  end

  # The canonical scoped Settings address for the seeded Default workspace.
  # main's route is PROJECT-level (no dataset segment, #1936).
  defp scoped_settings_path do
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"
  end

  defp unregister_type!(name) do
    Repo.delete_all(from(s in Barkpark.Content.SchemaDefinition, where: s.name == ^name))
  end

  # Every type bulldocs OWNS, straight off the plugin's own schema declaration
  # (`register_schemas/1` returns one `%SchemaDefinition{}` per shipped
  # schema JSON). Adding a schema to the plugin automatically widens this.
  defp unregister_bulldocs_owned_types! do
    Barkpark.Plugins.Bulldocs.register_schemas([])
    |> Enum.each(&unregister_type!(&1.name))
  end

  defp insert_type_doc!(type) do
    Repo.insert!(%Barkpark.Content.Document{
      doc_id: "#{type}-1",
      type: type,
      dataset: "production",
      status: "published",
      title: "#{type} 1",
      rev: "rev-#{type}-1",
      content: %{}
    })
  end

  # ── Chat execution profile toggle (connectors W23-2, D207/D211 → W26) ────
  #
  # The write surface for the per-workspace chat execution profile. W23-2
  # added the PER-WRITE `workspace_admin?/2` re-gate because the mount gate was
  # a GLOBAL-permission admin check (D207). W26 fixed the mount gate itself
  # (`LiveAuth.:scoped_admin` authorizes against the TARGET workspace), so the
  # flat-global-admin read-member is now rejected AT MOUNT — the per-write
  # re-gate stays in the LV as belt-and-suspenders behind it.
  describe "chat execution profile toggle (W23-2)" do
    setup do
      # Two tokens, BOTH holding the flat global admin permission so BOTH clear
      # the coarse mount gate. The per-write re-gate is the ONLY thing that
      # separates them at the target workspace.
      {:ok, admin_tok} =
        Auth.create_token("ep-admin-raw", "ep admin", "production", ["read", "write", "admin"])

      {:ok, outsider_tok} =
        Auth.create_token(
          "ep-outsider-raw",
          "ep outsider",
          "production",
          ["read", "write", "admin"]
        )

      {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "ep-ws", name: "Exec Profile WS"})
      {:ok, proj} = Barkpark.Tenancy.create_project_with_dataset(ws, %{name: "EPP"})

      # admin_tok is an ADMIN of the target ws; outsider_tok is only a MEMBER —
      # read access lets it mount (LiveScope), but it is NOT a workspace admin.
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, outsider_tok.id)

      {:ok, ws: ws, proj: proj}
    end

    defp ep_settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"

    test "renders the execution-profile control, defaulting to self-hosted when unset", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      conn = init_test_session(conn, %{"api_token" => "ep-admin-raw"})
      {:ok, _view, html} = live(conn, ep_settings_url(ws, proj))

      assert html =~ "Chat execution profile"
      assert html =~ ~s(data-test-id="execution-profile-control")
      # Unset persisted value → the switch reads self-hosted (the resolver's
      # fail-safe default), never cloud.
      assert html =~ ~s(data-execution-profile="self_hosted")
    end

    test "REJECTED AT MOUNT (W26): a flat-global-admin read-member of the target workspace never reaches the panel — nothing is written",
         %{conn: conn, ws: ws, proj: proj} do
      # The outsider holds the flat global admin perm — the shape that mounted
      # this panel pre-W26 and was only stopped by the per-write re-gate. The
      # `:scoped_admin` mount gate now refuses it outright: no view exists to
      # fire the toggle at, and nothing is ever written.
      conn = init_test_session(conn, %{"api_token" => "ep-outsider-raw"})

      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, ep_settings_url(ws, proj))

      assert Barkpark.Tenancy.workspace_chat_settings(Barkpark.Tenancy.get_workspace_by_id(ws.id)) ==
               %{},
             "a non-admin mount must not persist any chat settings"
    end

    test "happy path: an owner/admin of the workspace flips to cloud, it persists, and theme + plugin keys survive the merge",
         %{conn: conn, ws: ws, proj: proj} do
      # Seed unrelated settings keys FIRST so the merge-in-place chat write is
      # proven non-clobbering.
      {:ok, _} = Barkpark.Tenancy.set_workspace_theme(ws.id, "evergreen")

      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
          "onixedit" => %{"enabled" => false}
        })

      conn = init_test_session(conn, %{"api_token" => "ep-admin-raw"})
      {:ok, view, _html} = live(conn, ep_settings_url(ws, proj))

      html = render_click(view, "toggle_execution_profile", %{"ws" => ws.id})
      assert html =~ "cloud sandbox"

      ws_after = Barkpark.Tenancy.get_workspace_by_id(ws.id)
      assert Barkpark.Tenancy.workspace_chat_settings(ws_after)["execution_profile"] == "cloud"
      # Merge-in-place preserved the sibling settings namespaces.
      assert Barkpark.Tenancy.workspace_theme(ws_after) == "evergreen"
      assert Map.has_key?(Barkpark.Tenancy.workspace_plugin_settings(ws_after), "onixedit")

      # The toggle is a server-derived flip: a second click round-trips back to
      # self-hosted, never trusting a client-supplied value.
      {:ok, view2, _html} = live(conn, ep_settings_url(ws, proj))
      render_click(view2, "toggle_execution_profile", %{"ws" => ws.id})

      assert Barkpark.Tenancy.workspace_chat_settings(Barkpark.Tenancy.get_workspace_by_id(ws.id))[
               "execution_profile"
             ] == "self_hosted"
    end

    test "a garbage persisted profile never propagates — a flip yields a known-good value", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      # Corrupt the stored value directly, then toggle. The handler derives the
      # next value from `current == "cloud"` (false for garbage) → "cloud", a
      # known-good value guarded against `~w(cloud self_hosted)` before the write.
      {:ok, _} =
        Barkpark.Tenancy.set_workspace_chat_settings(ws.id, %{"execution_profile" => "banana"})

      conn = init_test_session(conn, %{"api_token" => "ep-admin-raw"})
      {:ok, view, _html} = live(conn, ep_settings_url(ws, proj))
      render_click(view, "toggle_execution_profile", %{"ws" => ws.id})

      profile =
        Barkpark.Tenancy.workspace_chat_settings(Barkpark.Tenancy.get_workspace_by_id(ws.id))[
          "execution_profile"
        ]

      assert profile in ~w(cloud self_hosted)
      assert profile == "cloud"
    end
  end

  # ── Per-write workspace_admin? re-gate on theme/plugin writes (W34, D268) ──
  #
  # Belt parity with toggle_execution_profile (W23-2/D211). The W26
  # `:scoped_admin` mount gate rejects an outsider AT MOUNT, so the LIVE threat
  # these tests model is NOT an outsider mounting — it is a role DOWNGRADE that
  # lands AFTER a legitimate admin has already mounted (defense-in-depth: a
  # LiveView outlives the mount check). Each test mounts as a real workspace
  # admin, downgrades that membership admin → member mid-socket via a direct
  # Repo write (there is no public revoke API), then fires the handler on the
  # STILL-MOUNTED view. `workspace_admin?/2` does a fresh `Repo.one` per call
  # (auth.ex membership/2 — zero socket cache), so the downgrade is seen at the
  # very next click and the write must fail closed.
  #
  # ORACLE LAW (D268): the load-bearing assertion is the targeted STATE being
  # UNCHANGED (theme read-back / plugin-override map). The bare substring
  # `html =~ "owner or admin of this workspace"` is FORBIDDEN — it also matches
  # the static help text at settings_live.ex and passes with the belt deleted.
  # The flash oracle here is the refusal-UNIQUE prefix "You need to be an owner
  # or admin" (do_toggle_execution_profile's wording), never the static phrase.
  describe "per-write workspace_admin? re-gate — theme/plugin writes (W34, D268)" do
    setup %{conn: conn} do
      {:ok, admin_tok} =
        Auth.create_token("w34-admin-raw", "w34 admin", "production", ["read", "write", "admin"])

      {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "w34-ws", name: "W34 Belt WS"})
      {:ok, proj} = Barkpark.Tenancy.create_project_with_dataset(ws, %{name: "W34P"})

      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")

      conn = init_test_session(conn, %{"api_token" => "w34-admin-raw"})
      {:ok, conn: conn, ws: ws, proj: proj, admin_tok: admin_tok}
    end

    defp w34_settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"

    # Mid-socket role downgrade with NO public revoke API: mutate the membership
    # row directly admin → member. Targeted by principal_id so the write is
    # unambiguous even if the workspace later grows other memberships.
    defp downgrade_to_member!(ws, principal_id) do
      Barkpark.Tenancy.Membership
      |> Repo.get_by!(workspace_id: ws.id, principal_id: principal_id)
      |> Ecto.Changeset.change(role: "member")
      |> Repo.update!()
    end

    defp reread(ws), do: Barkpark.Tenancy.get_workspace_by_id(ws.id)

    test "set_workspace_theme is REFUSED after a mid-socket admin→member downgrade — theme unchanged",
         %{conn: conn, ws: ws, proj: proj, admin_tok: admin_tok} do
      {:ok, view, _html} = live(conn, w34_settings_url(ws, proj))

      # Baseline: this fresh workspace has NO persisted "theme" settings key.
      # (The RESOLVED theme defaults to "evergreen" — the only theme shipping —
      # so we must assert on the raw persisted key, not the resolved value, or a
      # refused write is indistinguishable from a landed one.)
      refute Map.has_key?(reread(ws).settings || %{}, "theme")

      downgrade_to_member!(ws, admin_tok.id)

      html =
        render_change(view, "set_workspace_theme", %{"theme" => "evergreen", "ws" => ws.id})

      # STATE ORACLE (load-bearing): the write never persisted settings["theme"].
      refute Map.has_key?(reread(ws).settings || %{}, "theme")
      # Flash oracle: refusal-unique prefix present, success phrase absent.
      assert html =~ "You need to be an owner or admin"
      refute html =~ "Workspace theme set to"
    end

    test "toggle_plugin is REFUSED after a mid-socket admin→member downgrade — no override persisted",
         %{conn: conn, ws: ws, proj: proj, admin_tok: admin_tok} do
      {:ok, view, _html} = live(conn, w34_settings_url(ws, proj))
      name = pick_plugin()

      # Baseline: no plugin override exists for this workspace.
      refute Map.has_key?(Barkpark.Tenancy.workspace_plugin_settings(reread(ws)), name)

      downgrade_to_member!(ws, admin_tok.id)

      html = render_click(view, "toggle_plugin", %{"plugin" => name, "ws" => ws.id})

      # STATE ORACLE (load-bearing): no plugin override was written.
      refute Map.has_key?(Barkpark.Tenancy.workspace_plugin_settings(reread(ws)), name)
      assert html =~ "You need to be an owner or admin"
    end

    test "set_plugin_placement is REFUSED after a mid-socket admin→member downgrade — no placement override persisted",
         %{conn: conn, ws: ws, proj: proj, admin_tok: admin_tok} do
      {:ok, view, _html} = live(conn, w34_settings_url(ws, proj))
      name = pick_plugin()

      refute Map.has_key?(Barkpark.Tenancy.workspace_plugin_settings(reread(ws)), name)

      downgrade_to_member!(ws, admin_tok.id)

      html =
        render_change(view, "set_plugin_placement", %{
          "plugin" => name,
          "placement" => "main",
          "ws" => ws.id
        })

      # STATE ORACLE (load-bearing): no placement override was written.
      refute Map.has_key?(Barkpark.Tenancy.workspace_plugin_settings(reread(ws)), name)
      assert html =~ "You need to be an owner or admin"
    end
  end

  # ── Installation-admin re-gate on credential handlers (W35, D274 — E2) ──
  #
  # Plugin credentials live in the installation-GLOBAL `plugin_settings` store
  # (PK plugin_name, no tenant column): one shared account per deployment. The
  # W26 `:scoped_admin` mount gate only proves the actor administers the URL
  # workspace, so pre-W35 an admin of workspace B and ONLY B could mount
  # /w/B/…/studio/settings and reveal / overwrite / delete EVERY tenant's
  # credentials. These tests model exactly that principal — an admin membership
  # of B with NO installation authority (token arm: no flat global "admin"
  # perm; user arm: no Default-workspace admin role) — and prove each
  # credential handler refuses with the plugin_settings row byte-UNCHANGED.
  #
  # ORACLE LAW (D268): the load-bearing assertion is STATE — the SettingsRecord
  # row read back and compared whole (any write, re-encrypt, or delete flips
  # it), plus the audit table for reveal. Flash copy is secondary.
  describe "installation-admin re-gate on credential handlers (W35, D274 — E2)" do
    alias Barkpark.Plugins.SettingsRecord

    @w35_secret "installation-secret-xyz"

    setup %{conn: conn} do
      # Token principal: admin OF WORKSPACE B via membership role — clears the
      # role-only W26 mount gate — but WITHOUT the flat global "admin"
      # permission, so it holds no installation-level authority.
      {:ok, b_admin_tok} =
        Auth.create_token("w35-b-admin-raw", "w35 b-only admin", "production", ["read", "write"])

      {:ok, ws_b} = Barkpark.Tenancy.create_workspace(%{slug: "w35-wb", name: "W35 Cred WS B"})
      {:ok, proj_b} = Barkpark.Tenancy.create_project_with_dataset(ws_b, %{name: "W35PB"})
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, b_admin_tok.id, "admin")

      # The installation-global victim row every tenant shares.
      {:ok, _} = Settings.put("w35-victim", %{"api_key" => @w35_secret})

      conn = init_test_session(conn, %{"api_token" => "w35-b-admin-raw"})
      {:ok, conn: conn, ws_b: ws_b, proj_b: proj_b}
    end

    defp w35_settings_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"

    defp victim_row, do: Repo.get_by(SettingsRecord, plugin_name: "w35-victim")

    defp audit_count(plugin, action) do
      Repo.aggregate(
        from(a in SettingsAudit, where: a.plugin_name == ^plugin and a.action == ^action),
        :count
      )
    end

    test "reveal is REFUSED for a workspace-B-only admin — no secret in the DOM, no reveal audit, row unchanged",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))
      before = victim_row()

      html = render_click(view, "reveal", %{"plugin_name" => "w35-victim"})

      # STATE ORACLES (load-bearing): row byte-unchanged, zero reveal audit.
      assert victim_row() == before
      refute audited?("w35-victim", "reveal")
      # The secret never reaches the DOM; the refusal-unique flash does.
      refute html =~ @w35_secret
      assert html =~ "installation-admin authority"
    end

    test "save is REFUSED for a workspace-B-only admin — the shared credential row is byte-unchanged",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))
      before = victim_row()
      # The setup seed itself audits one "write" — the refused save must not
      # add another, so the ORACLE is the count staying put, not emptiness.
      write_audits_before = audit_count("w35-victim", "write")

      html =
        render_submit(view, "save", %{
          "plugin_name" => "w35-victim",
          "settings_json" => ~s({"api_key": "attacker-overwrite"})
        })

      # STATE ORACLE (load-bearing): the overwrite never landed.
      assert victim_row() == before
      assert audit_count("w35-victim", "write") == write_audits_before
      refute html =~ "Saved w35-victim"
      assert html =~ "installation-admin authority"
    end

    test "delete is REFUSED for a workspace-B-only admin — the shared credential row survives byte-identical",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))
      before = victim_row()
      assert before, "victim row must exist before the delete attempt"

      html = render_click(view, "delete", %{"plugin_name" => "w35-victim"})

      # STATE ORACLE (load-bearing): the row still exists, byte-identical.
      assert victim_row() == before
      refute audited?("w35-victim", "delete")
      refute html =~ "Deleted w35-victim"
      assert html =~ "installation-admin authority"
    end

    test "reveal_field is REFUSED for a workspace-B-only admin — typed secret stays masked, no reveal audit",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      # The typed path: seed bokbasen (spec-backed), attempt a load — which the
      # D274 follow-up now REFUSES for this principal too, so the panel stays
      # empty — then attempt the per-field reveal on top of that refused state
      # and prove it is refused in its own right (no reveal audit, row
      # unchanged). Same env hygiene as the typed-renderer suite: a host
      # carrying BOKBASEN_* env config must not perturb the spec resolution.
      prev = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prev),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end)

      Settings.put("bokbasen", %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "w35-client-id-long",
        "client_secret" => "w35-client-secret-long",
        "client_role" => "publisher"
      })

      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      before = Repo.get_by(SettingsRecord, plugin_name: "bokbasen")

      html = render_click(view, "reveal_field", %{"field" => "client_secret"})

      # STATE ORACLES (load-bearing): no reveal audit, row byte-unchanged.
      refute audited?("bokbasen", "reveal")
      assert Repo.get_by(SettingsRecord, plugin_name: "bokbasen") == before
      # The unmasked secret never reaches the DOM.
      refute html =~ "w35-client-secret-long"
      assert html =~ "installation-admin authority"
    end

    test "user arm: an account that is admin of workspace B ONLY is refused the same way — row unchanged",
         %{ws_b: ws_b, proj_b: proj_b} do
      email = "w35-b-admin-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Barkpark.Accounts.register_user(%{email: email, password: "correct-horse-battery"})

      {:ok, raw} = Barkpark.Accounts.create_user_session_token(user)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, user.id, "admin", "user")

      conn = Plug.Test.init_test_session(scoped_conn(), %{"user_session" => raw})
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))
      before = victim_row()

      html = render_click(view, "reveal", %{"plugin_name" => "w35-victim"})

      # STATE ORACLES (load-bearing): row byte-unchanged, zero reveal audit.
      assert victim_row() == before
      refute audited?("w35-victim", "reveal")
      refute html =~ @w35_secret
      assert html =~ "installation-admin authority"
    end
  end

  # ── Installation-admin gate on the LOAD path (D274 follow-up) ──────────
  #
  # W35 sealed reveal / reveal_field / save / delete and left `load` open to any
  # `:scoped_admin`. That residue is a SCOPE MISMATCH, not a forgotten line: the
  # live_session authorizes admin OF THE URL WORKSPACE, while the
  # `plugin_settings` store `load` reads is installation-GLOBAL. The masked
  # projection it rendered is partial, not anonymous — an admin of workspace B
  # and ONLY B could harvest, for any plugin name they cared to type:
  #
  #   * the LAST FOUR characters of every secret, verbatim (`Masking.mask/1`
  #     emits "********" <> last4 for any binary longer than 4 chars),
  #   * every non-`:masked` typed field in FULL plaintext (bokbasen's
  #     api_base / oauth_token_url / client_role),
  #   * the credential INVENTORY — stored key names, plus a found/not-found
  #     presence oracle over the whole installation ("No settings yet for …").
  #
  # ORACLE LAW (D268/D266). Two load-bearing oracles, neither a flash substring:
  #   (a) STATE — `Settings.get/2` writes a "read" audit row on every successful
  #       read, so a count of ZERO proves the guard refused before ANY store
  #       access (fail-closed, not mask-harder);
  #   (b) DOM — asserted against the exact `Masking.mask/1` output and its bare
  #       last-4 suffix, with the installation-admin POSITIVE CONTROL below
  #       proving both literals are reachable on this very page from this very
  #       row. Without that control the refutations could pass vacuously.
  describe "installation-admin gate on the credential LOAD path (D274 follow-up)" do
    # Longer than 4 chars ON PURPOSE: at <= 4 `Masking.mask/1` returns a bare
    # "****" with NO suffix and every refutation below would be vacuous.
    @load_secret "installation-load-secret-Qv7Z"
    @load_suffix String.slice(@load_secret, -4, 4)
    @typed_secret "w35-load-typed-secret-Bk9Q"

    setup %{conn: conn} do
      # Same principal shape as the W35 block: admin OF WORKSPACE B by
      # membership role (clears the `:scoped_admin` mount gate) with NO global
      # "admin" permission, hence no installation-level authority.
      {:ok, b_admin_tok} =
        Auth.create_token("w35l-b-admin-raw", "w35 load b-only admin", "production", [
          "read",
          "write"
        ])

      {:ok, ws_b} = Barkpark.Tenancy.create_workspace(%{slug: "w35l-wb", name: "W35L Cred WS B"})
      {:ok, proj_b} = Barkpark.Tenancy.create_project_with_dataset(ws_b, %{name: "W35LPB"})
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, b_admin_tok.id, "admin")

      # The installation-global row every tenant shares — the harvest target.
      {:ok, _} = Settings.put("w35-load-victim", %{"api_key" => @load_secret})

      conn = init_test_session(conn, %{"api_token" => "w35l-b-admin-raw"})
      {:ok, conn: conn, ws_b: ws_b, proj_b: proj_b}
    end

    test "load is REFUSED for a workspace-B-only admin — no mask suffix, no key inventory, ZERO store read",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "w35-load-victim"})
        |> render_submit()

      # (b) DOM ORACLE FIRST, deliberately: with the guard disarmed this is the
      # assertion that reds, and it reds NAMING the leak ("********Qv7Z" in the
      # page) rather than an audit count nobody can read as a disclosure.
      refute html =~ Masking.mask(@load_secret)
      refute html =~ @load_suffix
      # …nor the stored key names (the inventory half of the leak).
      refute html =~ "api_key"
      # The panel never advanced past the empty state (`@loaded?` mirror).
      assert html =~ "Status: empty"
      # (a) STATE ORACLE: zero reads of the installation-global store — the
      # refusal is fail-closed, not mask-harder. `Settings.get/2` audits every
      # successful read; the POSITIVE CONTROL below shows this counter DOES move
      # to 1 when the store is touched, so a 0 here is a live instrument.
      assert audit_count("w35-load-victim", "read") == 0
      assert html =~ "installation-admin authority"
    end

    test "POSITIVE CONTROL: an installation admin loading the SAME row still gets the masked suffix and a read audit",
         %{} do
      # Anti-vacuity: proves the mask literal, its bare suffix AND the "read"
      # audit increment are all producible on this page from this row — so the
      # refutations above fail when the guard is disarmed, and criterion 2
      # (installation-admin behaviour unchanged) holds on the same fixture.
      conn = init_test_session(scoped_conn(), %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @settings_path)

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "w35-load-victim"})
        |> render_submit()

      assert html =~ Masking.mask(@load_secret)
      assert html =~ @load_suffix
      assert html =~ "api_key"
      assert html =~ "Status: loaded"
      assert audit_count("w35-load-victim", "read") == 1
      refute html =~ @load_secret
    end

    test "the TYPED load path is refused too — no plaintext config, no secret tail, ZERO store read",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      # bokbasen is spec-backed, so `load` would take `load_typed` — which masks
      # only `:masked` fields and renders api_base / oauth_token_url /
      # client_role in FULL plaintext. Same env hygiene as the typed suite: a
      # host carrying BOKBASEN_* config must not perturb spec resolution.
      prev = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prev),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end)

      Settings.put("bokbasen", %{
        "api_base" => "https://api-sandbox.bokbasen.example",
        "oauth_token_url" => "https://login.bokbasen.example/oauth2/token",
        "client_id" => "w35-load-client-id-long",
        "client_secret" => @typed_secret,
        "client_role" => "distributor"
      })

      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
        |> render_submit()

      # DOM ORACLE FIRST (see the generic arm): no masked tail, and none of the
      # plaintext config the typed renderer would have shown in the clear.
      refute html =~ Masking.mask(@typed_secret)
      refute html =~ String.slice(@typed_secret, -4, 4)
      refute html =~ "https://api-sandbox.bokbasen.example"
      refute html =~ "https://login.bokbasen.example/oauth2/token"
      assert html =~ "Status: empty"
      # STATE ORACLE: the typed path never reached the store either.
      assert audit_count("bokbasen", "read") == 0
      assert html =~ "installation-admin authority"
    end

    test "a load for a plugin with NO row is refused IDENTICALLY — no found/not-found presence oracle",
         %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, w35_settings_url(ws_b, proj_b))

      absent =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "w35-load-no-such-plugin"})
        |> render_submit()

      # The not-found flash IS the presence signal — it must never appear, and
      # the disposition must be the same refusal the existing row produced.
      refute absent =~ "No settings yet for"
      assert absent =~ "installation-admin authority"
      assert absent =~ "Status: empty"
      assert audit_count("w35-load-no-such-plugin", "read") == 0
    end
  end
end
