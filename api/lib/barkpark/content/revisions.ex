defmodule Barkpark.Content.Revisions do
  @moduledoc """
  Revision history reads + restore.

  Leaf concern — lists/fetches `Barkpark.Content.Revision` rows and restores a
  document to a prior revision. Read-only except `restore_revision/4`, which
  funnels back through the write path via the still-on-facade
  `Barkpark.Content.upsert_document/4` (concern E).

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade so
  every external caller (`barkpark_web/contract/history`) is unchanged.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_to_dataset/3`
  (concern K, still on the facade): resolved via the still-on-facade public
  `Barkpark.Content.resolve_read_dataset_id/2`, then the NULL-tolerant
  legacy-string OR. Workspace scope rides the shared
  `Barkpark.Content.Scope.scope_to_workspace_or_global/3`. Published-id
  normalization rides the public `Barkpark.Content.published_id/1`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.Revision

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.doc_id == ^Content.published_id(doc_id) and r.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get a single revision by ID, scoped to a dataset and (optionally)
  workspace/project.

  Dataset scoping closes an intra-workspace IDOR: without it a member can read
  ANY revision in their workspace by UUID regardless of the dataset named in the
  URL. Workspace/project scoping additionally prevents cross-workspace reads of
  a guessed/leaked id. `scope_to_dataset` is NULL-tolerant (matches rows whose
  `dataset_id` is NULL but whose `dataset` STRING equals the requested one).
  """
  def get_revision(id, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    # Guard the :binary_id cast: the revision `:id` is a raw path param
    # (GET /v1/data/revision/:dataset/:id, and restore_revision/4 delegates here),
    # so a non-UUID would raise Ecto.CastError → 500. Malformed id → not_found.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        Revision
        |> where([r], r.id == ^uuid)
        |> scope_to_dataset(dataset, opts)
        |> scope_to_workspace_or_global(workspace_id, project_id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          rev -> {:ok, rev}
        end
    end
  end

  @doc """
  Restore a document to a specific revision.

  Always produces a DRAFT regardless of the revision's captured status. The
  write target is the `drafts.`-prefixed row, and `Writer.upsert_document`'s
  `Map.put_new("status", "draft")` supplies the status. Carrying `rev.status`
  verbatim would stamp a restored draft as `"published"` — making it satisfy
  every status-keyed read (wikilink `published_only`, Studio status chips)
  until the next explicit publish. Publishing stays a separate explicit action,
  matching Sanity's restore-into-draft semantics.

  `opts` is forwarded to `Barkpark.Content.upsert_document/4` so callers can
  supply lifecycle-hook context (`:source`, `:user_id`).
  """
  def restore_revision(revision_id, type, dataset, opts \\ []) do
    with {:ok, rev} <- get_revision(revision_id, dataset, opts),
         :ok <- assert_revision_dataset(rev, dataset) do
      attrs = %{
        "doc_id" => Content.draft_id(rev.doc_id),
        "title" => rev.title,
        "content" => rev.content
      }

      Content.upsert_document(type, attrs, dataset, opts)
    end
  end

  # Defence-in-depth on top of get_revision's dataset scoping: refuse to restore
  # a revision whose own `dataset` does not match the requested one, so a rev
  # from dataset A can never be re-upserted into dataset B within a workspace.
  defp assert_revision_dataset(%Revision{dataset: rev_dataset}, dataset)
       when rev_dataset == dataset,
       do: :ok

  defp assert_revision_dataset(_rev, _dataset), do: {:error, :not_found}

  # Mirrors `Barkpark.Content`'s private `scope_to_dataset/3` (concern K, still
  # on the facade). Resolves the read dataset_id through the facade's public
  # `resolve_read_dataset_id/2`, then applies the NULL-tolerant legacy-string OR.
  defp scope_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
