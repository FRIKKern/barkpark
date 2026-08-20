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
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.PortableDoc.TaskResolver
  alias Barkpark.{Content, Tasks}
  alias Barkpark.Tasks.Query, as: TaskQuery
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: StudioPaper

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

    %{
      proj_a: proj_a,
      proj_b: proj_b,
      scope_a: scope_a,
      scope_b: scope_b,
      ws_a: ws_a,
      ws_b: ws_b
    }
  end

  defp register_task_schema!(scope, opts \\ []) do
    private_fields = Keyword.get(opts, :private_fields, [])

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> mark_private(private_fields)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  # Flag the named fields `private` in the schema's field list — the schema-side
  # field-visibility marking `Envelope.field_readable?/3` reads.
  defp mark_private(%{"name" => "task", "fields" => fields} = attrs, private)
       when private != [] do
    Map.put(
      attrs,
      "fields",
      Enum.map(fields, fn f ->
        if Map.get(f, "name") in private, do: Map.put(f, "private", true), else: f
      end)
    )
  end

  defp mark_private(attrs, _private), do: attrs

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

  test "Studio editor preview wires the scoped aggregate into the reader shape", %{
    proj_a: proj_a,
    scope_a: scope_a,
    ws_a: ws_a
  } do
    mk_task!(scope_a, %{"lifecycle_status" => "open"})
    mk_task!(scope_a, %{"lifecycle_status" => "done"})

    block = %{"id" => "preview-stat", "type" => "stat", "query" => %{"source" => "tasks"}}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_project: proj_a, current_workspace: ws_a, dataset: @dataset}
    }

    assert [entry] = StudioPaper.task_previews([block], socket)

    assert entry == %{
             "attrs" => %{"value" => 2},
             "block_id" => "preview-stat",
             "type" => "stat"
           }

    assert TaskResolver.apply_preview(block, entry) ==
             TaskResolver.resolve([block], no_rows(), agg_fetch(scope_a)) |> List.first()
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

  # ── PROOF 5 (v2): measure whitelist + field-visibility cross-check ───────────

  defp agg(op, field), do: %{"op" => op, "field" => field}

  test "a measure over a NON-whitelisted field is rejected (no number leaks)", %{
    scope_a: scope_a
  } do
    # Two tasks carry a priority; a naive `sum(content->>'x')` read would total
    # them. The closed measure whitelist rejects the field up front — the reducer
    # never touches it, so no aggregate is produced.
    mk_task!(scope_a, %{"priority" => 2})
    mk_task!(scope_a, %{"priority" => 3})

    query = %{"source" => "tasks", "agg" => agg("sum", "not_a_measure")}

    assert {:error, {:bad_measure, {:field, "not_a_measure"}}} =
             TaskQuery.agg_for_query(query, scope_a, dataset: @dataset)

    # And the block is left untouched — the renderer shows its dim placeholder,
    # never a leaked number.
    block = %{"type" => "stat", "id" => "s1", "query" => query}
    assert [^block] = TaskResolver.resolve([block], no_rows(), agg_fetch_v2(scope_a))
  end

  test "a WHITELISTED measure whose field the schema marks PRIVATE is rejected", %{} do
    # A workspace whose task schema flags `priority` PRIVATE. `priority` IS in
    # @agg_measures, so the whitelist alone would allow it — the belt+suspenders
    # field_readable? cross-check (anonymous, fail-closed) is what rejects it.
    # Fail-before: without the cross-check, a whitelisted-but-private field's
    # values would be summed.
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]
    register_task_schema!(scope, private_fields: ["priority"])

    mk_task!(scope, %{"priority" => 2})
    mk_task!(scope, %{"priority" => 3})

    query = %{"source" => "tasks", "agg" => agg("sum", "priority")}

    assert {:error, {:bad_measure, {:not_readable, "priority"}}} =
             TaskQuery.agg_for_query(query, scope, dataset: @dataset)
  end

  # ── PROOF 6 (v2): k-anonymity suppression (nil, never 0 or the raw value) ────

  test "a sub-k bucket is SUPPRESSED (nil); a k-large sibling shows a real sum", %{
    scope_a: scope_a
  } do
    # `open` bucket: 5 tasks × priority 1 → sum 5 (count 5 ≥ k). `done` bucket:
    # ONE task × priority 3 → count 1 < k → suppressed. Fail-before: without the
    # k-anon floor the singleton bucket would return 3 — the raw row value.
    for _ <- 1..5, do: mk_task!(scope_a, %{"lifecycle_status" => "open", "priority" => 1})
    mk_task!(scope_a, %{"lifecycle_status" => "done", "priority" => 3})

    query = %{
      "source" => "tasks",
      "groupBy" => "status",
      "agg" => agg("sum", "priority")
    }

    {:ok, tally} = TaskQuery.agg_for_query(query, scope_a, dataset: @dataset)

    assert Map.get(tally.tally, {"open", :__all__}) == 5
    # Suppressed → absent from the finalized tally (reads as nil, never 0/3).
    assert Map.get(tally.tally, {"done", :__all__}) == nil
    refute Map.get(tally.tally, {"done", :__all__}) == 3

    # Through the chart shaper the suppressed cell passes as nil, never coerced.
    block = %{"type" => "chart", "id" => "c1", "query" => query}
    [out] = TaskResolver.resolve([block], no_rows(), agg_fetch_v2(scope_a))
    by_label = Map.new(out["series"], fn %{"label" => l, "points" => p} -> {l, p} end)
    assert by_label["open"] == [5]
    assert by_label["done"] == [nil]
  end

  test "count op is EXEMPT from suppression (a singleton bucket still counts)", %{
    scope_a: scope_a
  } do
    mk_task!(scope_a, %{"lifecycle_status" => "done"})

    {:ok, tally} =
      TaskQuery.agg_for_query(
        %{"source" => "tasks", "groupBy" => "status", "agg" => %{"op" => "count"}},
        scope_a,
        dataset: @dataset
      )

    assert Map.get(tally.tally, {"done", :__all__}) == 1

    # And `agg:{op:count}` is byte-identical to no agg (v1 back-compat).
    {:ok, v1} =
      TaskQuery.agg_for_query(%{"source" => "tasks", "groupBy" => "status"}, scope_a)

    assert Map.delete(tally, :op) == Map.delete(v1, :op)
  end

  # ── PROOF 7 (v2): tenancy — a measure inherits the SAME fail-closed scope ────

  test "a SUM in workspace A excludes workspace B; nil scope suppresses", %{
    scope_a: scope_a,
    scope_b: scope_b
  } do
    # A: 5 × priority 1 → 5. B: 5 × priority 4 → 20. The WHERE clause is
    # untouched from v1 — the measure just folds the SAME scoped rows.
    for _ <- 1..5, do: mk_task!(scope_a, %{"priority" => 1})
    for _ <- 1..5, do: mk_task!(scope_b, %{"priority" => 4})

    query = %{"source" => "tasks", "agg" => agg("sum", "priority")}

    {:ok, ta} = TaskQuery.agg_for_query(query, scope_a, dataset: @dataset)
    assert ta.total == 5

    {:ok, tb} = TaskQuery.agg_for_query(query, scope_b, dataset: @dataset)
    assert tb.total == 20

    # nil workspace → zero rows → measure total suppressed (nil, never 0).
    {:ok, tnil} = TaskQuery.agg_for_query(query, [], dataset: @dataset)
    assert tnil.total == nil
  end

  test "avg / min / max fold the scoped rows correctly", %{scope_a: scope_a} do
    for p <- 0..4, do: mk_task!(scope_a, %{"priority" => p})

    for {op, expect} <- [{"sum", 10}, {"avg", 2.0}, {"min", 0}, {"max", 4}] do
      {:ok, t} =
        TaskQuery.agg_for_query(
          %{"source" => "tasks", "agg" => agg(op, "priority")},
          scope_a,
          dataset: @dataset
        )

      assert t.total == expect, "#{op} total should be #{inspect(expect)}"
    end
  end

  # ── PROOF 8 (v2): min/max is gated to extremum_safe? measures ────────────────

  test "min/max on a non-extremum-safe measure is rejected; sum/avg allowed" do
    # A synthetic whitelist where the measure is NOT flagged extremum_safe. This
    # is the guard a FUTURE sensitive measure relies on: it may be summed/avg'd
    # but a min/max would surface a real row's value.
    measures = %{"sensitive" => {fn _ -> 1 end, false}}

    assert {:error, {:bad_measure, {:not_extremum_safe, "sensitive"}}} =
             TaskQuery.validate_measure("min", "sensitive", measures)

    assert {:error, {:bad_measure, {:not_extremum_safe, "sensitive"}}} =
             TaskQuery.validate_measure("max", "sensitive", measures)

    assert {:ok, _} = TaskQuery.validate_measure("sum", "sensitive", measures)
    assert {:ok, _} = TaskQuery.validate_measure("avg", "sensitive", measures)

    # The real default measure (`priority`) IS extremum-safe → min/max allowed.
    assert {:ok, _} = TaskQuery.validate_measure("min", "priority")
    assert {:ok, _} = TaskQuery.validate_measure("max", "priority")

    # An unknown op / field is rejected distinctly (not as an extremum issue).
    assert {:error, {:bad_measure, {:op, "median"}}} =
             TaskQuery.validate_measure("median", "priority")

    assert {:error, {:bad_measure, {:field, "ghost"}}} =
             TaskQuery.validate_measure("sum", "ghost")
  end

  defp agg_fetch_v2(scope), do: fn q -> TaskQuery.agg_for_query(q, scope, dataset: @dataset) end
end
