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
  Is this doc grandfathered FOR THIS CALLER'S WORKSPACE?

  The ledger is keyed `(doc_id, dataset)` with no workspace, and every
  workspace owns a dataset with the same name, so `member?/2` alone answers
  for a slug in ANY workspace: a brand-new paper in workspace B whose slug
  matched another workspace's grandfathered row skipped the whole wall, and
  B's passing publish then cleared that other workspace's row
  (task-98206e62ba0b3168). With a `:workspace_id` in `opts`, the row counts
  only when the SAME document (doc_id, type, dataset) exists in that workspace
  and predates the ledger snapshot (`inserted_at <= exempted_at`), i.e. it is
  the document the snapshot grandfathered. Without a workspace (an unscoped,
  instance-level caller) this is `member?/2`.
  """
  @spec member?(String.t(), String.t(), String.t(), keyword()) :: boolean()
  def member?(doc_id, dataset, type, opts)
      when is_binary(doc_id) and is_binary(dataset) and is_binary(type) and is_list(opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and ws != "" ->
        Repo.exists?(
          from(e in "authoring_exemptions",
            join: d in "documents",
            # The published row or its draft twin (`drafts.<id>`).
            on:
              (d.doc_id == e.doc_id or d.doc_id == fragment("'drafts.' || ?", e.doc_id)) and
                d.dataset == e.dataset and d.type == ^type,
            where:
              e.doc_id == ^doc_id and e.dataset == ^dataset and
                d.workspace_id == type(^ws, :binary_id) and d.inserted_at <= e.exempted_at
          )
        )

      _ ->
        member?(doc_id, dataset)
    end
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
