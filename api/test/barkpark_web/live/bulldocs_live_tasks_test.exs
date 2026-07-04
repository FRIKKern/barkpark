defmodule BarkparkWeb.BulldocsLiveTasksTest do
  @moduledoc """
  End-to-end lock for LIVE PLANS: a paper whose `task-list` block carries a
  `query` (not a static snapshot) renders the real `bp` tasks in the Bulldocs
  reader — resolve-at-read — and re-renders when a task moves (the reader
  subscribes to its tenant's task mutations and re-resolves). The task twin of
  the sheet-embed View-mode lock.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp mk_task!(title, lifecycle, epic, scope) do
    doc_id = "lt-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => %{"kind" => "task", "lifecycle_status" => lifecycle, "parent_id" => epic}},
        @dataset,
        scope
      )

    doc
  end

  test "a task-list query renders live tasks, and a mutation updates the plan", %{conn: conn, scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"
    _done = mk_task!("collect targets", "done", epic, scope)
    open = mk_task!("inject snapshot", "open", epic, scope)

    slug = "live-plan-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: slug,
        blocks: [%{"id" => "t1", "type" => "task-list", "query" => %{"parent_id" => epic, "dataset" => @dataset}}]
      })

    {:ok, view, html} = live(conn, "/papers/#{slug}")

    # resolve-at-read: the real tasks are in the rendered plan, with the right
    # white-ladder glyphs (done = teal ✓, open-no-blocker = ready ○ white).
    assert html =~ "collect targets"
    assert html =~ "inject snapshot"
    assert html =~ "bp-g--done"
    assert html =~ "bp-g--ready"

    # Move the work: close the open task.
    {:ok, _} =
      Content.upsert_document(
        "task",
        %{"doc_id" => open.doc_id, "content" => %{"kind" => "task", "lifecycle_status" => "done", "parent_id" => epic}},
        @dataset,
        scope
      )

    # The reader heard the task mutation on its tenant stream and re-resolved —
    # the same live view now shows both tasks done, no ready ROW left (the
    # momentum legend keeps a static "ready" label, so assert on the row class).
    updated = render(view)
    assert updated =~ "inject snapshot"
    refute updated =~ "bp-trow--ready"
    assert updated =~ ~r/bp-trow--done.*bp-trow--done/s
    assert updated =~ "<b>2</b> done"
  end

  test "an author-pinned snapshot (no query) still renders offline", %{conn: conn} do
    slug = "static-plan-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: slug,
        blocks: [%{"id" => "t1", "type" => "task-list", "snapshot" => [%{"title" => "hand-written", "status" => "ready"}]}]
      })

    {:ok, _view, html} = live(conn, "/papers/#{slug}")
    assert html =~ "hand-written"
  end
end
