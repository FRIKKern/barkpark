defmodule BarkparkWeb.Studio.StudioLiveDeskScopeLeakTest do
  @moduledoc """
  Tenancy-leak guard for the Studio desk (B8 / barkpark-qucz).

  Before the fix, the s5 workspace/project switcher re-assigned the socket
  scope (`current_workspace` / `current_project`) but `rebuild_panes/1` and
  `PaneBuilder.build/3` DROPPED that scope — so the desk listed EVERY
  workspace's documents regardless of the active selection, and Studio writes
  mis-stamped. The switcher was cosmetic.

  The fix threads `BarkparkWeb.ScopeHelpers.scope_opts(socket)` through
  `rebuild_panes` → `PaneBuilder.build(.., scope: …)` → every `Content`
  read, and through `hook_opts/1` for the write path.

  This test stands up TWO workspaces, switches the Studio socket to workspace
  A, navigates to the `post` desk, and asserts the desk pane lists A's
  document but NEVER B's. LiveViewTest + compile only — full live-browser
  verification of the desk is the orchestrator's gate (see what-to-click in
  the subagent return).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "wsa", name: "Workspace A"})
    {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "pa", name: "Project A"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "wsb", name: "Workspace B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "pb", name: "Project B"})

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

    # One doc per workspace, SAME dataset — isolation must come from
    # workspace_id, not the dataset leaf. Distinct titles so the rendered
    # desk pane is unambiguous about which row leaked.
    {:ok, _doc_a} =
      Content.create_document(
        "post",
        %{"_id" => "post-a", "title" => "ALPHA-ONLY-DOC"},
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _doc_b} =
      Content.create_document(
        "post",
        %{"_id" => "post-b", "title" => "BRAVO-ONLY-DOC"},
        @dataset,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    {:ok,
     conn: conn,
     default_ws: default_ws,
     ws_a: ws_a,
     proj_a: proj_a,
     ws_b: ws_b,
     proj_b: proj_b}
  end

  test "desk scoped to workspace A lists A's doc and NOT workspace B's", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

    # Switch the socket scope to workspace A (mirrors the s5 switcher click).
    render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => ws_a.slug})

    # Drill into the `post` desk so a :document_type_list pane is built.
    {:ok, view, html} = live(conn, "/studio/#{@dataset}/post")
    # The fresh mount defaults to Default scope; re-switch then re-navigate so
    # the desk rebuild runs under workspace A's scope.
    render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => ws_a.slug})

    # Inspect the rebuilt pane assigns directly — the authoritative check.
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.current_workspace.slug == ws_a.slug
    assert assigns.current_project.slug == proj_a.slug

    desk_titles =
      assigns.panes
      |> Enum.flat_map(fn pane -> Map.get(pane, :items, []) end)
      |> Enum.filter(&(Map.get(&1, :type) == :doc))
      |> Enum.map(& &1.title)

    assert "ALPHA-ONLY-DOC" in desk_titles,
           "expected workspace A's doc in the desk, got #{inspect(desk_titles)}"

    refute "BRAVO-ONLY-DOC" in desk_titles,
           "DESK TENANCY LEAK: workspace B's doc appeared in workspace A's desk — " <>
             "scope was dropped in rebuild_panes/PaneBuilder.build (got #{inspect(desk_titles)})"

    # And the same guard at the rendered-HTML layer (what the browser shows).
    refute html =~ "BRAVO-ONLY-DOC"
  end

  test "hook_opts threads the active socket scope into the write path", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}")
    render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => ws_a.slug})

    socket = :sys.get_state(view.pid).socket
    opts = BarkparkWeb.ScopeHelpers.scope_opts(socket)

    assert Keyword.get(opts, :workspace_id) == ws_a.id
    assert Keyword.get(opts, :project_id) == proj_a.id
  end
end
