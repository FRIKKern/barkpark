defmodule Barkpark.Content.Exemptions do
  @moduledoc """
  The legacy exemption ledger of the publish wall (authoring-excellence D6).

  `authoring_exemptions` is a deploy-time SNAPSHOT of every document that was
  already published when the wall migration ran (`INSERT … SELECT FROM
  documents WHERE status = 'published'` at migration time — never a literal
  count). A row means "this document predates the label spine; its republishes
  pass the wall unlabeled".

  The ledger is **DELETE-only after the seed** — this module exposes no insert.
  The moment a document passes `LabelSpine.validate` at publish, its row is
  cleared (`clear/2`, the ratchet shrink), so the exempt count is monotone
  non-increasing and stripping the tags back off later re-hits the wall
  (published-id-existence alone was REJECTED as the predicate for exactly that
  strip-and-republish loophole).
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo

  @doc "Is this published doc id grandfathered in this dataset?"
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(doc_id, dataset) when is_binary(doc_id) and is_binary(dataset) do
    Repo.exists?(
      from(e in "authoring_exemptions", where: e.doc_id == ^doc_id and e.dataset == ^dataset)
    )
  end

  @doc """
  The ratchet shrink: drop the doc's exemption row (idempotent). Called when a
  publish PASSES the label spine — from then on the document is held to the
  wall like any new one.
  """
  @spec clear(String.t(), String.t()) :: :ok
  def clear(doc_id, dataset) when is_binary(doc_id) and is_binary(dataset) do
    Repo.delete_all(
      from(e in "authoring_exemptions", where: e.doc_id == ^doc_id and e.dataset == ^dataset)
    )

    :ok
  end
end
