defmodule BarkparkWeb.Studio.StudioLiveStaleNavPathTest do
  @moduledoc """
  Tasks barkpark-nce1 / barkpark-5svq / barkpark-zok1: a workspace/project
  switch must NOT leave the old project's `nav_path` (and the `editor_doc` it
  resolved) on the socket.

  The bug:
    * `rescope_dataset_for_project/2` carries the OLD project's `nav_path`
      across the switch. When the new project's default dataset slug equals the
      current one (every project ships a "production" dataset, so this is the
      common case), `rescope` takes the `slug == dataset` branch and calls
      `rebuild_panes` with the UNCHANGED `nav_path`. `PaneBuilder.walk_path`
      then resolves the old project's doc ids against the NEW project's
      structure — the editor pane shows a stale/empty doc.
    * A subsequent autosave/save runs `do_autosave` over that stale
      `editor_doc`, so `upsert_draft` writes the OLD doc_id under the NEW
      project's scope — a wrong-scope write that can `get_or_create` a duplicate
      dataset row under the wrong project.

  The fix resets `nav_path` to the root AND clears the open-doc/autosave state
  (`editor_doc` et al.) on every switch, before rebuilding. These tests prove:
    1. after switching project while STAYING on dataset "production" (the bug
       branch), the editor does NOT show the old project's doc — nav_path reset,
       editor_doc nil. (Asserting the OLD doc is gone is what fails pre-fix.)
    2. a save right after the switch lands in the NEW project's scope (never the
       old project, never a duplicate row under the wrong project).

  Single member workspace (Default), so the switcher collapses the Workspace
  control to a static label and only the Project `<select>` renders — the switch
  is driven through it. Navigation into a doc uses `render_patch` so the socket
  scope (current_project) is preserved across the patch (a fresh `live/2` would
  remount to the default project). LiveViewTest + compile; the live-browser
  round-trip is the orchestrator's integration gate.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    # The Default workspace/project is backfilled into the test DB. Give Default
    # TWO extra projects, each with its OWN "production" dataset — switching
    # between them stays on the "production" slug (the bug branch in
    # rescope_dataset_for_project) so we exercise it directly.
    default_ws = Tenancy.get_default_workspace()

    {:ok, project_a} = Tenancy.create_project(default_ws, %{slug: "proj-a", name: "Project A"})
    {:ok, ds_a} = Tenancy.create_dataset(project_a, %{slug: "production", name: "Prod A"})

    {:ok, project_b} = Tenancy.create_project(default_ws, %{slug: "proj-b", name: "Project B"})
    {:ok, ds_b} = Tenancy.create_dataset(project_b, %{slug: "production", name: "Prod B"})

    raw = "stale-navpath-test-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "stale", @dataset, ["read", "write"], default_ws.id)

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

    # A document that lives in PROJECT A only. We switch into A, open it in the
    # editor, then switch to B — the switch must drop it.
    {:ok, doc_a} =
      Content.create_document(
        "post",
        %{"doc_id" => "post-in-a", "title" => "Doc In A"},
        @dataset,
        source: :studio,
        workspace_id: default_ws.id,
        project_id: project_a.id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     token: token,
     default_ws: default_ws,
     project_a: project_a,
     project_b: project_b,
     ds_a: ds_a,
     ds_b: ds_b,
     doc_a: doc_a}
  end

  # Mount, switch into Project A, open doc_a in the editor (scope preserved via
  # render_patch). Returns the connected view with editor_doc populated under A.
  defp open_doc_under_a(conn, project_a) do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

    render_change(element(view, ~s(select[name="project"])), %{"project" => project_a.slug})

    # Navigate into the doc WITHOUT remounting — keeps current_project == A.
    render_patch(view, "/studio/#{@dataset}/post/post-in-a")

    view
  end

  describe "stale nav_path / editor_doc after a project switch (nce1)" do
    test "switching project while staying on 'production' resets nav_path + drops the old project's doc",
         %{conn: conn, project_a: project_a, project_b: project_b} do
      view = open_doc_under_a(conn, project_a)

      before = :sys.get_state(view.pid).socket.assigns
      assert before.current_project.slug == project_a.slug
      assert before.nav_path == ["post", "post-in-a"],
             "precondition: nav_path walks the open doc"

      assert before.editor_doc,
             "precondition: the doc must be open in the editor under Project A"

      assert before.editor_doc.doc_id =~ "post-in-a"

      # NOW switch to Project B. Its default dataset slug is also "production", so
      # rescope_dataset_for_project hits the `slug == dataset` branch — the bug
      # path that used to rebuild with the stale nav_path.
      render_change(element(view, ~s(select[name="project"])), %{"project" => project_b.slug})

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.current_project.slug == project_b.slug,
             "the switch must land on Project B"

      # THE FIX: nav_path reset to root so panes rebuild from the new project's
      # root rather than walking the old project's doc ids.
      assert assigns.nav_path == [],
             "STALE NAV: nav_path survived the switch — panes rebuilt from the old project's path"

      # THE FIX: the editor no longer shows Project A's doc. Pre-fix the stale
      # nav_path resolved editor_doc to the old doc; post-fix it is cleared.
      refute assigns.editor_doc,
             "STALE EDITOR: editor_doc survived the switch — the editor shows the old project's doc"
    end
  end

  describe "save after a switch lands in the NEW scope (5svq / zok1)" do
    test "an autosave right after the switch does not write the old doc into the wrong project",
         %{conn: conn, default_ws: default_ws, project_a: project_a, project_b: project_b} do
      view = open_doc_under_a(conn, project_a)

      assert :sys.get_state(view.pid).socket.assigns.editor_doc,
             "precondition: doc open under Project A"

      a_before = doc_count(default_ws.id, project_a.id)
      b_before = doc_count(default_ws.id, project_b.id)

      render_change(element(view, ~s(select[name="project"])), %{"project" => project_b.slug})

      # Fire a save with edited params. With the stale editor_doc the pre-fix code
      # would upsert_draft(doc_a, ...) under Project B's scope — writing the old
      # doc_id into the WRONG project and get_or_create a duplicate "production"
      # dataset under B. Post-fix editor_doc is nil so do_autosave no-ops.
      render_click(view, "save", %{"doc" => %{"title" => "Edited After Switch"}})

      a_after = doc_count(default_ws.id, project_a.id)
      b_after = doc_count(default_ws.id, project_b.id)

      assert a_after == a_before,
             "WRONG SCOPE: a post-switch save mutated/duplicated the OLD project's doc set"

      assert b_after == b_before,
             "WRONG SCOPE: a post-switch save wrote the old project's doc into Project B"

      refute Enum.any?(
               docs_in(default_ws.id, project_b.id),
               &(Content.published_id(&1.doc_id) == "post-in-a")
             ),
             "DUP DOC: the old project's doc_id was reused under the switched-to project"
    end

    test "a NEW doc created after the switch lands in Project B's scope, not Project A",
         %{conn: conn, default_ws: default_ws, project_a: project_a, project_b: project_b} do
      view = open_doc_under_a(conn, project_a)

      render_change(element(view, ~s(select[name="project"])), %{"project" => project_b.slug})

      a_before = doc_count(default_ws.id, project_a.id)
      b_before = doc_count(default_ws.id, project_b.id)

      # A fresh scoped write after the switch resolves its scope from the socket
      # (current_workspace/current_project) — it must land in Project B.
      render_click(view, "new-document", %{"type" => "post"})

      assert doc_count(default_ws.id, project_b.id) == b_before + 1,
             "a write after the switch must land in the switched-to project (B)"

      assert doc_count(default_ws.id, project_a.id) == a_before,
             "a write after the switch must NOT touch the old project (A)"
    end
  end

  defp doc_count(ws_id, project_id) do
    Barkpark.Repo.aggregate(
      from(d in Barkpark.Content.Document,
        where: d.workspace_id == ^ws_id and d.project_id == ^project_id
      ),
      :count
    )
  end

  defp docs_in(ws_id, project_id) do
    Barkpark.Repo.all(
      from(d in Barkpark.Content.Document,
        where: d.workspace_id == ^ws_id and d.project_id == ^project_id
      )
    )
  end
end
