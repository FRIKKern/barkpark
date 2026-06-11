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

  P3 (Scoped-by-URL cutover): the only Studio mount is the scoped
  live_session, so mounts use `scoped_studio/1` (Default scope) or the
  explicit `/w/<ws>/p/<proj>` form. A workspace switch is now a push_patch
  to the NEW scope's canonical URL — tests follow the navigation
  (`assert_patch` + fresh mount of the patched scope) instead of asserting
  in-place assign flips.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "wsa", name: "Workspace A"})
    {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "pa", name: "Project A"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "wsb", name: "Workspace B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "pb", name: "Project B"})

    # The switcher + switch-workspace are now membership-gated (barkpark-g4a7).
    # Mint a principal that is a member of workspace A (and Default, via the
    # token's home workspace) so the scope switch to A is honoured. The
    # principal is deliberately NOT a member of workspace B — its doc must
    # still never leak into A's scoped desk.
    raw = "desk-leak-test-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "desk-leak", @dataset, ["read", "write"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(ws_a.id, token.id, "member")
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

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
     conn: conn, default_ws: default_ws, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  test "desk scoped to workspace A lists A's doc and NOT workspace B's", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}"))

    # Switch the socket scope to workspace A (mirrors a scope-menu pick;
    # fired directly — the bar's select form is gone, the handler isn't).
    # P3: the switch is a push_patch to the NEW scope's canonical URL.
    render_change(view, "switch-workspace", %{"workspace" => ws_a.slug})

    patched = assert_patch(view)
    assert patched =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/"

    # Follow the navigation: the switch lands on A's scope ROOT
    # (reset_nav_for_switch), so drill into the `post` desk by mounting the
    # new scope's desk URL — that builds the :document_type_list pane under
    # workspace A's URL-resolved scope.
    {:ok, view, html} =
      live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/post")

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
    {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}"))

    render_change(view, "switch-workspace", %{"workspace" => ws_a.slug})

    # P3: the switch navigates — follow the patch so handle_params +
    # LiveScope have re-resolved the scope from the new URL before we
    # inspect the socket.
    assert assert_patch(view) =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/"

    socket = :sys.get_state(view.pid).socket
    opts = BarkparkWeb.ScopeHelpers.scope_opts(socket)

    assert Keyword.get(opts, :workspace_id) == ws_a.id
    assert Keyword.get(opts, :project_id) == proj_a.id
  end

  # Task barkpark-f9s9: the secondary picker reads (image / reference /
  # secondary-doc / revision / secondary-fetch) drop scope into the
  # fail-closed nil-scope path unless they thread the socket scope. This
  # asserts the reference picker is workspace-scoped: under workspace A's
  # scope it offers A's `post` doc but NEVER B's.
  test "the secondary-doc picker is workspace-scoped (no foreign workspace doc)", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    # P3: workspace A's scope comes from the URL, not an in-socket switch —
    # mount the editor for A's doc directly on A's scoped surface so
    # `editor_type` is set, then open the picker.
    {:ok, view, _html} =
      live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/post/post-a")

    render_click(view, "open-secondary-picker", %{})

    candidate_titles =
      :sys.get_state(view.pid).socket.assigns.secondary_candidates
      |> Enum.map(& &1.title)

    refute "BRAVO-ONLY-DOC" in candidate_titles,
           "PICKER TENANCY LEAK: workspace B's doc appeared in workspace A's " <>
             "secondary picker — the read dropped scope (got #{inspect(candidate_titles)})"
  end
end
