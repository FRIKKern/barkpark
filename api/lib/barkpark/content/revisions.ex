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
  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.Document
  alias Barkpark.Content.MutationEvent
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

  @doc """
  Resolve a `_rev` HASH to the stored envelope snapshot of that revision.

  ## Why this exists (task-8d4b1f2c7a0e3591)

  `documents.rev` is the opaque 32-hex content hash every read surface stamps as
  the envelope's `_rev`, and it is the token acceptance criteria, seals and CAS
  guards actually CITE. Until now nothing could turn one back into content:
  `get_revision/3` keys on the `revisions` row UUID, `revisions` carries no
  `rev` column at all, and a caller holding a `_rev` from a sealed paper had no
  read anywhere in the API that would resolve it. A cited revision was therefore
  neither live nor retrievable the moment the document moved on.

  The mapping was already in the database, merely unsurfaced. Every revision-
  producing write runs `Broadcast.tap_broadcast/7`, which persists BOTH a
  `revisions` row AND a `mutation_events` row inside the SAME transaction, and
  the event row carries `rev` (the hash) plus `document` — the full
  `Envelope.render(doc, nil, :internal)` snapshot as of that rev. `mutation_events`
  is never pruned (see `Content.EventLog`: "the backlog grows without bound"), so
  this read is fully RETROSPECTIVE — it resolves hashes minted long before this
  function existed.

  ## Shape

  Returns `{:ok, %{rev:, doc_id:, type:, dataset:, action:, timestamp:, document:}}`
  where `document` is the RAW stored envelope. Redaction is the CALLER'S job and
  is not optional: the snapshot is an `:internal` render, so it holds
  `private` / `owner_only` / `readable_by` fields in the clear.
  `BarkparkWeb.HistoryController.show/2` routes it through
  `Barkpark.Content.Envelope.redact/3` — the same chokepoint the SSE delete-replay
  path uses on this same column, and the same one the UUID arm uses on
  `rev.content`.

  ## Scope

  Identical to `get_revision/3`, rung for rung: dataset (NULL-tolerant legacy
  string OR), workspace/project, and `maybe_scope_to_grants/2`. `mutation_events`
  carries `project_id`, `dataset`, `type` and `doc_id` natively, so the grant
  ladder binds without a join exactly as it does on `revisions`.

  A hash is only ever matched against a 32-char lowercase hex token, so a
  non-hash path param can never widen the query.
  """
  def get_revision_by_rev(rev, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    if rev_hash?(rev) do
      MutationEvent
      |> where([e], e.rev == ^rev)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> maybe_scope_to_grants(opts)
      # A rev is unique per write, but a re-emitted event would otherwise make
      # the read non-deterministic; newest wins, matching list_revisions' order.
      |> order_by([e], desc: e.id)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil ->
          {:error, :not_found}

        event ->
          {:ok,
           %{
             rev: event.rev,
             doc_id: event.doc_id,
             type: event.type,
             dataset: event.dataset,
             action: event.mutation,
             timestamp: event.inserted_at,
             document: event.document || %{}
           }}
      end
    else
      {:error, :not_found}
    end
  end

  # `Content.Writer.generate_rev/0` and every sibling mint
  # `:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)` — 32 lowercase
  # hex chars. Anything else is not a rev and must not reach the query.
  defp rev_hash?(rev) when is_binary(rev), do: Regex.match?(~r/\A[0-9a-f]{32}\z/, rev)
  defp rev_hash?(_), do: false

  @doc """
  Replace a document's content AND append its revision-history entry inside ONE
  transaction. The ONLY sanctioned way for an offline/migration writer to
  rewrite a document that is already published.

  ## The hole this closes (task-8d4b1f2c7a0e3591)

  The live write path cannot lose history: `Content.Writer` / `Content.Lifecycle`
  results are tapped by `Broadcast.tap_broadcast/7`, which appends a `revisions`
  row in the mutating transaction. The OFFLINE corpus rewriters did not go
  through it. `Papers.BackfillBlockIds.persist/2`,
  `Papers.DoctrineBackfill.persist/2` and `Papers.CompositionMigration.persist/2`
  each built a `Document.changeset/2` and called a BARE `Repo.update/1` — no
  broadcast, and, crucially, no revision. Each is driven by a Mix task
  (`mix barkpark.paper.backfill_block_ids` / `.doctrine_backfill` /
  `.composition_migrate`) that sweeps EVERY `type:"paper"` row across every
  workspace, project and dataset in one pass.

  So a single `--apply` run could replace the blocks, the cached `body_html`, the
  projected body and (DoctrineBackfill) the row title of dozens of ALREADY-
  PUBLISHED papers in seconds, bump `documents.rev` so every rev-keyed consumer
  saw a new hash, and leave `bp doc history` showing NOTHING between the last
  human edit and the rewrite. After the fact a legitimate migration and an
  accidental clobber were literally indistinguishable — the corpus held no row
  that said either had happened.

  ## The contract

  * The `Repo.update` and the `Revision` insert share one `Repo.transaction/1`.
    A writer cannot commit content without committing history: a failed revision
    insert ROLLS THE CONTENT BACK. This deliberately inverts
    `Broadcast.save_revision/5`'s own log-and-continue policy, which is correct
    for a live edit (losing an audit row is better than failing a user's write)
    and wrong here (the whole point of a migration is that it is auditable).
  * `:action` is REQUIRED and must name the writer, e.g.
    `"migrate:doctrine_backfill"`. It lands in `revisions.action`, which
    `GET /v1/data/history/...` already renders, so the history entry SAYS what
    rewrote the paper. No schema change is needed to carry the reason.
  * `:actor_user_id` is optional and stamped verbatim (nil for an unattended
    Mix run) — the same column the live path threads from `ctx.user_id`.

  Returns `{:ok, %Document{}}` or `{:error, term}`.
  """
  def update_document_with_history(%Document{} = doc, attrs, opts) do
    action = Keyword.fetch!(opts, :action)
    actor_user_id = Keyword.get(opts, :actor_user_id)

    Repo.transaction(fn ->
      with {:ok, updated} <- doc |> Document.changeset(attrs) |> Repo.update(),
           {:ok, _revision} <-
             Broadcast.save_revision(
               updated,
               updated.type,
               updated.dataset,
               action,
               actor_user_id
             ) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
