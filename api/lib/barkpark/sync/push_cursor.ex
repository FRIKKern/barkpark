defmodule Barkpark.Sync.PushCursor do
  @moduledoc """
  Persistent per-target high-water mark for the PUSH-sync subsystem.

  One row per `{source, dataset}` holding the largest LOCAL `mutation_events.id`
  that has been pushed to the remote (or deliberately, durably recorded as a
  conflict). This is a SEPARATE cursor from `Barkpark.Sync.Cursor` (the pull
  high-water mark): the two live in INCOMPARABLE id-spaces — pull tracks the
  remote producer's `Last-Event-ID`, push tracks the local `mutation_events.id`
  — so mixing them would let one rewind the other (invariant #3). The push loop
  reads `get/2`, drains `id > cursor` from the `Outbox`, and only advances the
  cursor after a successful ack OR a durable `PushConflict.record` — never past
  an un-pushed event on a transient error.

  `put/3` is a MONOTONIC upsert — it only ever advances the stored id, never
  rewinds it, even under out-of-order calls. (Structural copy of
  `Barkpark.Sync.Cursor`, distinct table `sync_push_cursors`.)
  """

  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo

  @primary_key false
  schema "sync_push_cursors" do
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :event_id, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Current push high-water mark for `{source, dataset}`; 0 when none is stored."
  @spec get(String.t(), String.t()) :: non_neg_integer()
  def get(source, dataset) when is_binary(source) and is_binary(dataset) do
    from(c in __MODULE__,
      where: c.source == ^source and c.dataset == ^dataset,
      select: c.event_id
    )
    |> Repo.one()
    |> case do
      nil -> 0
      id -> id
    end
  end

  @doc """
  Monotonically advance the stored push high-water mark to `event_id`. A no-op
  when the stored value is already `>= event_id`.
  """
  @spec put(String.t(), String.t(), non_neg_integer()) :: :ok
  def put(source, dataset, event_id)
      when is_binary(source) and is_binary(dataset) and is_integer(event_id) and event_id >= 0 do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          source: source,
          dataset: dataset,
          event_id: event_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        from(c in __MODULE__,
          where: fragment("EXCLUDED.event_id") > c.event_id,
          update: [
            set: [
              event_id: fragment("EXCLUDED.event_id"),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:source, :dataset]
    )

    :ok
  end

  @doc """
  One-time, idempotent init of the push high-water mark for `{source, dataset}`
  to the dataset's current head (`MAX(mutation_events.id)`, 0 when empty) — ONLY
  when no cursor row exists. Skips ALL pre-enablement history (cloned/pulled rows,
  regardless of the migration's `source="api"` backfill) so first enable never
  replays it to the remote (no ping-pong, invariant #4). Steady-state echo of
  post-enable PULL rows stays handled by the Outbox `source="sync"` exclusion.
  `on_conflict: :nothing` makes this a NO-OP once a row exists — it never rewinds
  an already-advanced cursor and is safe to call on every boot.
  """
  @spec bootstrap_if_absent(String.t(), String.t()) :: :ok
  def bootstrap_if_absent(source, dataset)
      when is_binary(source) and is_binary(dataset) do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          source: source,
          dataset: dataset,
          event_id: head_event_id(dataset),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:source, :dataset]
    )

    :ok
  end

  defp head_event_id(dataset) do
    from(e in MutationEvent, where: e.dataset == ^dataset, select: max(e.id))
    |> Repo.one() || 0
  end
end
