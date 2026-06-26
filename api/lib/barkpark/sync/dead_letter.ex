defmodule Barkpark.Sync.DeadLetter do
  @moduledoc """
  Durable per-event quarantine for the pull-sync subsystem. One row per
  `{source, dataset, event_id}`. A poison event (one that fails to apply
  repeatedly) is recorded here BEFORE the cursor is allowed past it, so
  dead-lettering is an inspectable quarantine, never a silent skip
  (see `Barkpark.Sync.Applier` — write-then-advance). `record_failure/5`
  writes the envelope on INSERT only; conflict updates never overwrite it.
  """
  use Ecto.Schema
  import Ecto.Query
  alias Barkpark.Repo

  @primary_key false
  schema "sync_dead_letters" do
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :event_id, :integer, primary_key: true
    field :attempts, :integer, default: 0
    field :status, :string, default: "pending"
    field :envelope, :map
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Insert-or-increment; returns the post-state attempt count. envelope set on INSERT only (never overwritten)."
  @spec record_failure(String.t(), String.t(), non_neg_integer(), map(), term()) :: pos_integer()
  def record_failure(source, dataset, event_id, envelope, reason) do
    now = DateTime.utc_now()

    {1, [%{attempts: attempts}]} =
      Repo.insert_all(
        __MODULE__,
        [
          %{
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
