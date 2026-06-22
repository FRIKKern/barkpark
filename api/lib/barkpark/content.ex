defmodule Barkpark.Content do
  @moduledoc """
  Context for documents and schema definitions.

  ## Draft/Published model

  Follows Sanity's convention: drafts and published are separate document rows.

    - Published document: `doc_id = "p1"`
    - Draft of same:      `doc_id = "drafts.p1"`

  Creating a document always creates a draft (`drafts.{id}`).
  Publishing copies the draft to the published ID and removes the draft.
  Editing a published doc creates a new draft alongside it.

  ## Perspectives

    - `:published` — only documents without `drafts.` prefix (public-facing)
    - `:drafts`    — prefers draft over published when both exist (studio view)
    - `:raw`       — all documents including both drafts and published
  """

  alias Barkpark.Content.{
    Analytics,
    Broadcast,
    Document,
    DraftId,
    Edge,
    Edges,
    Export,
    Forms,
    Labels,
    Lifecycle,
    Mutations,
    Papers,
    Query,
    Revisions,
    Schema,
    SchemaDefinition,
    Search,
    WriteScope,
    Writer
  }

  # ── Draft/Published helpers (extracted → Content.DraftId) ──────────────────

  defdelegate draft_id(published_id), to: DraftId
  defdelegate published_id(doc_id), to: DraftId
  defdelegate draft?(doc_id), to: DraftId

  # ── Documents ──────────────────────────────────────────────────────────────

  @doc """
  List documents by type and dataset.

  Options:
    - `:perspective`  — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter_map`   — map of field=>value filters, e.g. `%{"status" => "draft"}`
    - `:limit`        — max rows returned (default 100, max 1000, min 1)
    - `:offset`       — rows to skip (default 0)
    - `:order`        — `:updated_at_desc` (default), `:updated_at_asc`,
                        `:created_at_desc`, `:created_at_asc`

  The `:drafts` perspective merges draft/published pairs at SQL level via
  `DISTINCT ON`, so `limit` and `offset` are applied after the merge.

  Tenancy scoping (Wave 1 hard boundary):
    - `:workspace_id` — scope reads to a single workspace (nil = unscoped /
                        pre-tenancy back-compat).
    - `:project_id`   — further narrow to a single project (requires
                        `:workspace_id`; nil = workspace-wide).

  The workspace/project filter is applied IN ADDITION TO the dataset-string
  filter via `Barkpark.Content.Scope.scope_to_workspace/3`.
  """
  def list_documents(type, dataset, opts \\ []),
    do: Query.list_documents(type, dataset, opts)

  @doc """
  Fetch a single document by `{doc_id, type, dataset}`.

  Delegates to `Barkpark.Content.Query.get_document/4`.
  """
  def get_document(doc_id, type, dataset, opts \\ []),
    do: Query.get_document(doc_id, type, dataset, opts)

  @doc """
  Batch sibling of `get_document/4`: load many documents by `doc_id` in ONE
  scoped query, returned as a `%{doc_id => %Document{}}` map.

  Delegates to `Barkpark.Content.Query.get_documents_by_ids/3`.
  """
  @spec get_documents_by_ids([String.t()], String.t(), keyword()) ::
          %{optional(String.t()) => Document.t()}
  def get_documents_by_ids(doc_ids, dataset, opts \\ []),
    do: Query.get_documents_by_ids(doc_ids, dataset, opts)

  # ── Reference / codelist labels (extracted → Content.Labels) ───────────────
  #
  # Public `reference_title/4` and `codelist_label/3` keep their facade entry
  # points (explicit wrappers because `reference_title/4` carries a default
  # `opts \\ []`). The private render-opts builders delegate too, so the paper /
  # write paths inside this module call `Labels.render_opts(...)` etc.

  @doc """
  Resolve a referenced document's display title from a stored reference value.

  Delegates to `Barkpark.Content.Labels.reference_title/4`.
  """
  @spec reference_title(String.t() | nil, String.t() | nil, String.t(), keyword()) :: String.t()
  def reference_title(value, ref_type, dataset, opts \\ []),
    do: Labels.reference_title(value, ref_type, dataset, opts)

  @doc """
  Resolve a codelist CODE to its human LABEL for View-mode rendering.

  Delegates to `Barkpark.Content.Labels.codelist_label/3`.
  """
  defdelegate codelist_label(plugin, codelist_id, code), to: Labels

  @doc """
  Fetch a document with draft-first preference. Returns the draft if it
  exists, otherwise falls back to the published row, plus flags for
  whether the returned doc is the draft and whether a published version
  exists. Used by StudioLive's native editor pane — consolidated in
  Task #11 WI3 from prior duplicates (the plugin LVs that originally
  shared this helper were removed in Goal `barkpark-zdy`).

      {doc | nil, is_draft :: boolean, has_published :: boolean}
  """
  @spec fetch_doc_with_draft(String.t(), String.t(), String.t(), keyword()) ::
          {Document.t() | nil, boolean(), boolean()}
  def fetch_doc_with_draft(type, doc_id, dataset, opts \\ []),
    do: Query.fetch_doc_with_draft(type, doc_id, dataset, opts)

  # ── Form ↔ content coercion (extracted → Content.Forms) ────────────────────
  # `doc_to_form/2` `build_content/2` `upsert_draft/6` + the Classic-save
  # data-loss guard. Facade wrappers (upsert_draft carries a default arg, so an
  # explicit wrapper rather than a bare defdelegate).

  defdelegate doc_to_form(doc, schema), to: Forms
  defdelegate build_content(params, schema), to: Forms

  def upsert_draft(base_doc, type, schema, params, dataset, opts \\ []),
    do: Forms.upsert_draft(base_doc, type, schema, params, dataset, opts)

  # ── Document write path (extracted → Content.Writer, concern E) ────────────
  #
  # create / clone / upsert + the write-path helpers (envelope coercion,
  # id/rev generation, task-kind validation, initial-values + Expectation
  # scaffolding, deep-merge, dynamic-token resolution) live in
  # `Barkpark.Content.Writer`. These thin facade wrappers keep every external
  # caller (`Barkpark.Content.<fn>`) unchanged. Defaults (\\) are spelled out
  # as explicit wrappers rather than bare defdelegate.

  @doc "Validate document content against its schema. Returns {:ok, content} or {:error, errors_map}."
  def validate_document(type, title, content, dataset),
    do: Writer.validate_document(type, title, content, dataset)

  @doc """
  Create or update a document. New docs are always created as drafts.
  See `Barkpark.Content.Writer.create_document/4`.
  """
  def create_document(type, attrs, dataset, opts \\ []),
    do: Writer.create_document(type, attrs, dataset, opts)

  @doc """
  Clone a document into a fresh draft. See `Content.Writer.clone_document/4`.
  """
  @spec clone_document(map(), String.t(), String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def clone_document(doc, type, dataset, opts \\ []),
    do: Writer.clone_document(doc, type, dataset, opts)

  @doc false
  defdelegate deep_merge(a, b), to: Writer

  @doc false
  defdelegate resolve_dynamics(term), to: Writer

  @doc """
  Upsert a document — used by autosave and patch paths.
  See `Barkpark.Content.Writer.upsert_document/4`.
  """
  def upsert_document(type, attrs, dataset, opts \\ []),
    do: Writer.upsert_document(type, attrs, dataset, opts)

  # ── Publish lifecycle (extracted → Content.Lifecycle, concern F) ───────────
  #
  # publish / unpublish / discard-draft / delete moved to
  # `Barkpark.Content.Lifecycle`. Thin facade wrappers keep every external
  # caller unchanged; defaults (\\) are explicit wrappers.

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  See `Barkpark.Content.Lifecycle.publish_document/4`.
  """
  def publish_document(published_doc_id, type, dataset, opts \\ []),
    do: Lifecycle.publish_document(published_doc_id, type, dataset, opts)

  @doc """
  Unpublish: move published doc back to draft, delete published version.
  See `Barkpark.Content.Lifecycle.unpublish_document/4`.
  """
  def unpublish_document(published_doc_id, type, dataset, opts \\ []),
    do: Lifecycle.unpublish_document(published_doc_id, type, dataset, opts)

  @doc "Discard a draft without publishing. See `Content.Lifecycle.discard_draft/4`."
  def discard_draft(published_doc_id, type, dataset, opts \\ []),
    do: Lifecycle.discard_draft(published_doc_id, type, dataset, opts)

  @doc """
  Delete both the published and draft variants of a document.
  See `Barkpark.Content.Lifecycle.delete_document/4`.
  """
  def delete_document(doc_id, type, dataset, opts \\ []),
    do: Lifecycle.delete_document(doc_id, type, dataset, opts)

  # ── Batch mutations (extracted → Content.Mutations, concern H) ─────────────
  #
  # `apply_mutations/3` (transaction + broadcast-deferral + per-op dispatch)
  # moved to `Barkpark.Content.Mutations`. Thin facade wrapper preserves the
  # default arg.

  @doc """
  Apply a batch of mutations atomically.
  See `Barkpark.Content.Mutations.apply_mutations/3`.
  """
  def apply_mutations(mutations, dataset, opts \\ []),
    do: Mutations.apply_mutations(mutations, dataset, opts)

  # ── Content-graph edges (extracted → Content.Edges, concern I) ─────────────
  #
  # Reference discovery / disconnect + content-edge CRUD moved to
  # `Barkpark.Content.Edges` (which sits ABOVE the `Content.Edge`/
  # `Content.Graph` schema modules). Thin facade wrappers keep every external
  # caller unchanged; defaults (\\) are explicit wrappers.

  @doc """
  Find all documents that reference a given document ID.
  See `Barkpark.Content.Edges.find_referencing_docs/3`.
  """
  def find_referencing_docs(doc_id, dataset, opts \\ []),
    do: Edges.find_referencing_docs(doc_id, dataset, opts)

  @doc """
  Remove all references to a document ID from other documents.
  See `Barkpark.Content.Edges.disconnect_references/3`.
  """
  def disconnect_references(doc_id, dataset, opts \\ []),
    do: Edges.disconnect_references(doc_id, dataset, opts)

  @doc """
  Extract the outbound reference-field edges of a document.
  See `Barkpark.Content.Edges.extract_edges/2`.
  """
  @spec extract_edges(map() | Document.t(), keyword()) :: [
          %{
            from_id: String.t(),
            to_id: String.t(),
            kind: String.t(),
            field: String.t(),
            refType: String.t() | nil,
            dangling: boolean()
          }
        ]
  def extract_edges(doc, opts \\ []), do: Edges.extract_edges(doc, opts)

  @doc """
  Insert (or REPLACE) a single content edge by its `(from_id, to_id, kind)`
  triple. See `Barkpark.Content.Edges.add_edge/4`.
  """
  @spec add_edge(binary(), binary(), String.t(), map()) ::
          {:ok, Edge.t()} | {:error, :no_target} | {:error, Ecto.Changeset.t()}
  def add_edge(from_id, to_id, kind, attrs \\ %{}),
    do: Edges.add_edge(from_id, to_id, kind, attrs)

  @doc """
  Insert/replace a batch of edge maps. See `Barkpark.Content.Edges.add_edges/2`.
  """
  def add_edges(edges, opts \\ []), do: Edges.add_edges(edges, opts)

  @doc "Outbound edges of a document id. See `Content.Edges.list_outbound_edges/2`."
  def list_outbound_edges(from_id, opts \\ []), do: Edges.list_outbound_edges(from_id, opts)

  @doc "Inbound edges of a document id. See `Content.Edges.list_inbound_edges/2`."
  def list_inbound_edges(to_id, opts \\ []), do: Edges.list_inbound_edges(to_id, opts)

  @doc """
  The projection SOURCE corpus. See `Barkpark.Content.Edges.corpus_edges/3`.
  """
  @spec corpus_edges(String.t(), String.t(), keyword()) :: [map()]
  def corpus_edges(type, dataset, opts \\ []), do: Edges.corpus_edges(type, dataset, opts)

  # ── Scope resolution (extracted → Content.WriteScope) ─────────────────────
  #
  # Tenancy scope stamping/resolution + the lifecycle-hook helpers moved to
  # Barkpark.Content.WriteScope (concern K). These thin wrappers keep every
  # external caller (Media, Webhooks, Papers, Schema, the search retrievers)
  # unchanged. The `read_default_project_id/1` default (\\) is spelled out as
  # explicit clauses rather than a bare defdelegate.

  @doc false
  defdelegate put_scope_attrs(attrs, opts), to: WriteScope

  @doc false
  defdelegate resolve_read_dataset_id(dataset, opts), to: WriteScope

  @doc false
  def read_default_project_id, do: WriteScope.read_default_project_id([])
  @doc false
  def read_default_project_id(opts), do: WriteScope.read_default_project_id(opts)

  # ── Schema Definitions (extracted → Content.Schema) ───────────────────────
  #
  # All schema-definition reads/writes, SDK serialization, hashing, and the
  # dataset catalog moved to Barkpark.Content.Schema. These thin wrappers keep
  # every external caller (SchemaController, Bootstrap, capabilities, SDK
  # serialization) unchanged. Defaults (\\) are spelled out as explicit
  # wrappers rather than bare defdelegate.

  @doc """
  The default dataset for a bare Studio landing (no `:dataset` in the URL).
  See `Barkpark.Content.Schema.default_dataset/0`.
  """
  @spec default_dataset() :: String.t()
  def default_dataset, do: Schema.default_dataset()

  @doc """
  Return the dataset slugs OWNED by a project, sorted alphabetically.
  See `Barkpark.Content.Schema.list_datasets/1`.
  """
  def list_datasets(project_id \\ :default), do: Schema.list_datasets(project_id)

  def list_schemas(dataset, opts \\ []), do: Schema.list_schemas(dataset, opts)

  def get_schema(name, dataset, opts \\ []), do: Schema.get_schema(name, dataset, opts)

  @doc """
  Resolve the full Expectation for a schema definition.
  See `Barkpark.Content.Schema.resolve_expectation/1`.
  """
  @spec resolve_expectation(SchemaDefinition.t()) :: %{layout: [map()], prefill: map()}
  def resolve_expectation(%SchemaDefinition{} = schema),
    do: Schema.resolve_expectation(schema)

  def upsert_schema(attrs, dataset, opts \\ []), do: Schema.upsert_schema(attrs, dataset, opts)

  def delete_schema(name, dataset, opts \\ []), do: Schema.delete_schema(name, dataset, opts)

  @doc """
  Whether the schema's public-read gate is open for `type` in `dataset`.
  See `Barkpark.Content.Schema.schema_public?/3`.
  """
  def schema_public?(type, dataset, opts \\ []), do: Schema.schema_public?(type, dataset, opts)

  @doc """
  Returns the union of CORS origin allow-lists across all schemas in the dataset.
  See `Barkpark.Content.Schema.allowed_origins_for_dataset/2`.
  """
  @spec allowed_origins_for_dataset(String.t(), keyword()) :: [String.t()]
  def allowed_origins_for_dataset(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.allowed_origins_for_dataset(dataset, opts)

  def schema_hash_for_dataset(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.schema_hash_for_dataset(dataset, opts)

  @doc """
  Deterministic 16-char hex content hash of a single schema definition.
  See `Barkpark.Content.Schema.schema_hash_for_schema/1`.
  """
  def schema_hash_for_schema(%SchemaDefinition{} = schema),
    do: Schema.schema_hash_for_schema(schema)

  @doc """
  Render a single schema in SDK envelope shape.
  See `Barkpark.Content.Schema.serialize_schema_for_sdk/1`.
  """
  def serialize_schema_for_sdk(%SchemaDefinition{} = schema),
    do: Schema.serialize_schema_for_sdk(schema)

  @doc """
  List every schema in a dataset in SDK envelope shape, plus a
  top-level `datasetSchemaHash`. See `Barkpark.Content.Schema.list_schemas_for_sdk/2`.
  """
  def list_schemas_for_sdk(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.list_schemas_for_sdk(dataset, opts)

  def schema_hash_for_all_datasets, do: Schema.schema_hash_for_all_datasets()

  # ── Analytics (extracted → Content.Analytics) ─────────────────────────────

  @doc "Count documents grouped by type, with published/draft breakdown."
  def document_stats(dataset, opts \\ []), do: Analytics.document_stats(dataset, opts)

  @doc "Count total documents in a dataset."
  def total_documents(dataset, opts \\ []), do: Analytics.total_documents(dataset, opts)

  @doc "Recent mutation activity — last N events."
  def recent_activity(dataset, opts \\ []), do: Analytics.recent_activity(dataset, opts)

  # ── PubSub ────────────────────────────────────────────────────────────────
  #
  # Broadcasts are DEFERRED when we're inside an Ecto transaction (e.g.
  # apply_mutations/2). They land in the process dict and are flushed by
  # flush_deferred_broadcasts/0 after the transaction commits. If the
  # transaction rolls back, clear_deferred_broadcasts/0 discards them
  # (no ghost events on the SSE stream). Direct writes outside a
  # transaction broadcast immediately — same behaviour as before.

  @doc """
  Broadcast an ALREADY-PERSISTED document mutation on the canonical PubSub
  topics — the public seam for writers that bypass `tap_broadcast/5` (the
  task lifecycle paths in `Barkpark.Tasks`, `Tasks.TtlSweeper`,
  `Tasks.Compactor`, which mutate `documents` rows via CAS-guarded
  `Repo.update_all` and write their own `mutation_events` rows).

  Emits the SAME message shape `tap_broadcast/5` emits, on the SAME three
  topics, so every existing subscriber (the `/v1/data/listen/:dataset` SSE
  controller, StudioLive's list + per-doc handlers, the nextjs revalidate
  consumer) consumes task-op events with zero changes:

    * `documents:<dataset>`                      — `{:document_changed, msg}`
    * `doc:ws:<ws>:<dataset>:<type>:<pubid>`     — `{:doc_updated, msg}`
    * `documents:ws:<workspace_id>:<dataset>`    — `{:document_changed, msg}`
      (only when the doc carries a workspace_id)

  Extracted to `Content.Broadcast`, which is the single owner of the topic
  shapes — callers never build topic strings themselves.

  ## Options
    * `:event_id` — the caller's `mutation_events` row id. REQUIRED for the
      SSE path: the listen controller pattern-matches on `event_id` and
      drops messages without one (it's also the SSE `id:` used for
      Last-Event-ID resume).
    * `:previous_rev` — the rev the caller observed before its CAS write.

  `mutation` is the caller's mutation kind string (e.g. `"task.claimed"`) —
  it matches the `mutation` column of the caller's `mutation_events` row, so
  a live SSE frame and a Last-Event-ID replayed frame carry the same kind.

  IMPORTANT: call AFTER the writing transaction commits. This broadcasts
  immediately (no transaction-deferral) — firing it inside an open
  transaction would let subscribers read state that may still roll back.
  """
  @spec broadcast_document_mutation(Document.t(), String.t(), keyword()) :: :ok
  def broadcast_document_mutation(%Document{} = doc, mutation, opts \\ [])
      when is_binary(mutation),
      do: Broadcast.broadcast_document_mutation(doc, mutation, opts)

  # ── Search (extracted → Content.Search) ───────────────────────────────────

  @doc "Search documents by title using the QueryPipeline. Returns `{docs, count, meta}`."
  def search_documents(query, dataset, opts \\ []),
    do: Search.search_documents(query, dataset, opts)

  # ── Export (extracted → Content.Export) ────────────────────────────────────

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []), do: Export.export_stream(dataset, opts)

  # ── Revisions (extracted → Content.Revisions) ─────────────────────────────

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []),
    do: Revisions.list_revisions(doc_id, type, dataset, opts)

  @doc "Get a single revision by ID, scoped to a dataset and (optionally) workspace/project."
  def get_revision(id, dataset, opts \\ []), do: Revisions.get_revision(id, dataset, opts)

  @doc "Restore a document to a specific revision."
  def restore_revision(revision_id, type, dataset, opts \\ []),
    do: Revisions.restore_revision(revision_id, type, dataset, opts)

  # ── Papers — context functions (extracted → Content.Papers, Step 10) ───────
  #
  # The `type:"paper"` feature (the Bulldocs surface) lives in
  # `Barkpark.Content.Papers`. These facade entries keep every external caller
  # (`Barkpark.Content.<fn>`) unchanged. Explicit thin wrappers preserve the
  # `\\` default args; bare delegations cover the no-default arities.

  @doc "The default dataset papers live under. See `Content.Papers`."
  def paper_default_dataset, do: Papers.paper_default_dataset()

  @doc "The document type discriminator for papers. See `Content.Papers`."
  def paper_type, do: Papers.paper_type()

  @doc "Per-doc PubSub topic for a paper, scoped to the owning workspace. See `Content.Papers`."
  def paper_topic(slug, workspace_id, dataset \\ Papers.paper_default_dataset()),
    do: Papers.paper_topic(slug, workspace_id, dataset)

  @doc "Per-doc PubSub topic for an ordinary document, scoped to the owning workspace."
  defdelegate doc_topic(pubid, type, workspace_id, dataset), to: Broadcast

  @doc "Fetch a paper (a type-\"paper\" document) by slug. See `Content.Papers`."
  def get_paper(slug, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.get_paper(slug, dataset, opts)

  @doc "Resolve a paper for the PUBLIC, unauthenticated surface. See `Content.Papers`."
  def get_public_paper(slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.get_public_paper(slug, dataset)

  @doc "Resolve a document of `type` by `slug` for a PUBLIC surface. See `Content.Papers`."
  def get_public_document(type, slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.get_public_document(type, slug, dataset)

  @doc "The paper's block list, or `nil` for an HTML-only paper. See `Content.Papers`."
  def paper_blocks(slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.paper_blocks(slug, dataset)

  @doc "Resolve the block list for editing a document. See `Content.Papers`."
  defdelegate resolve_blocks_for_edit(doc, type, dataset), to: Papers

  @doc "The expected fields still recommendable for a document's block list. See `Content.Papers`."
  def available_expected_fields(blocks, expectation, schema \\ nil),
    do: Papers.available_expected_fields(blocks, expectation, schema)

  @doc "True when a HARD cap blocks inserting another bound block. See `Content.Papers`."
  defdelegate expected_field_blocked?(blocks, expectation, field_name), to: Papers

  @doc "Upsert a paper keyed by `{dataset, slug}` and broadcast a whole-HTML frame. See `Content.Papers`."
  defdelegate upsert_paper(attrs), to: Papers

  @doc "Apply a single portable-doc op to a paper's block list. See `Content.Papers`."
  def apply_paper_block_op(slug, op, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.apply_paper_block_op(slug, op, dataset, opts)

  @doc "Apply a LIST of portable-doc ops to a paper's block list atomically. See `Content.Papers`."
  def apply_paper_block_ops(slug, ops, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.apply_paper_block_ops(slug, ops, dataset, opts)

  @doc "Apply a single portable-doc op to any Expectation-bearing document. See `Content.Papers`."
  def apply_document_block_op(doc_id, type, op, dataset, opts \\ []),
    do: Papers.apply_document_block_op(doc_id, type, op, dataset, opts)
end
