defmodule Barkpark.Tasks.Prime do
  @moduledoc false
  # One-call agent-rehydration reads for `GET /v1/tasks/prime`. Owns the three
  # multi-table reads the
  # HTTP controller previously built inline — lifted here verbatim so the web
  # layer delegates to the Tasks context instead of running domain queries
  # against `Document` / `MutationEvent` itself:
  #
  #   * `in_progress` — live claims (worker-narrowed when `:worker` is given),
  #     newest-touched first, capped at 100.
  #   * `recent_events` — the last `:limit` task `mutation_events`, newest
  #     first, as lean `{event, doc_id, at}` rows.
  #   * `counts` — lifecycle_status → count totals for the scope.
  #
  # Tenancy scoping is byte-identical to the former controller path: the same
  # fail-CLOSED `Scope.scope_to_workspace/3` on workspace, the same project /
  # claim-worker / event-workspace narrowing. The `ready` head and edge-count
  # rendering stay in their existing owners (`Tasks.ready/1`, the controller's
  # render helpers) — this module returns only the three reads it lifted.

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, MutationEvent, Scope}
  alias Barkpark.Repo

  @type result :: %{
          in_progress: [Document.t()],
          recent_events: [map()],
          counts: %{optional(String.t()) => non_neg_integer()}
        }

  @doc """
  Compose the prime reads for the given scope.

  ## Options
    * `:workspace_id` — binary uuid; fails CLOSED (zero rows) when nil.
    * `:project_id`   — binary uuid; narrows within the workspace.
    * `:worker`       — string; narrows `in_progress` to that worker's claims.
    * `:limit`        — integer bound for the `recent_events` slice.

  Returns `%{in_progress: [...], recent_events: [...], counts: %{...}}`.
  """
  @spec prime(keyword()) :: result()
  def prime(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    worker = Keyword.get(opts, :worker)
    limit = Keyword.get(opts, :limit)

    %{
      in_progress: in_progress(workspace_id, project_id, worker),
      recent_events: recent_events(workspace_id, limit),
      counts: lifecycle_counts(workspace_id, project_id)
    }
  end

  defp in_progress(workspace_id, project_id, worker) do
    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
      order_by: [desc: d.updated_at],
      limit: 100
    )
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_claim_worker(worker)
    |> Repo.all()
  end

  defp recent_events(workspace_id, limit) do
    from(e in MutationEvent,
      where: e.type == "task" and like(e.mutation, "task.%"),
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      select: %{event: e.mutation, doc_id: e.doc_id, at: e.inserted_at}
    )
    |> maybe_filter_event_workspace(workspace_id)
    |> Repo.all()
  end

  defp lifecycle_counts(workspace_id, project_id) do
    from(d in Document,
      where: d.type == "task",
      group_by: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content),
      select: {fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content), count(d.id)}
    )
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_project(project_id)
    |> Repo.all()
    |> Map.new()
  end

  # Tenancy filters — identical semantics to the controller's former
  # `Params.maybe_filter_*` helpers (workspace + event-workspace route through
  # the fail-CLOSED `Scope.scope_to_workspace/3`; project is a leaf narrowing;
  # claim-worker matches `content.claim.worker`).
  defp maybe_filter_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  defp maybe_filter_event_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  defp maybe_filter_claim_worker(query, nil), do: query

  defp maybe_filter_claim_worker(query, worker) when is_binary(worker),
    do: from(d in query, where: fragment("?->'claim'->>'worker'", d.content) == ^worker)
end
