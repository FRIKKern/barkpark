defmodule Barkpark.Tasks.PaperTaskSchemaReadCountTest do
  @moduledoc """
  ctx-b6-memoized-visibility-gate — a paper render resolves the `task` schema
  ONCE however many query-carrying task blocks it holds. Counted from Ecto's
  `[:barkpark, :repo, :query]` telemetry (source `schema_definitions`), scoped
  to this process.
  """
  use Barkpark.DataCase, async: true

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

  defp schema_reads(fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:barkpark, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == owner and meta[:source] == "schema_definitions",
            do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  defp blocks(n),
    do:
      for(
        i <- 1..n,
        do: %{
          "type" => "task-list",
          "query" => %{"parent_id" => "epic-#{i}", "dataset" => @dataset}
        }
      )

  @tag :requires_plugins
  test "one task schema read per render, for 1 block and for 12", %{scope: scope} do
    one = schema_reads(fn -> Papers.resolve_tasks_in_blocks(blocks(1), scope) end)
    twelve = schema_reads(fn -> Papers.resolve_tasks_in_blocks(blocks(12), scope) end)

    assert one >= 1, "the counter saw no schema read at all — it measures nothing"
    assert twelve == one, "12 blocks read the task schema #{twelve} times, 1 block #{one}"
  end
end
