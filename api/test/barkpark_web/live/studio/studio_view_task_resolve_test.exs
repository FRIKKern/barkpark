defmodule BarkparkWeb.Studio.StudioViewTaskResolveTest do
  @moduledoc """
  pdd-t11 debt fix (2): the Studio read-only VIEW-mode stream resolves a paper's
  live `task-list`/`task-board`/`roadmap` query blocks the SAME way the /papers
  reader does (Content.Papers.resolve_tasks_in_blocks — the one producer, rule 3).
  Before this fix `paper_stream_items/3` never task-resolved, so an embedded plan
  rendered as an empty query block in Studio while the public reader showed real
  `bp` rows.

  Also locks D5: the SOURCE blocks handed in are left UNresolved (still carry
  `query`, never a frozen `snapshot`) — the render stream is display-only and is
  never the save baseline.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

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
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "svt-#{System.unique_integer([:positive])}",
          "title" => title,
          "content" => %{"kind" => "task", "lifecycle_status" => lifecycle, "parent_id" => epic}
        },
        @dataset,
        scope
      )

    doc
  end

  test "view-mode stream resolves a task-list query into live rows (reader parity)", %{
    scope: scope
  } do
    epic = "epic-#{System.unique_integer([:positive])}"
    _done = mk_task!("collect targets", "done", epic, scope)
    _open = mk_task!("inject snapshot", "open", epic, scope)

    blocks = [
      %{
        "id" => "t1",
        "type" => "task-list",
        "query" => %{"parent_id" => epic, "dataset" => @dataset}
      }
    ]

    [%{id: "t1", html: html}] = Paper.paper_stream_items(blocks, @dataset, scope)

    # the real tasks are painted, with the same white-ladder glyph classes the
    # /papers reader emits (done = teal ✓, open-no-blocker = ready ○ white).
    assert html =~ "collect targets"
    assert html =~ "inject snapshot"
    assert html =~ "bp-g--done"
    assert html =~ "bp-g--ready"

    # D5: the SOURCE block handed in is never mutated — it still carries the raw
    # `query` (the save baseline stays unresolved; no frozen snapshot).
    assert [%{"query" => _, "type" => "task-list"} = only] = blocks
    refute Map.has_key?(only, "snapshot")
  end

  test "an author-pinned snapshot (no query) renders untouched, plugin-off safe", %{scope: scope} do
    blocks = [
      %{
        "id" => "t1",
        "type" => "task-list",
        "snapshot" => [%{"title" => "hand-written", "status" => "ready"}]
      }
    ]

    [%{id: "t1", html: html}] = Paper.paper_stream_items(blocks, @dataset, scope)
    assert html =~ "hand-written"
  end
end
