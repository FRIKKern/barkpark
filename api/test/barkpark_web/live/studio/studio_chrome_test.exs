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

  defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/studio/#{@dataset}/media"

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

      assert_redirect(view, "/w/#{ws_b.slug}/p/chrome-pb/studio/#{@dataset}")
    end

    test "switch-dataset on MediaLive navigates within the scope", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, staging} = Tenancy.create_dataset(proj_a, %{slug: "staging", name: "staging"})

      {:ok, view, _html} = live(conn, media_url(ws_a, proj_a))

      render_change(view, "switch-dataset", %{"dataset" => staging.slug})

      assert_redirect(view, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/staging")
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

      assert_redirect(view, "/w/#{ws_b.slug}/p/#{proj_b.slug}/studio/#{@dataset}")
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
      {:ok, view, _html} = live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}")

      html = render_click(view, "scope-menu-toggle", %{})
      assert html =~ ~s{aria-label="Switch workspace, project and dataset"}

      render_click(view, "scope-open", %{
        "ws" => ws_b.slug,
        "proj" => proj_b.slug,
        "ds" => @dataset
      })

      assert_redirect(view, "/w/#{ws_b.slug}/p/#{proj_b.slug}/studio/#{@dataset}")
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
      assert html =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/api-tester"
    end

    test "ApiTesterLive renders the scope title + tabs too", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/api-tester")

      assert html =~ ~s{phx-click="scope-menu-toggle"}
      assert html =~ "studio-bar-tabs"
    end
  end
end
