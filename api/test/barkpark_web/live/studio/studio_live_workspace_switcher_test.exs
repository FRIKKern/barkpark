defmodule BarkparkWeb.Studio.StudioLiveWorkspaceSwitcherTest do
  @moduledoc """
  Task barkpark-k86v: the Studio LiveView workspace/project switcher.

  Covers:
    * the switcher renders both selects (Workspace + Project) in the topbar,
      defaulting to the seeded Default workspace/project;
    * `switch-workspace` re-assigns `:current_workspace` (and re-defaults the
      project to the picked workspace's first project) on the socket;
    * `switch-project` re-assigns `:current_project` within the current
      workspace.

  The Studio route shape stays `/studio/:dataset` — switching is a LiveView
  event over socket scope, NOT a URL navigation. Full live-browser round-trip
  is the orchestrator's integration gate; this is LiveViewTest + compile.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    # The migration backfill seeds the Default workspace/project into the test
    # DB (outside the sandbox), so it is present here. Add a SECOND workspace +
    # project so switching has somewhere to go.
    default_ws = Tenancy.get_default_workspace()
    default_project = Tenancy.get_default_project()

    {:ok, acme_ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
    {:ok, acme_blog} = Tenancy.create_project(acme_ws, %{slug: "blog", name: "Blog"})

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

    {:ok,
     conn: conn,
     default_ws: default_ws,
     default_project: default_project,
     acme_ws: acme_ws,
     acme_blog: acme_blog}
  end

  describe "switcher render" do
    test "renders the Workspace + Project selects defaulting to Default scope", %{
      conn: conn,
      default_ws: default_ws,
      default_project: default_project
    } do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}")

      # Both selects present, wired to the switch events.
      assert html =~ ~s(phx-change="switch-workspace")
      assert html =~ ~s(phx-change="switch-project")

      # Defaults to the seeded Default scope.
      assert view |> element(~s(select[name="workspace"])) |> render() =~ default_ws.name
      assert view |> element(~s(select[name="project"])) |> render() =~ default_project.name

      # Other workspace's option is offered too.
      assert html =~ "Acme"
    end
  end

  describe "switching scope" do
    test "switch-workspace re-assigns current_workspace + re-defaults project", %{
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

    test "switch-project re-assigns current_project within the workspace", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, second_project} =
        Tenancy.create_project(default_ws, %{slug: "secondary", name: "Secondary"})

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="project"])), %{
        "project" => second_project.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == default_ws.slug
      assert assigns.current_project.slug == second_project.slug
    end

    test "unknown workspace slug is a no-op (scope unchanged)", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => "does-not-exist"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == default_ws.slug
    end
  end
end
