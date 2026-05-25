defmodule BarkparkWeb.Studio.StudioLiveWorkspaceSwitcherTest do
  @moduledoc """
  Task barkpark-k86v: the Studio LiveView workspace/project switcher.
  Task barkpark-g4a7: the switcher is now MEMBERSHIP-AWARE — it lists only the
  mounted principal's member workspaces (never the unscoped `list_workspaces/0`),
  and `switch-workspace` / `switch-project` reject a switch to a workspace the
  principal isn't a member of.

  Covers:
    * the switcher renders both selects (Workspace + Project) in the topbar,
      defaulting to the principal's first member workspace;
    * the workspace `<select>` lists ONLY member workspaces — a foreign
      workspace the principal has no membership in never appears;
    * `switch-workspace` to a MEMBER workspace re-assigns `:current_workspace`
      (and re-defaults the project); a switch to a NON-MEMBER workspace is
      rejected (scope unchanged);
    * `switch-project` re-assigns `:current_project` within the current
      workspace.

  The Studio route shape stays `/studio/:dataset` — switching is a LiveView
  event over socket scope, NOT a URL navigation. Full live-browser round-trip
  is the orchestrator's integration gate; this is LiveViewTest + compile.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    # The migration backfill seeds the Default workspace/project into the test
    # DB (outside the sandbox), so it is present here. Add a SECOND workspace +
    # project (a MEMBER workspace) so switching has somewhere to go, and a THIRD
    # (a FOREIGN workspace) the principal is NOT a member of.
    default_ws = Tenancy.get_default_workspace()
    default_project = Tenancy.get_default_project()

    {:ok, acme_ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
    {:ok, acme_blog} = Tenancy.create_project(acme_ws, %{slug: "blog", name: "Blog"})

    {:ok, foreign_ws} = Tenancy.create_workspace(%{slug: "foreign", name: "Foreign Co"})
    {:ok, _foreign_proj} = Tenancy.create_project(foreign_ws, %{slug: "secret", name: "Secret"})

    # Mint a principal that is a member of Default + Acme but NOT Foreign Co.
    raw = "switcher-test-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "switcher", @dataset, ["read", "write"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(acme_ws.id, token.id, "member")

    # A schema so the desk has something to render after a scope switch.
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     default_ws: default_ws,
     default_project: default_project,
     acme_ws: acme_ws,
     acme_blog: acme_blog,
     foreign_ws: foreign_ws}
  end

  describe "switcher render" do
    test "renders the Workspace + Project selects defaulting to a member workspace", %{
      conn: conn,
      default_ws: default_ws,
      acme_ws: acme_ws,
      acme_blog: acme_blog
    } do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}")

      # Both selects present, wired to the switch events.
      assert html =~ ~s(phx-change="switch-workspace")
      assert html =~ ~s(phx-change="switch-project")

      # The initial scope is the principal's slug-FIRST member workspace
      # (`list_workspaces_for/1` is slug-ordered, "acme" < "default"), with
      # its first project — not the seeded Default. Both member workspaces
      # are offered in the workspace select.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      assert assigns.current_project.slug == acme_blog.slug

      ws_select = view |> element(~s(select[name="workspace"])) |> render()
      assert ws_select =~ acme_ws.name
      assert ws_select =~ default_ws.name
    end

    test "the workspace select lists ONLY member workspaces — no foreign tenant", %{
      conn: conn,
      foreign_ws: foreign_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      ws_select = view |> element(~s(select[name="workspace"])) |> render()

      # Member workspaces present.
      assert ws_select =~ "Acme"
      # The foreign workspace (no membership row) MUST NOT appear/be selectable.
      refute ws_select =~ foreign_ws.name,
             "TENANT LEAK: a non-member workspace appeared in the switcher — " <>
               "the switcher must use list_workspaces_for/1, not list_workspaces/0"
    end
  end

  describe "switching scope" do
    test "switch-workspace to a MEMBER workspace re-assigns scope + re-defaults project", %{
      conn: conn,
      acme_ws: acme_ws,
      acme_blog: acme_blog
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => acme_ws.slug})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      # Project re-defaulted to the new workspace's first project.
      assert assigns.current_project.slug == acme_blog.slug

      # The Project select now shows the new workspace's project.
      assert view |> element(~s(select[name="project"])) |> render() =~ acme_blog.name
    end

    test "switch-workspace to a NON-MEMBER workspace is REJECTED (scope unchanged)", %{
      conn: conn,
      foreign_ws: foreign_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      before = :sys.get_state(view.pid).socket.assigns.current_workspace.slug

      # Forge a switch to the foreign workspace's slug (the option isn't even
      # rendered, but a crafted phx-change must still be refused server-side).
      render_change(element(view, ~s(select[name="workspace"])), %{
        "workspace" => foreign_ws.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == before,
             "MEMBERSHIP GATE BREACH: switch-workspace re-scoped to a non-member workspace"
      refute assigns.current_workspace.slug == foreign_ws.slug
    end

    test "switch-project re-assigns current_project within a member workspace", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, second_project} =
        Tenancy.create_project(default_ws, %{slug: "secondary", name: "Secondary"})

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Switch into Default (a member workspace), then change project within it.
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => default_ws.slug})

      render_change(element(view, ~s(select[name="project"])), %{
        "project" => second_project.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == default_ws.slug
      assert assigns.current_project.slug == second_project.slug
    end

    test "unknown workspace slug is a no-op (scope unchanged)", %{
      conn: conn,
      acme_ws: acme_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => "does-not-exist"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
    end
  end
end
