defmodule Barkpark.Sync.DeadLetter do
  @moduledoc """
  Durable per-event quarantine for the pull-sync subsystem. One row per
  `{source, dataset, event_id}`. A poison event (one that fails to apply
  repeatedly) is recorded here BEFORE the cursor is allowed past it, so
  dead-lettering is an inspectable quarantine, never a silent skip
  (see `Barkpark.Sync.Applier` — write-then-advance). `record_failure/5`
  writes the envelope on INSERT only; conflict updates never overwrite it.

  ## The exit (task-b2b871424bd184eb)

  `status` moves `pending → dead` automatically and leaves quarantine ONLY
  through `resolve/3`, an operator act: `"dead"`/`"pending"` → `"resolved"`.
  The row is kept, envelope intact, for audit — resolving never deletes.
  There is deliberately NO replay: the cursor has already advanced past a
  dead event, so re-applying its (older) envelope could overwrite newer
  state. An operator who wants the write re-issues it at the source, then
  resolves the row. Today the call is the operator's from a remote console
  (`bin/barkpark rpc 'Barkpark.Sync.DeadLetter.resolve("api", "production", 42)'`);
  a Studio/HTTP surface over `list_dead/2` + `resolve/3` remains unbuilt.
  """
  use Ecto.Schema
  import Ecto.Query
  alias Barkpark.Repo

  @primary_key false
  schema "sync_dead_letters" do
    # Stamped per-workspace attribution column (charter D55) — E1 export + FK
    # cascade delete. NOT a key component; the `{source, dataset, event_id}` PK
    # and conflict target are unchanged (D57). Nullable (workspace-agnostic NULL).
    field :workspace_id, :binary_id
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :event_id, :integer, primary_key: true
    field :attempts, :integer, default: 0
    field :status, :string, default: "pending"
    field :envelope, :map
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Insert-or-increment; returns the post-state attempt count. envelope + workspace_id set on INSERT only (never overwritten)."
  @spec record_failure(binary() | nil, String.t(), String.t(), non_neg_integer(), map(), term()) ::
          pos_integer()
  def record_failure(workspace_id, source, dataset, event_id, envelope, reason) do
    now = DateTime.utc_now()

    {1, [%{attempts: attempts}]} =
      Repo.insert_all(
        __MODULE__,
        [
          %{
            workspace_id: workspace_id,
            source: source,
            dataset: dataset,
            event_id: event_id,
            envelope: envelope,
            attempts: 1,
            status: "pending",
            last_error: inspect(reason),
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [inc: [attempts: 1], set: [last_error: inspect(reason), updated_at: now]],
        conflict_target: [:source, :dataset, :event_id],
        returning: [:attempts]
      )

    attempts
  end

  @doc "Flip a quarantined event's status to \"dead\" (the queryable surface)."
  @spec mark_dead(String.t(), String.t(), non_neg_integer()) :: :ok
  def mark_dead(source, dataset, event_id) do
    from(d in __MODULE__,
      where: d.source == ^source and d.dataset == ^dataset and d.event_id == ^event_id
    )
    |> Repo.update_all(set: [status: "dead", updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Take one quarantined event OUT of quarantine: `"dead"` or `"pending"` →
  `"resolved"`. Returns `:ok`, or `{:error, :not_found}` when no quarantined
  row matches (absent, or already resolved). The envelope is kept.
  """
  @spec resolve(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def resolve(source, dataset, event_id) do
    from(d in __MODULE__,
      where:
        d.source == ^source and d.dataset == ^dataset and d.event_id == ^event_id and
          d.status in ["dead", "pending"]
    )
    |> Repo.update_all(set: [status: "resolved", updated_at: DateTime.utc_now()])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc "Queryable surface: all dead-lettered rows for `{source, dataset}`."
  @spec list_dead(String.t(), String.t()) :: [%__MODULE__{}]
  def list_dead(source, dataset) do
    from(d in __MODULE__,
      where: d.source == ^source and d.dataset == ^dataset and d.status == "dead",
      order_by: [asc: d.event_id]
    )
    |> Repo.all()
  end
end
