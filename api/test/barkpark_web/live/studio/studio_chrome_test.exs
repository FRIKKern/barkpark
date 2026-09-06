defmodule BarkparkWeb.StudioChromeTest do
  @moduledoc """
  The shared top-bar contract (BarkparkWeb.StudioChrome): every surface in
  the Studio layout renders the same chrome, and the scope controls are
  SAFE everywhere — on non-StudioLive surfaces a switch is a navigation to
  the target scope's canonical URL (it used to crash MediaLive/
  ApiTesterLive: LiveScope assigned current_workspace so the switcher
  RENDERED, but only StudioLive defined the switch-* handlers).

  Also covers the Sanity-style scope MENU: the title button opens one
  popover where workspace, project and dataset are picked together;
  `scope-open` (a dataset pick) navigates to the triple's canonical URL,
  membership-gated server-side.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("chrome-a")
    {:ok, proj_a} = Tenancy.create_project_with_dataset(ws_a, %{name: "chrome-pa"})
    ws_b = create_workspace!("chrome-b")
    {:ok, proj_b} = Tenancy.create_project_with_dataset(ws_b, %{name: "chrome-pb"})

    raw = "chrome-test-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "chrome-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "member")
    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "member")

    member_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    %{member_conn: member_conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media"

  describe "legacy switch events stay safe on non-StudioLive surfaces (the crash kill)" do
    test "switch-workspace on MediaLive NAVIGATES to the target scope", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      # Pre-chrome this was a FunctionClauseError crash: MediaLive has no
      # switch-* handlers. The select form is gone from the markup, but the
      # event contract remains chrome-handled on every non-StudioLive view.
      render_change(view, "switch-workspace", %{"workspace" => ws_b.slug})

      assert_redirect(view, "/w/#{ws_b.slug}/p/chrome-pb/d/#{@dataset}/studio")
    end

    test "switch-dataset on MediaLive navigates within the scope", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, staging} = Tenancy.create_dataset(proj_a, %{slug: "staging", name: "staging"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_change(view, "switch-dataset", %{"dataset" => staging.slug})

      assert_redirect(view, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/staging/studio")
    end

    test "a forged switch into a non-membership workspace is ignored", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      foreign = create_workspace!("chrome-foreign")
      {:ok, _} = Tenancy.create_project_with_dataset(foreign, %{name: "chrome-pf"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      html = render_change(view, "switch-workspace", %{"workspace" => foreign.slug})

      # No navigation, no crash — the chrome guard mirrors StudioLive's.
      assert html =~ "media-explorer-host"
    end
  end

  describe "the scope menu (Sanity-style single popover)" do
    test "toggle opens the menu with all three columns, membership workspaces only", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      foreign = create_workspace!("chrome-menu-foreign")
      {:ok, _} = Tenancy.create_project_with_dataset(foreign, %{name: "chrome-pmf"})

      {:ok, view, html} = live(conn, media_url(ws_a, proj_a))

      # Closed by default: the title button renders, the popover doesn't.
      assert html =~ ~s{phx-click="scope-menu-toggle"}
      refute html =~ ~s{aria-label="Switch workspace, project and dataset"}

      html = render_click(view, "scope-menu-toggle", %{})

      assert html =~ ~s{aria-label="Switch workspace, project and dataset"}
      assert html =~ ws_a.name
      assert html =~ ws_b.name
      # The hard tenant boundary holds in the menu too.
      refute html =~ foreign.name

      # Pre-focused on the current path: project + dataset columns filled.
      assert html =~ proj_a.name
      assert html =~ ~s{phx-value-ds="#{@dataset}"}
    end

    test "previewing another workspace reloads the project/dataset columns without navigating",
         %{member_conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b} do
      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_click(view, "scope-menu-toggle", %{})
      html = render_click(view, "scope-menu-ws", %{"id" => ws_b.id})

      # Still on MediaLive (a preview is not a navigation)…
      assert html =~ "media-explorer-host"
      # …but the child columns now show ws_b's project, and the dataset
      # buttons carry the previewed triple.
      assert html =~ proj_b.name
      assert html =~ ~s{phx-value-ws="#{ws_b.slug}"}
      assert html =~ ~s{phx-value-proj="#{proj_b.slug}"}
    end

    test "scope-open navigates to the picked triple's canonical URL", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_click(view, "scope-menu-toggle", %{})

      render_click(view, "scope-open", %{
        "ws" => ws_b.slug,
        "proj" => proj_b.slug,
        "ds" => @dataset
      })

      assert_redirect(view, "/w/#{ws_b.slug}/p/#{proj_b.slug}/d/#{@dataset}/studio")
    end

    test "a forged scope-open into a non-membership workspace is refused", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      foreign = create_workspace!("chrome-open-foreign")
      {:ok, foreign_proj} = Tenancy.create_project_with_dataset(foreign, %{name: "chrome-pof"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_click(view, "scope-menu-toggle", %{})

      html =
        render_click(view, "scope-open", %{
          "ws" => foreign.slug,
          "proj" => foreign_proj.slug,
          "ds" => @dataset
        })

      # No navigation — and the refusal also closes the menu.
      assert html =~ "media-explorer-host"
      refute html =~ ~s{aria-label="Switch workspace, project and dataset"}
    end

    test "a mismatched project/dataset pairing is refused", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      # proj_a belongs to ws_a — claiming it under ws_b must fail the
      # containment re-resolution even though both are membership scopes.
      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_click(view, "scope-menu-toggle", %{})

      html =
        render_click(view, "scope-open", %{
          "ws" => ws_b.slug,
          "proj" => proj_a.slug,
          "ds" => @dataset
        })

      assert html =~ "media-explorer-host"
    end

    test "the menu works on StudioLive too (chrome hook attaches everywhere)", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, view, _html} = live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio")

      html = render_click(view, "scope-menu-toggle", %{})
      assert html =~ ~s{aria-label="Switch workspace, project and dataset"}

      render_click(view, "scope-open", %{
        "ws" => ws_b.slug,
        "proj" => proj_b.slug,
        "ds" => @dataset
      })

      assert_redirect(view, "/w/#{ws_b.slug}/p/#{proj_b.slug}/d/#{@dataset}/studio")
    end
  end

  describe "consistent chrome across surfaces" do
    test "MediaLive renders the scope title + tabs", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      assert html =~ ~s{phx-click="scope-menu-toggle"}
      assert html =~ "studio-bar-tabs"
      assert html =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/api-tester"
    end

    test "ApiTesterLive renders the scope title + tabs too", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/api-tester")

      assert html =~ ~s{phx-click="scope-menu-toggle"}
      assert html =~ "studio-bar-tabs"
    end
  end

  describe "icons-only top bar (sup-w1)" do
    test "each host tab renders an SVG glyph named by aria-label, with no visible text node",
         %{member_conn: conn, ws_a: ws_a, proj_a: proj_a} do
      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      # The label is the accessible name AND the native tooltip — never a
      # visible text child of the tab.
      for label <- ["Structure", "Media", "API"] do
        assert html =~ ~s{title="#{label}" aria-label="#{label}"}
      end

      # The tab's visible content is the inline SVG glyph, wrapped in the
      # aria-hidden icon span (the label lives only in the a11y attributes).
      assert html =~
               ~s{aria-label="Structure" data-test-id="top-menu-tab"><span class="studio-tab-icon" aria-hidden="true"><svg}

      # The pre-icon markup rendered the label as a bare text node
      # (…top-menu-tab">Structure</a>). Prove that text node is GONE.
      refute html =~ ~s{data-test-id="top-menu-tab">Structure</a>}
      refute html =~ ~s{data-test-id="top-menu-tab">Media</a>}
      refute html =~ ~s{data-test-id="top-menu-tab">API</a>}

      # Every rendered tab carries a glyph: at least one <svg per host tab.
      assert length(Regex.scan(~r/class="studio-tab-icon"/, html)) >= 3
    end

    test "the compact scope chip still fires scope-menu-toggle", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, view, html} = live(conn, media_url(ws_a, proj_a))

      # The trigger is the compact chip button (unchanged event contract).
      assert html =~ ~s{class="scope-title bar-focusable"}
      assert html =~ ~s{phx-click="scope-menu-toggle"}

      # Clicking it still opens the Miller-columns popover.
      html = render_click(view, "scope-menu-toggle", %{})
      assert html =~ ~s{aria-label="Switch workspace, project and dataset"}
    end
  end

  describe "current_path is derived by the shared hook, not hand-set per LiveView" do
    # The disease this hook cures: only 4 of ~13 Studio LiveViews used to
    # hand-set current_path, so ApiTester/Settings/Styleguide/OrgAdmin/
    # plugin-admin rendered with NO active tab. StudioChrome's
    # :handle_params hook now derives it for every studio-layout surface.

    test "ApiTesterLive mount derives current_path and lights the API tab", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      path = "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/api-tester"
      {:ok, view, html} = live(conn, path)

      # The hook (not the LiveView — ApiTesterLive never sets it) derived
      # current_path from the request URI.
      assert :sys.get_state(view.pid).socket.assigns.current_path == path

      # …and that lit the API tab: active-state is now DERIVED everywhere.
      assert html =~ ~s{href="#{path}" class="studio-tab active" aria-current="page"}
      # Exactly one tab is active across the whole bar.
      assert length(Regex.scan(~r/class="studio-tab active"/, html)) == 1
    end

    test "trailing slash is normalized away (deterministic active_when boundary)", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      base = "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio"
      {:ok, view, _html} = live(conn, base <> "/api-tester/")

      # No trailing slash on the derived path; bare root stays "/".
      assert :sys.get_state(view.pid).socket.assigns.current_path == base <> "/api-tester"
    end

    test "push_patch within StudioLive refreshes current_path (hook fires on every patch)", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      root = "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio"
      {:ok, view, _html} = live(conn, root)

      # Mount value from the hook.
      assert :sys.get_state(view.pid).socket.assigns.current_path == root

      # A live patch to a deeper Structure path re-runs handle_params, so the
      # hook re-derives current_path — it is not frozen at the mount value.
      render_patch(view, root <> "/post")
      assert :sys.get_state(view.pid).socket.assigns.current_path == root <> "/post"
    end
  end

  # ── arpss-w10: admin chrome is scoped to the MOUNTED workspace ─────────────
  #
  # `shares_admin?` used to be `token_admin? or account_admin?`, and the account
  # arm authorized against `Tenancy.get_default_workspace()` — never the
  # workspace `hydrate_scope/1` had just resolved. It now delegates to
  # `BarkparkWeb.Studio.Caps.admin?/1`, the SAME seat-authority oracle the
  # StudioLive deny-gate enforces with: `role_permits?(membership_role, ws_id,
  # :admin)` on the mounted workspace.
  #
  # MediaLive is the surface under test on purpose: StudioLive's own
  # `mount.ex` (`shares_admin?: Caps.admin?(socket)` in the mount assigns)
  # overwrites `shares_admin?` from `Caps.admin?/1` after every
  # on_mount, so the chrome value is only OBSERVABLE on the other chrome
  # surfaces (Media / ApiTester / Settings / tmux / chat / plugin admin).
  #
  # BOTH proofs red on the pre-fix predicate, in opposite directions.
  describe "shares_admin? is decided on the MOUNTED workspace, not the Default one" do
    setup do
      {default_ws, _default_proj} = ensure_default_scope!()
      %{default_ws: default_ws}
    end

    defp user_conn_for(memberships) do
      email = "chrome-scope-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Barkpark.Accounts.register_user(%{email: email, password: "correct-horse-battery"})

      for {ws, role} <- memberships do
        {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
      end

      {:ok, raw} = Barkpark.Accounts.create_user_session_token(user)
      Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{"user_session" => raw})
    end

    test "FALSE-SHOW: an admin of Default who is a plain member of the mounted workspace gets NO admin chrome",
         %{default_ws: default_ws, ws_a: ws_a, proj_a: proj_a} do
      conn = user_conn_for([{default_ws, "admin"}, {ws_a, "member"}])

      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      # Pre-fix this rendered: account_admin? said :ok against DEFAULT, so the
      # Share button (and the admin tabs) appeared on a workspace where the
      # scoped-admin gate would then refuse them.
      refute html =~ ~s{phx-click="shares-open"}
    end

    test "FALSE-HIDE: an admin of the MOUNTED workspace holding no Default role DOES get admin chrome",
         %{ws_a: ws_a, proj_a: proj_a} do
      conn = user_conn_for([{ws_a, "admin"}])

      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      # Pre-fix this was ABSENT — the operationally worse direction: an admin or
      # OWNER of A with no Default membership saw no admin chrome anywhere,
      # including on the workspace they administer.
      assert html =~ ~s{phx-click="shares-open"}
    end

    test "an OWNER of the mounted workspace is admin chrome too (the seat rule reads the role, not a name allowlist of one)",
         %{ws_a: ws_a, proj_a: proj_a} do
      conn = user_conn_for([{ws_a, "owner"}])

      {:ok, _view, html} = live(conn, media_url(ws_a, proj_a))

      assert html =~ ~s{phx-click="shares-open"}
    end

    test "instance_admin? keeps the HOST-level oracle: a Default admin browsing a foreign workspace still holds it",
         %{default_ws: default_ws, ws_a: ws_a, proj_a: proj_a} do
      conn = user_conn_for([{default_ws, "admin"}, {ws_a, "member"}])

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      # The split is the point: the workspace-scoped flag is OFF here (the test
      # above), while the self-update banner's host-level flag stays ON. Merging
      # these two back into one assign re-creates one of the two defects.
      assert :sys.get_state(view.pid).socket.assigns.instance_admin? == true
      assert :sys.get_state(view.pid).socket.assigns.shares_admin? == false
    end
  end
end
