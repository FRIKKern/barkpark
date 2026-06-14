defmodule Barkpark.EdgeProjector.TasksEdgeProjectionTest do
  @moduledoc """
  Phase 3 — the Tasks plugin's `extract_edges/2` projects the AUTHORITATIVE
  `task_edges` rows (gap #1) carrying their real `kind` (gap #2).

  These are the two CONFIRMED blocking fixes:

    1. The dependency graph comes from the `task_edges` table — the only
       authoritative store — NOT the DEAD `content.dependencies` key. The pure
       callback reads the rows the worker HYDRATES onto the payload
       (`Tasks.hydrate_edges/1`); writing `content.dependencies` projects NO
       blocks edge.
    2. BOTH whitelisted kinds (`blocks` AND `discovered-from`) surface — the
       row's real `kind` is mapped straight through, never hardcoded `"blocks"`.

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Tasks, as: TasksPlugin

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

    prev_plugins = Application.get_env(:barkpark, :plugins)
    Application.delete_env(:barkpark, :plugins)

    # Register the REAL Tasks plugin so the collector drives its
    # resolve_extract_edges/2 (not a fake) — the headline blast-radius path.
    :ok = Registry.register(TasksPlugin, %{"plugin_name" => "tasks"})

    on_exit(fn ->
      Registry.reset()

      case prev_plugins do
        nil -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)

    %{scope: scope}
  end

  # Create + publish a task doc, return the published %Document{}. `content_extra`
  # is merged into the task content (where `parent_id` / `dependencies` live).
  defp publish_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp project_edges(doc) do
    Registry.collect_edge_extractors(baseline: [], ctx: %{doc: doc, dataset: @dataset})
  end

  describe "task_edges is the authoritative source (gap #1)" do
    test "a real blocks task_edges row surfaces as a blocks content edge", %{scope: scope} do
      src = publish_task!("t-a", scope)
      blk = publish_task!("t-b", scope)

      # Real dependency lives in task_edges (from = dependent, to = blocker).
      {:ok, _} = Tasks.add_dep(src.id, blk.id, :blocks)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      blocks = Enum.filter(edges, &(&1[:kind] == "blocks"))
      assert [%{from_id: "t-a", to_id: "t-b", plugin_source: "tasks"}] = blocks
    end

    test "content.dependencies is a DEAD KEY — writing it projects NO blocks edge",
         %{scope: scope} do
      # No task_edges rows; the dependency lives ONLY in the dead key.
      src = publish_task!("t-c", scope, %{"dependencies" => ["t-d"]})
      _blk = publish_task!("t-d", scope)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      assert Enum.filter(edges, &(&1[:kind] == "blocks")) == []
    end

    test "an un-hydrated task emits no blocks edge (the dead key is never read)",
         %{scope: scope} do
      src = publish_task!("t-e", scope)
      blk = publish_task!("t-f", scope)
      {:ok, _} = Tasks.add_dep(src.id, blk.id, :blocks)

      # Project the RAW (un-hydrated) doc — no task_edges on the payload.
      edges = project_edges(src)
      assert Enum.filter(edges, &(&1[:kind] == "blocks")) == []
    end
  end

  describe "both kinds surface (gap #2)" do
    test "a discovered-from task_edges row surfaces as a discovered-from content edge",
         %{scope: scope} do
      src = publish_task!("t-g", scope)
      disc = publish_task!("t-h", scope)

      {:ok, _} = Tasks.add_dep(src.id, disc.id, :"discovered-from")

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      found = Enum.filter(edges, &(&1[:kind] == "discovered-from"))
      assert [%{from_id: "t-g", to_id: "t-h", plugin_source: "tasks"}] = found
    end

    test "blocks AND discovered-from from the same source both surface with their real kind",
         %{scope: scope} do
      src = publish_task!("t-i", scope)
      b = publish_task!("t-j", scope)
      d = publish_task!("t-k", scope)

      {:ok, _} = Tasks.add_dep(src.id, b.id, :blocks)
      {:ok, _} = Tasks.add_dep(src.id, d.id, :"discovered-from")

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      kinds = edges |> Enum.map(& &1[:kind]) |> Enum.sort()
      assert "blocks" in kinds
      assert "discovered-from" in kinds
    end
  end

  describe "parent_id still projects (regression)" do
    test "content.parent_id surfaces as a parent edge alongside task_edges",
         %{scope: scope} do
      src = publish_task!("t-l", scope, %{"parent_id" => "t-parent"})
      b = publish_task!("t-m", scope)
      {:ok, _} = Tasks.add_dep(src.id, b.id, :blocks)

      hydrated = TasksPlugin.hydrate_edges(src)
      edges = project_edges(hydrated)

      parent = Enum.find(edges, &(&1[:kind] == "parent"))
      assert parent[:from_id] == "t-l"
      assert parent[:to_id] == "t-parent"

      assert Enum.any?(edges, &(&1[:kind] == "blocks"))
    end
  end
end
