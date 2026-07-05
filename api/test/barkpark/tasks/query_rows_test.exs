defmodule Barkpark.Tasks.QueryRowsTest do
  @moduledoc """
  DB-backed proof for `Barkpark.Tasks.Query.rows_for_query/2` — the live-plan
  fetcher. Seeds representative task docs (+ a real `:blocks` edge) and asserts
  it derives the component snapshot rows the PortableDoc emitters render:
  the open→ready / open-with-unmet-blocker→backlog / blocked / in_progress /
  done ladder, straight from the substrate. No phx.server — just the Repo
  sandbox, so this is honest verification, not a stub.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Query, as: TaskQuery

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp row_for(rows, title), do: Enum.find(rows, &(&1["title"] == title))

  test "derives the full status ladder from real substrate rows", %{scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"
    u = fn p -> "#{p}-#{System.unique_integer([:positive])}" end

    ready = mk_task!(u.("ready"), scope, %{"parent_id" => epic, "labels" => ["wave:5"]})
    _done = mk_task!(u.("done"), scope, %{"parent_id" => epic, "lifecycle_status" => "done"})

    _prog =
      mk_task!(u.("prog"), scope, %{
        "parent_id" => epic,
        "lifecycle_status" => "in_progress",
        "claim" => %{"worker" => "o3"}
      })

    _blkd =
      mk_task!(u.("blocked"), scope, %{"parent_id" => epic, "lifecycle_status" => "blocked"})

    backlog = mk_task!(u.("backlog"), scope, %{"parent_id" => epic})

    # A real blocker: `backlog` depends on an un-done task OUTSIDE the epic.
    blocker = mk_task!(u.("blocker"), scope, %{})
    {:ok, _} = Tasks.add_dep(backlog.id, blocker.id, :blocks)

    rows = TaskQuery.rows_for_query(%{"parent_id" => epic, "dataset" => @dataset}, scope)

    # Only the five epic children come back (the blocker is outside the epic).
    assert length(rows) == 5

    assert row_for(rows, ready.title)["status"] == "ready"
    assert Enum.find(rows, &(&1["status"] == "done"))
    assert Enum.find(rows, &(&1["status"] == "blocked"))

    prog = Enum.find(rows, &(&1["status"] == "in_progress"))
    assert prog["worker"] == "o3"

    backlog_row = row_for(rows, backlog.title)

    assert backlog_row["status"] == "open",
           "open task with an unmet blocker reads as backlog, not ready"

    # The wave:5 label became the phase group on the ready row.
    assert row_for(rows, ready.title)["phase"] == "5"
  end

  test "a resolved blocker flips backlog → ready", %{scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"

    dependent =
      mk_task!("dep-#{System.unique_integer([:positive])}", scope, %{"parent_id" => epic})

    blocker =
      mk_task!("blk-#{System.unique_integer([:positive])}", scope, %{"lifecycle_status" => "done"})

    {:ok, _} = Tasks.add_dep(dependent.id, blocker.id, :blocks)

    [row] = TaskQuery.rows_for_query(%{"parent_id" => epic, "dataset" => @dataset}, scope)
    assert row["status"] == "ready", "the only blocker is done → the task is ready"
  end

  test "label filter narrows the set", %{scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"

    keep =
      mk_task!("keep-#{System.unique_integer([:positive])}", scope, %{
        "parent_id" => epic,
        "labels" => ["wave:9"]
      })

    _drop =
      mk_task!("drop-#{System.unique_integer([:positive])}", scope, %{
        "parent_id" => epic,
        "labels" => ["wave:1"]
      })

    rows =
      TaskQuery.rows_for_query(
        %{"parent_id" => epic, "label" => "wave:9", "dataset" => @dataset},
        scope
      )

    assert Enum.map(rows, & &1["title"]) == [keep.title]
  end

  test "nil workspace fails closed (zero rows)", %{scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"
    mk_task!("x-#{System.unique_integer([:positive])}", scope, %{"parent_id" => epic})
    assert TaskQuery.rows_for_query(%{"parent_id" => epic, "dataset" => @dataset}, []) == []
  end
end

defmodule Barkpark.Content.PapersTaskResolveTest do
  @moduledoc "End-to-end: a paper block's query resolves to a live snapshot from the substrate."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Papers

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

  test "resolve_tasks_in_blocks fills a task-list block from live tasks", %{scope: scope} do
    epic = "epic-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "a-#{System.unique_integer([:positive])}",
          "title" => "collect",
          "content" => %{"kind" => "task", "lifecycle_status" => "done", "parent_id" => epic}
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "b-#{System.unique_integer([:positive])}",
          "title" => "inject",
          "content" => %{"kind" => "task", "lifecycle_status" => "open", "parent_id" => epic}
        },
        @dataset,
        scope
      )

    blocks = [%{"type" => "task-list", "query" => %{"parent_id" => epic, "dataset" => @dataset}}]
    [out] = Papers.resolve_tasks_in_blocks(blocks, scope)

    refute Map.has_key?(out, "query")
    statuses = out["snapshot"] |> Enum.map(& &1["status"]) |> Enum.sort()
    assert statuses == ["done", "ready"]
  end
end
