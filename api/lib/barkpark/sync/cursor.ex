defmodule Barkpark.Sync.Cursor do
  @moduledoc """
  Persistent per-source high-water mark for the pull-sync subsystem.

  One row per `{source, dataset}` holding the largest applied event id. The
  cursor is the `Last-Event-ID` resume point AND the Phase-1 echo-dedup gate:
  the remote producer replays STRICTLY `id > since`
  (`BarkparkWeb.ListenController.replay_since/3`), and the `Applier` skips any
  event whose id is `<= cursor`, so an already-applied event never re-fires a
  spurious local mutation.

  `put/3` is a MONOTONIC upsert — it only ever advances the stored id, never
  rewinds it, even under out-of-order calls.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Repo

  @primary_key false
  schema "sync_cursors" do
    # Stamped per-workspace ATTRIBUTION column (charter D55): drives E1 export
    # (`WHERE workspace_id=$ws`) + FK-cascade delete. NOT a key component — the
    # `{source, dataset}` PK and the monotonic-upsert conflict target are
    # unchanged (D57). Nullable so the workspace-agnostic caller can stamp NULL.
    field :workspace_id, :binary_id
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :event_id, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Current high-water mark for `{source, dataset}`; 0 when none is stored."
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
  Monotonically advance the stored high-water mark to `event_id`, stamping
  `workspace_id` for per-workspace attribution. A no-op when the stored value is
  already `>= event_id`; the workspace_id is written on INSERT only.
  """
  @spec put(binary() | nil, String.t(), String.t(), non_neg_integer()) :: :ok
  def put(workspace_id, source, dataset, event_id)
      when is_binary(source) and is_binary(dataset) and is_integer(event_id) and event_id >= 0 do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          workspace_id: workspace_id,
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
end
