defmodule Barkpark.Tasks.Queue do
  @moduledoc false
  # The dependency-aware, phase-scoped ready-queue query. `ready/1` (read-only)
  # and `Tasks.Claim.claim/2` (row-locked) both ride `ready_query/1` — keeping ONE
  # definition is what makes "claim returns exactly what ready would have picked"
  # a property of the code, not a documentation promise.

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge

  @ready_default_limit 50
  @ready_lifecycle_statuses ~w(open blocked)

  def ready(opts \\ []) do
    opts
    |> ready_query()
    |> Repo.all()
  end

  def ready_query(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    dataset = Keyword.get(opts, :dataset)
    phase_id = Keyword.get(opts, :phase_id)
    limit = Keyword.get(opts, :limit, @ready_default_limit)

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        where:
          not exists(
            from(e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and
                  e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
            )
          ),
        order_by: [
          asc_nulls_last: fragment("(?->>'priority')::int", d.content),
          asc: d.inserted_at
        ],
        limit: ^limit
      )

    base
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  defp maybe_filter_phase(query, nil), do: query

  defp maybe_filter_phase(query, phase_id) when is_binary(phase_id) do
    from([doc: d] in query,
      where: fragment("?->>'parent_id'", d.content) == ^phase_id
    )
  end
end
