defmodule Barkpark.Sync.PushConflict do
  @moduledoc """
  Durable per-event PUSH conflict quarantine. One row per
  `{source, dataset, event_id}`. When the remote REJECTS a push (stale-base CAS
  `rev_mismatch`, a fenced/stale task claim, or a resource conflict) we must
  NEVER silently overwrite the remote (invariant #5). Instead the local loser is
  PRESERVED here — its full envelope copied into `local_document` on INSERT only
  — and the push cursor is advanced only AFTER this durable write
  (write-then-advance, mirroring `Barkpark.Sync.DeadLetter`). The conflict is
  thus an inspectable quarantine, never a silent skip. The operator
  resolve/retry workflow and the Studio Conflicts pane that reads `list_open/2`
  are P3.
  """
  use Ecto.Schema
  import Ecto.Query
  alias Barkpark.Repo

  @primary_key false
  schema "sync_push_conflicts" do
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :event_id, :integer, primary_key: true
    field :doc_id, :string
    field :type, :string
    field :kind, :string
    field :local_document, :map
    field :expected_remote_rev, :string
    field :actual_remote_rev, :string
    field :status, :string, default: "open"
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Record a push conflict for `{source, dataset, event_id}`. `attrs` carries
  `:doc_id`, `:type`, `:kind`, `:local_document` (THE preserved loser),
  `:expected_remote_rev`, `:actual_remote_rev`, `:last_error`. The preserved
  envelope/loser is written on INSERT only; a conflict (re-record of the same
  event_id) updates `last_error`/`updated_at` ONLY — it never overwrites the
  loser.
  """
  @spec record(String.t(), String.t(), non_neg_integer(), map()) :: :ok
  def record(source, dataset, event_id, attrs)
      when is_binary(source) and is_binary(dataset) and is_integer(event_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          source: source,
          dataset: dataset,
          event_id: event_id,
          doc_id: attrs[:doc_id],
          type: attrs[:type],
          kind: attrs[:kind],
          local_document: attrs[:local_document],
          expected_remote_rev: attrs[:expected_remote_rev],
          actual_remote_rev: attrs[:actual_remote_rev],
          status: "open",
          last_error: attrs[:last_error],
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [last_error: attrs[:last_error], updated_at: now]],
      conflict_target: [:source, :dataset, :event_id]
    )

    :ok
  end

  @doc "Queryable surface (P3 Studio pane): all open conflicts for `{source, dataset}`."
  @spec list_open(String.t(), String.t()) :: [%__MODULE__{}]
  def list_open(source, dataset) do
    from(c in __MODULE__,
      where: c.source == ^source and c.dataset == ^dataset and c.status == "open",
      order_by: [asc: c.event_id]
    )
    |> Repo.all()
  end
end
