defmodule Barkpark.Sync.PushDocRev do
  @moduledoc """
  Remote-rev ledger for the PUSH-sync subsystem. One row per
  `{source, dataset, doc_id}` holding the remote's last-known rev for that doc.

  This is the CAS base sent as `ifRevisionID` on each push: the local
  `mutation_events.previous_rev` is the LOCAL prior rev (minted by the local
  writer) and is meaningless to the remote, so it cannot be the conditional
  base. The ledger is updated on every successful push ack (mandatory) and is
  ALSO primed by the pull applier's observed remote rev (`Applier.prime_push_ledger/3`,
  wired in P2) so a cloned/pulled doc edited locally pushes back with the correct
  `ifRevisionID` instead of a fail-closed `create` that spuriously conflicts.

  `put/4` is a last-write-wins upsert on `{source, dataset, doc_id}` — the
  remote rev only ever moves forward as we observe it.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Repo

  @primary_key false
  schema "sync_push_doc_revs" do
    field :source, :string, primary_key: true
    field :dataset, :string, primary_key: true
    field :doc_id, :string, primary_key: true
    field :remote_rev, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The remote's last-known rev for `{source, dataset, doc_id}`; nil when unknown (first push)."
  @spec get(String.t(), String.t(), String.t()) :: String.t() | nil
  def get(source, dataset, doc_id)
      when is_binary(source) and is_binary(dataset) and is_binary(doc_id) do
    from(r in __MODULE__,
      where: r.source == ^source and r.dataset == ^dataset and r.doc_id == ^doc_id,
      select: r.remote_rev
    )
    |> Repo.one()
  end

  @doc "Record the remote's last-known rev for a doc (last-write-wins upsert)."
  @spec put(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def put(source, dataset, doc_id, remote_rev)
      when is_binary(source) and is_binary(dataset) and is_binary(doc_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          source: source,
          dataset: dataset,
          doc_id: doc_id,
          remote_rev: remote_rev,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [remote_rev: remote_rev, updated_at: now]],
      conflict_target: [:source, :dataset, :doc_id]
    )

    :ok
  end
end
