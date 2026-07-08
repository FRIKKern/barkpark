defmodule Barkpark.Tasks.AggQueryTest do
  @moduledoc """
  DB-backed proofs for the COUNT-ONLY aggregate resolver:

    * `Barkpark.Tasks.Query.agg_for_query/2` — the scoped count roll-up.
    * `Barkpark.PortableDoc.TaskResolver` data-viz arm — the tally → ratified
      chart/heatmap/stat Attrs, byte-for-byte what the renderers consume.

  The load-bearing proof is CROSS-WORKSPACE ISOLATION (mutation-proven): an
  aggregate scoped to workspace A must NEVER count workspace B's rows. Written
  so that dropping `Scope.scope_to_workspace/3` makes A's count include B → RED.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tasks}
  alias Barkpark.Tasks.Query, as: TaskQuery
  alias Barkpark.PortableDoc.TaskResolver

  @dataset "test"

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    register_task_schema!(scope_a)
    register_task_schema!(scope_b)

    %{scope_a: scope_a, scope_b: scope_b}
  end

  defp register_task_schema!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(scope, content) do
    doc_id = "t-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content)
        },
        @dataset,
        scope
      )

    doc
  end

  # ── PROOF 1: cross-workspace isolation (mutation-proven) ─────────────────────

  test "aggregate in workspace A never counts workspace B's rows", %{
    scope_a: scope_a,
    scope_b: scope_b
  } do
    # A: 2 tasks. B: 3 tasks. A's total count must be 2, never 5.
    mk_task!(scope_a, %{})
    mk_task!(scope_a, %{})
    mk_task!(scope_b, %{})
    mk_task!(scope_b, %{})
    mk_task!(scope_b, %{})

    {:ok, tally} = TaskQuery.agg_for_query(%{"source" => "tasks"}, scope_a)

    assert tally.total == 2,
           "workspace A must count ONLY its own 2 rows — dropping scope_to_workspace would make this 5 (B leaks in)"

    {:ok, tally_b} = TaskQuery.agg_for_query(%{"source" => "tasks"}, scope_b)
    assert tally_b.total == 3
  end

  test "nil / foreign workspace fails closed (zero count)", %{scope_a: scope_a} do
    mk_task!(scope_a, %{})
    assert {:ok, %{total: 0}} = TaskQuery.agg_for_query(%{"source" => "tasks"}, [])

    assert {:ok, %{total: 0}} =
             TaskQuery.agg_for_query(%{"source" => "tasks"},
               workspace_id: "00000000-0000-0000-0000-000000000000"
             )
  end

  # ── PROOF 2: resolved shape byte-matches the ratified contract ───────────────

  defp agg_fetch(scope), do: fn q -> TaskQuery.agg_for_query(q, scope) end
  defp no_rows, do: fn _ -> [] end

  test "chart resolves to the ratified series shape (count per groupBy value)", %{
    scope_a: scope_a
  } do
    mk_task!(scope_a, %{"lifecycle_status" => "open"})
    mk_task!(scope_a, %{"lifecycle_status" => "open"})
    mk_task!(scope_a, %{"lifecycle_status" => "done"})

    query = %{"source" => "tasks", "groupBy" => "status"}
    block = %{"type" => "chart", "id" => "c1", "query" => query}

    [out] = TaskResolver.resolve([block], no_rows(), agg_fetch(scope_a))

    refute Map.has_key?(out, "query")
    assert %{"series" => series} = out
    assert Map.keys(out) |> Enum.sort() == ["id", "series", "type"]

    by_label = Map.new(series, fn %{"label" => l, "points" => p} -> {l, p} end)
    assert by_label["open"] == [2]
    assert by_label["done"] == [1]

    # Each series entry is exactly {label, points}.
    for s <- series, do: assert(Map.keys(s) |> Enum.sort() == ["label", "points"])
  end

  test "heatmap resolves to the ratified cells/max/rowLabels/colLabels shape", %{
    scope_a: scope_a
  } do
    mk_task!(scope_a, %{"lifecycle_status" => "open", "priority" => 0})
    mk_task!(scope_a, %{"lifecycle_status" => "open", "priority" => 0})
    mk_task!(scope_a, %{"lifecycle_status" => "done", "priority" => 2})

    query = %{"source" => "tasks", "groupBy" => ["status", "priority"]}
    block = %{"type" => "heatmap", "id" => "h1", "query" => query}

    [out] = TaskResolver.resolve([block], no_rows(), agg_fetch(scope_a))

    refute Map.has_key?(out, "query")

    assert Map.keys(out) |> Enum.sort() == [
             "cells",
             "colLabels",
             "id",
             "max",
             "rowLabels",
             "type"
           ]

    assert out["rowLabels"] == ["done", "open"]
    assert out["colLabels"] == ["0", "2"]
    # cells row-major: done→[p0:0, p2:1], open→[p0:2, p2:0]
    assert out["cells"] == [[0, 1], [2, 0]]
    assert out["max"] == 2
  end

  test "stat resolves to a scalar count; with `over` gains a spark", %{scope_a: scope_a} do
    mk_task!(scope_a, %{})
    mk_task!(scope_a, %{})

    scalar_block = %{"type" => "stat", "id" => "s1", "query" => %{"source" => "tasks"}}
    [scalar] = TaskResolver.resolve([scalar_block], no_rows(), agg_fetch(scope_a))
    assert Map.keys(scalar) |> Enum.sort() == ["id", "type", "value"]
    assert scalar["value"] == 2

    spark_query = %{"source" => "tasks", "over" => %{"bucket" => "day", "last" => 7}}
    spark_block = %{"type" => "stat", "id" => "s2", "query" => spark_query}
    [spark] = TaskResolver.resolve([spark_block], no_rows(), agg_fetch(scope_a))
    assert spark["value"] == 2
    assert is_list(spark["spark"]) and Enum.sum(spark["spark"]) == 2
  end

  # ── PROOF 3: offline parity — literal blocks with NO query pass through ───────

  test "a literal data-viz block with no query is untouched (offline/wasm)", %{scope_a: scope_a} do
    literal_chart = %{"type" => "chart", "series" => [%{"label" => "a", "points" => [1, 2]}]}
    literal_stat = %{"type" => "stat", "value" => 42}

    assert [^literal_chart, ^literal_stat] =
             TaskResolver.resolve([literal_chart, literal_stat], no_rows(), agg_fetch(scope_a))
  end

  test "a query-carrying data-viz block passes through untouched when agg_fetch is absent" do
    block = %{
      "type" => "chart",
      "id" => "c1",
      "query" => %{"source" => "tasks", "groupBy" => "status"}
    }

    # 2-arg resolve (agg_fetch defaults to nil) — the offline/wasm degrade.
    assert [^block] = TaskResolver.resolve([block], no_rows())
  end

  # ── PROOF 4: whitelist reject + malformed floor ──────────────────────────────

  test "an out-of-whitelist groupBy dim is rejected", %{scope_a: scope_a} do
    mk_task!(scope_a, %{})

    assert {:error, {:bad_dim, "secret_jsonb_path"}} =
             TaskQuery.agg_for_query(
               %{"source" => "tasks", "groupBy" => "secret_jsonb_path"},
               scope_a
             )
  end

  test "an out-of-whitelist over bucket / field is rejected", %{scope_a: scope_a} do
    assert {:error, {:bad_over, "century"}} =
             TaskQuery.agg_for_query(
               %{"source" => "tasks", "over" => %{"bucket" => "century"}},
               scope_a
             )

    assert {:error, {:bad_over_field, "content->>'ssn'"}} =
             TaskQuery.agg_for_query(
               %{"source" => "tasks", "over" => %{"bucket" => "day", "on" => "content->>'ssn'"}},
               scope_a
             )
  end

  test "a non-task source is rejected", %{scope_a: scope_a} do
    assert {:error, {:bad_source, "posts"}} =
             TaskQuery.agg_for_query(%{"source" => "posts"}, scope_a)
  end

  test "a rejected block query leaves the block untouched (renderer placeholder)", %{
    scope_a: scope_a
  } do
    block = %{
      "type" => "chart",
      "id" => "c1",
      "query" => %{"source" => "tasks", "groupBy" => "nope"}
    }

    # agg_fetch returns {:error, _} → block keeps its query, renderer degrades.
    assert [^block] = TaskResolver.resolve([block], no_rows(), agg_fetch(scope_a))
  end
end
