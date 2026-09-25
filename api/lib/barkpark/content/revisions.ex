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

  ## Retention: INDEFINITE, and deliberately so (loop-low-history-offset-retention)

  There is no age sweep, no per-document cap, and no archival tier. A revision
  row lives until the SCOPE that owns it is deleted. That is the whole policy,
  and it is written here because "how long is history kept" had no answer
  anywhere and the compactor had already guessed at one.

  The enumeration behind that claim: every `Repo.delete_all/1` and
  `Repo.delete/1` call site in `api/lib` was listed, and none names
  `Barkpark.Content.Revision` or the `revisions` table. The only paths that
  remove a revision row are the three scope foreign keys — `workspace_id` /
  `project_id` / `dataset_id` — flipped to `ON DELETE CASCADE` by migration
  `20260527160000_cascade_content_on_scope_delete`. So deleting a workspace,
  project or dataset takes its revisions along with its documents, and nothing
  else ever does.

  Two consequences worth stating, because they are what a caller actually needs:

    * Deleting a DOCUMENT does not delete its revisions. `revisions.doc_id` is
      a plain string with no FK to `documents`, so the history of a deleted
      document stays listable and `restore_revision/4` can bring it back. The
      `action: "delete"` entry is itself a revision.
    * The compaction snapshot written by the Tasks plugin's compactor (action
      `"compaction_snapshot"`) is an ordinary revision row and inherits exactly
      this retention. Nothing prunes it. That module's note about "the existing
      revision-pruning sweep" described a sweep that has never existed; it has
      been corrected.

  A bounded policy, if one is ever wanted, is a NEW decision with a NEW
  migration — never a behaviour to assume is already running. Pinned by
  `test/barkpark/content/revision_retention_and_paging_test.exs`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.Revision

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3, maybe_scope_to_grants: 2]

  @doc """
  List revisions for a document, newest first.

  ## Options

    * `:limit` — page size (default 50).
    * `:offset` — how many of the newest revisions to skip (default 0).
      Negative values clamp to 0.

  ### Why the order key is a PAIR (loop-low-history-offset-retention)

  `revisions.inserted_at` is NOT unique: `Broadcast.save_revision/5` stamps it
  from the write, and a single mutation batch (or two writers landing in the
  same microsecond) produces rows that tie. Postgres gives no stable order
  among tied rows, so a bare `desc: inserted_at` + OFFSET can return the SAME
  row on two consecutive pages and never return another — a caller paging the
  whole history silently loses restorable evidence it was never told about.

  Ordering by `{inserted_at, id}` makes the sort total (`id` is the primary
  key, so the pair is unique by construction), which is what makes OFFSET a
  contract rather than a suggestion. The first page is unchanged for any
  document whose revisions have distinct timestamps.
  """
  def list_revisions(doc_id, type, dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.doc_id == ^Content.published_id(doc_id) and r.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> offset(^offset)
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
    # so a non-UUID would raise Ecto.Query.CastError → an opaque 400. Malformed
    # id → not_found.
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
    # WHY THIS ARM IS THE SAME ARM, not a new opening. `get_revision/3` (:103)
    # and `list_revisions/4` (:68) already apply these exact three clauses —
    # dataset, workspace-or-global, grants — verified line by line. This adds a
    # new KEY (the rev hash) to an existing read; it widens nothing.
    #
    # NARROWING ONLY THIS ARM WOULD CLOSE NOTHING. Its only caller is
    # `history_controller.ex:99`, which falls back here when the id is not a
    # UUID, passing the SAME `opts` it hands `get_revision/3` five lines above.
    # Fail-closing the hash path alone would make one controller answer one
    # request shape two ways depending on whether the caller typed a UUID or a
    # hash, while the UUID door stayed global — so anything made unreadable by
    # hash stays readable by id. The confidentiality boundary is set by
    # `get_revision/3`, not here.
    #
    # If the fail-open arm is wrong, it is wrong at all THREE call sites and at
    # the UUID door too. That is a reachability review of its own, filed as a
    # row rather than smuggled in behind the newest line.
    # global-read: same clauses as get_revision/3; a new key on an existing read, and its one caller shares opts with the UUID door
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
