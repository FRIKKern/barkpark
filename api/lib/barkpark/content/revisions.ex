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

  ## Grant row narrowing (task-5fa8c834e1afa197)

  Both READ entry points — `list_revisions/4` and `get_revision/3` — thread the
  shared `Barkpark.Content.Scope.maybe_scope_to_grants/2` after the workspace
  clause, exactly as `Content.Query.get_document/4` and the analytics aggregates
  do. Without it these builders dropped `opts[:grant_scoped]`, and because the
  gate DEFAULTS that flag to false the absent call meant "do not narrow", not
  "narrow to nothing": a non-member admitted by `ResolveWorkspace`'s grant arm on
  `/w/:ws/p/:proj/v1/data/history/:dataset/:type/:doc_id` and
  `/w/:ws/p/:proj/v1/data/revision/:dataset/:id` read every revision of every
  document in the dataset — the stored snapshot's title, status and content —
  when her grant covered a single type.

  NO JOIN IS NEEDED, and none is introduced. `Scope.scope_to_grants/3` binds the
  ladder `project_id → dataset → type → doc_id` against the FIRST binding, and
  `Barkpark.Content.Revision` carries all four columns natively (stamped from the
  source document by `Broadcast.save_revision/5`, which also stamps
  `workspace_id`). The one asymmetry with `documents` is deliberate and
  tightening-only: `revisions.doc_id` is always the PUBLISHED id
  (`DraftId.published_id/1` at write time), so a grant pinned to the `doc_id`
  rung matches a revision by its published id — the same id `list_revisions/4`
  already normalizes its own lookup to.

  A MEMBER never carries the flag, so the gate is a provable no-op and both
  reads are byte-identical for her (grants only ADD access). `restore_revision/4`
  resolves through `get_revision/3` and so inherits the narrowing — a strict
  tightening on a write path. Pinned by
  `test/barkpark_web/integration/export_revision_grant_narrowing_test.exs`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.Revision

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3, maybe_scope_to_grants: 2]

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.doc_id == ^Content.published_id(doc_id) and r.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
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
  Grant narrowing (module doc) closes the same IDOR across a GRANT boundary: a
  grant-admitted non-member could otherwise read any revision in the workspace
  by UUID, whatever her grant's ladder.
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
        |> maybe_scope_to_grants(opts)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          rev -> {:ok, rev}
        end
    end
  end

  @doc """
  Resolve a document `_rev` HASH to the revision that captured it.

  [rev-hash-has-no-read] The envelope publishes `"_rev" => doc.rev` on every
  document read, and acceptance criteria cite that hash to name the exact
  revision they sealed. Until `revisions.rev` existed there was no path —
  surfaced or un-surfaced — from the hash to the content it names: this table is
  keyed by its own UUID and `get_revision/3` rejects a non-UUID outright. A
  revision a seal cited was therefore neither live nor retrievable.

  Scoping is IDENTICAL to `get_revision/3` — the same dataset clause, the same
  workspace/project clause, the same grant narrowing — so this is a new KEY on
  the existing read, never a wider one. A `_rev` a caller may not read by UUID
  stays unreadable by hash.

  Takes the NEWEST match: `revisions.rev` is not unique (the same document rev
  can be snapshotted by more than one action, e.g. a provenance tap alongside
  the write), and the newest row is the one that describes the settled state.

  LIMIT: history written before the `rev` column existed carries a NULL `rev`
  and cannot be resolved this way — the hash was never recorded, so it cannot be
  recovered. Those rows stay readable by UUID exactly as before.
  """
  def get_revision_by_rev(rev, dataset, opts \\ [])

  def get_revision_by_rev(rev, _dataset, _opts) when not is_binary(rev) or rev == "",
    do: {:error, :not_found}

  def get_revision_by_rev(rev, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.rev == ^rev)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
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
