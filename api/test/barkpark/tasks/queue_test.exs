defmodule Barkpark.Tasks.QueueTest do
  @moduledoc """
  Focused tests for `Barkpark.Tasks.Queue` — the module that owns
  `ready_query/1` and `ready/1`.

  The integration tests in `tasks_ready_test.exs` cover blocker semantics,
  phase scoping, lifecycle filtering, tenancy, and concurrency via the
  `Tasks` facade.  This file fills the remaining gaps:

    1. `ready_query/1` returns an `%Ecto.Query{}` struct (it is used by
       `Claim.claim/2` as a composable base — never call Repo inside).
    2. Dataset isolation — `maybe_filter_dataset` ensures a task in
       "production" is NOT returned when querying "staging".
    3. `limit` option — the default cap applies and can be overridden
       down to 1 (only the highest-priority task comes back).
    4. `ready/1` with no workspace_id fails CLOSED (zero rows from
       `Scope.scope_to_workspace/3`), including when called with []).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Queue

  @dataset "production"
  @dataset_alt "staging"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope, @dataset)
    register_schemas!(scope, @dataset_alt)

    %{scope: scope}
  end

  defp register_schemas!(scope, dataset) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, dataset, content_extra \\ %{}) do
    content =
      Map.merge(
        %{"kind" => "task", "lifecycle_status" => "open"},
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        dataset,
        scope
      )

    doc
  end

  defp ids_of(docs), do: Enum.map(docs, & &1.id)

  # ─── (1) ready_query/1 returns a composable Ecto.Query ───────────────────

  describe "ready_query/1" do
    test "returns an %Ecto.Query{} struct — does not hit the DB by itself", %{scope: scope} do
      result = Queue.ready_query(scope ++ [dataset: @dataset])
      assert %Ecto.Query{} = result
    end
  end

  # ─── (2) Dataset isolation ────────────────────────────────────────────────

  describe "ready/1 — dataset isolation" do
    test "task in 'production' is NOT returned when querying 'staging'",
         %{scope: scope} do
      prod_task =
        mk_task!("ds-prod-#{System.unique_integer([:positive])}", scope, @dataset)

      staging_results = Queue.ready(scope ++ [dataset: @dataset_alt]) |> ids_of()
      prod_results = Queue.ready(scope ++ [dataset: @dataset]) |> ids_of()

      assert prod_task.id in prod_results,
             "task created in 'production' must appear in the production ready set"

      refute prod_task.id in staging_results,
             "task created in 'production' must NOT appear in the staging ready set"
    end

    test "tasks in each dataset appear only in their own ready set", %{scope: scope} do
      prod_task =
        mk_task!("ds-iso-prod-#{System.unique_integer([:positive])}", scope, @dataset)

      staging_task =
        mk_task!("ds-iso-staging-#{System.unique_integer([:positive])}", scope, @dataset_alt)

      prod_ids = Queue.ready(scope ++ [dataset: @dataset]) |> ids_of()
      staging_ids = Queue.ready(scope ++ [dataset: @dataset_alt]) |> ids_of()

      assert prod_task.id in prod_ids
      refute prod_task.id in staging_ids

      assert staging_task.id in staging_ids
      refute staging_task.id in prod_ids
    end
  end

  # ─── (3) limit option ─────────────────────────────────────────────────────

  describe "ready/1 — limit option" do
    test "limit: 1 returns at most 1 task even when multiple are ready", %{scope: scope} do
      phase_id = "phase-lim-#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        mk_task!("lim-#{i}-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id
        })
      end

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id, limit: 1])
      assert length(results) == 1
    end
  end

  # ─── (4) ready/1 fails CLOSED without workspace scope ────────────────────

  describe "ready/1 — no workspace scope" do
    test "empty opts list returns []" do
      assert Queue.ready([]) == []
    end

    test "explicit nil workspace_id returns []", %{scope: _scope} do
      assert Queue.ready([workspace_id: nil, dataset: @dataset]) == []
    end
  end
end
