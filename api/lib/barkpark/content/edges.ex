defmodule Barkpark.Content.Edges do
  @moduledoc """
  The content-graph EDGE concern (I) — reference discovery / disconnect plus
  the content-edge CRUD that sits ABOVE the `Content.Edge`/`Content.Graph`
  schema modules: `extract_edges/2` (schema-driven reference-field walk),
  `add_edge`/`add_edges` (slug→`documents.id` resolution + upsert),
  `list_outbound_edges`/`list_inbound_edges`, and `corpus_edges`.

  Extracted from `Barkpark.Content` (decomposition Step 13, concern I).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; reads (`get_document`/`get_schema`/`list_schemas`/
  `list_documents`) are called back through `Barkpark.Content.*`, rev
  generation through `Content.Writer`.
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, Document, DraftId, SchemaDefinition, Writer, WriteScope}

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3, scope_to_workspace: 3]

  @doc """
  Find all documents that reference a given document ID.

  `opts` may carry `:workspace_id` / `:project_id`; when present the schema
  scan and the per-type document scan are scoped to that tenant so the
  reference search never crosses the workspace boundary (barkpark-af50).
  Callers that pass no scope keep the explicit-global behaviour.
  """
  def find_referencing_docs(doc_id, dataset, opts \\ []) do
    pub_id = DraftId.published_id(doc_id)
    schemas = Content.list_schemas(dataset, opts)

    # Find all schema fields that are references
    ref_fields =
      for schema <- schemas,
          field <- schema.fields,
          field["type"] == "reference",
          do: {schema.name, field["name"]}

    # Search each type for docs that reference this ID. The predicate
    # (`content->>field == pub_id`) is pushed into SQL via the `:filter_map`
    # eq op so the DB returns ONLY the referencing rows — was a full
    # load-all-of-type per reference field followed by an in-memory
    # Enum.filter (barkpark-sji2). Scope opts (workspace/project/dataset) stay
    # threaded as before. limit: 1000 so a high fan-in reference is not
    # truncated by the default 100-row cap.
    Enum.flat_map(ref_fields, fn {type_name, field_name} ->
      ref_opts =
        opts
        |> Keyword.put(:perspective, :raw)
        |> Keyword.put(:filter_map, %{field_name => pub_id})
        |> Keyword.put_new(:limit, 1000)

      Content.list_documents(type_name, dataset, ref_opts)
      |> Enum.map(fn doc ->
        %{doc_id: doc.doc_id, type: type_name, title: doc.title, field: field_name}
      end)
    end)
  end

  @doc """
  Remove all references to a document ID from other documents.

  `opts` may carry `:workspace_id` / `:project_id` — threaded into both the
  referencing-doc scan and the per-doc read so the disconnect stays inside the
  tenant boundary (barkpark-af50).

  ## arrayOf-aware (the blast-radius fix)

  The referencing-source set is the UNION of two probes, so it matches the
  Studio guard modal exactly while staying robust when edges are not yet
  materialised:

    * the scalar SQL scan `find_referencing_docs/3` (`content->>field == pub_id`)
      — finds scalar `reference` referencers WITHOUT depending on the
      `content_edges` projection (the projector is async / `:manual` in tests);
      and
    * `Content.Graph.reverse_referencers/2` — the arrayOf-aware inbound-edge
      query over `content_edges` (materialised in Phase 2) — finds referencers
      via `arrayOf`-of-`reference` fields like `task.attachments`.

  The previous path built its `ref_fields` from `field["type"] == "reference"`
  ONLY, so it silently skipped arrayOf referencers: the guard modal warned about
  them (it probes via `reverse_referencers`) but the disconnect never acted on
  them, leaving those references dangling after the doc was unpublished anyway —
  defeating the disconnect remediation for the headline arrayOf case. This
  closes the gap: for each referencing source we strip the target from BOTH
  scalar `reference` fields (delete the field) AND `arrayOf`-of-`reference`
  fields (`List.delete` the element, keeping the array's other references).
  """
  def disconnect_references(doc_id, dataset, opts \\ []) do
    pub_id = DraftId.published_id(doc_id)

    scalar_refs =
      find_referencing_docs(doc_id, dataset, opts)
      |> Enum.map(fn ref -> {ref.doc_id, ref.type} end)

    array_refs =
      Barkpark.Content.Graph.reverse_referencers(pub_id, [dataset: dataset] ++ opts)
      |> Enum.map(fn ref -> {ref[:from_doc_id] || ref[:from_id], ref[:type]} end)

    # Distinct referencing sources — a source can reference the target via
    # several edges (a scalar `rel` AND an `arrayOf` `attachments`), and the two
    # probes can both surface the same scalar source; we load + rewrite each
    # source doc once, stripping the id from every matching field in one update.
    (scalar_refs ++ array_refs)
    |> Enum.reject(fn {ref_doc_id, type} -> is_nil(ref_doc_id) or is_nil(type) end)
    |> Enum.uniq()
    |> Enum.each(fn {ref_doc_id, type} ->
      disconnect_one_source(ref_doc_id, type, pub_id, dataset, opts)
    end)
  end

  # Strip every reference to `target_pub_id` out of one referencing source doc,
  # across BOTH scalar `reference` fields and `arrayOf`-of-`reference` fields.
  defp disconnect_one_source(ref_doc_id, type, target_pub_id, dataset, opts) do
    with {:ok, schema} <- Content.get_schema(type, dataset),
         {:ok, doc} <- Content.get_document(ref_doc_id, type, dataset, opts) do
      content = doc.content || %{}
      updated_content = strip_reference_fields(content, schema.fields, target_pub_id)

      if updated_content != content do
        prev_rev = doc.rev

        doc
        |> Document.changeset(%{"content" => updated_content, "rev" => Writer.generate_rev()})
        |> Repo.update()
        |> Broadcast.tap_broadcast(dataset, type, "update", prev_rev)
      end

      :ok
    else
      _ -> :ok
    end
  end

  # Walk the schema fields and remove `target_pub_id` from each reference-bearing
  # field of `content`. Scalar `reference` whose value coalesces to the target →
  # delete the key. `arrayOf` of `reference` → keep every element that is NOT the
  # target (published-coalesced compare), so OTHER references in the array
  # survive. All other fields pass through untouched.
  defp strip_reference_fields(content, fields, target_pub_id) do
    Enum.reduce(fields, content, fn field, acc ->
      name = field["name"]
      value = Map.get(acc, name)

      cond do
        field["type"] == "reference" and is_binary(value) and
            DraftId.published_id(value) == target_pub_id ->
          Map.delete(acc, name)

        get_in(field, ["of", "type"]) == "reference" and is_list(value) ->
          kept =
            Enum.reject(value, fn v ->
              is_binary(v) and DraftId.published_id(v) == target_pub_id
            end)

          if kept == value, do: acc, else: Map.put(acc, name, kept)

        true ->
          acc
      end
    end)
  end

  # ── Content graph edges (reference-field extraction + CRUD) ─────────────────
  #
  # extract_edges/2 walks a document's schema reference fields (scalar AND
  # arrayOf-of-reference) and emits one raw edge per target. from_id/to_id are
  # ALWAYS published-coalesced (published_id/1) so keys are publish-stable and a
  # draft is never a from_id. Dangling is computed here at READ time — there is
  # no dangling column (the to_id FK makes a dangling edge unstorable; see
  # `Barkpark.Content.Edge` moduledoc). The closest live precedents are the
  # scalar-only find_referencing_docs/3 and the untyped reference_title/4.

  @doc """
  Extract the outbound reference-field edges of a document.

  For the doc's schema (`list_schemas/2` → matched by `doc.type`) enumerate
  BOTH:

    * scalar fields where `f["type"] == "reference"` — value is
      `doc.content[field]`, refType `f["refType"]` (MAY be nil); and
    * arrayOf fields where `get_in(f, ["of", "type"]) == "reference"` — value is
      `List.wrap(doc.content[field])` (one edge per element), refType
      `get_in(f, ["of", "refType"])` (MAY be nil).

  Each raw target value becomes one edge map with `from_id` =
  `published_id(doc.doc_id)`, `to_id` = `published_id(target)`. `dangling` is
  resolved per target via `resolve_target_existence/4` (typed `get_document/4`
  when refType is a non-empty binary; type-agnostic `Repo.exists?` when refType
  is nil/empty — NEVER `get_document` with a nil type, which would short-circuit
  to `:not_found` and false-flag every untyped ref). Resolution runs under the
  `:published` lens (mirrors anonymous reads); a target whose published twin
  does not yet exist is reported dangling.

  Pure of plugins — reads only core schema reference fields, so it still emits
  core edges with `Application.put_env(:barkpark, :plugins, [])` (fresh-install
  invariant). Resolves EACH target → O(edges) DB round-trips; the Phase-3
  projector runs it off the request path.

  Returns `[%{from_id, to_id, kind, field, refType, dangling}]`. `kind` is the
  source reference field's NAME (e.g. `"dependencies"`, `"intentions"`,
  `"related"`) so distinct reference fields become distinct edge kinds in
  /v1/graph; plugin-projected kinds (Phase 3) arrive via the registry
  collector, not this function.
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
  def extract_edges(doc, opts \\ []) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    type = Map.get(doc, :type) || Map.get(doc, "type")
    dataset = Map.get(doc, :dataset) || Map.get(doc, "dataset")
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}

    from_id = DraftId.published_id(doc_id)

    schema =
      dataset
      |> Content.list_schemas(opts)
      |> Enum.find(fn s -> s.name == type end)

    case schema do
      nil ->
        []

      %SchemaDefinition{fields: fields} ->
        fields
        |> Enum.flat_map(fn field -> extract_field_edges(field, content) end)
        |> Enum.map(fn {raw_target, field_name, ref_type} ->
          to_id = DraftId.published_id(raw_target)

          dangling =
            not resolve_target_existence(to_id, ref_type, dataset, opts)

          %{
            from_id: from_id,
            to_id: to_id,
            # kind IS the source reference field's name (graph-edge-seam): a
            # `dependencies` ref → kind "dependencies", `intentions` → "intentions",
            # `related` → "related". This makes distinct reference fields distinct
            # edge kinds in /v1/graph (bp-graph.js colours by kind) WITHOUT a
            # via_field column or API change — the kind column already surfaces.
            # Was the generic "references" for every field. Plugin-projected kinds
            # (Phase 3) arrive via the registry collector, not this function.
            kind: field_name,
            field: field_name,
            refType: ref_type,
            dangling: dangling
          }
        end)
    end
  end

  # Scalar reference field → at most one {raw_target, field_name, ref_type}.
  defp extract_field_edges(%{"type" => "reference"} = field, content) do
    field_name = field["name"]
    ref_type = field["refType"]

    case Map.get(content, field_name) do
      value when is_binary(value) and value != "" ->
        [{value, field_name, ref_type}]

      _ ->
        []
    end
  end

  # arrayOf-of-reference field → one entry per non-blank element (bare-id
  # string array, the task.attachments shape).
  defp extract_field_edges(
         %{"type" => "arrayOf", "of" => %{"type" => "reference"} = of} = field,
         content
       ) do
    field_name = field["name"]
    ref_type = of["refType"]

    content
    |> Map.get(field_name)
    |> List.wrap()
    |> Enum.filter(fn v -> is_binary(v) and v != "" end)
    |> Enum.map(fn value -> {value, field_name, ref_type} end)
  end

  defp extract_field_edges(_field, _content), do: []

  # The SHARED resolve-and-dangling helper (gap #2). TWO branches that MUST
  # agree on lens (:published) + scope so a typed and an untyped ref to the same
  # target never disagree:
  #
  #   (i)  refType is a non-empty binary → typed get_document/4; resolvable
  #        unless it returns {:error, :not_found}.
  #   (ii) refType is nil OR "" → DO NOT call get_document with a nil type
  #        (get_document/4 short-circuits to :not_found on a nil type and would
  #        false-positive EVERY untyped ref). Instead run a type-agnostic
  #        existence query — present? under the :published lens means
  #        resolvable.
  #
  # BOTH branches share the :published lens: the typed branch resolves only the
  # published row (get_document/4 matches `doc_id == to_id` where to_id is
  # already published-coalesced), and the untyped branch matches the published
  # id ONLY — NOT the `drafts.` twin. A draft-only target (no published twin)
  # is therefore dangling under EITHER branch, so a typed ref and an untyped ref
  # to the same target never disagree on dangling (gap #2 contract). This is
  # why we do NOT copy reference_title/4's `or doc_id == draft` clause —
  # reference_title intentionally falls back to the draft twin for a cosmetic
  # title, which is the WRONG lens for published-dangling.
  #
  # Returns true when the target is resolvable (NOT dangling).
  @spec resolve_target_existence(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          boolean()
  defp resolve_target_existence(to_id, ref_type, dataset, opts)
       when is_binary(ref_type) and ref_type != "" do
    case Content.get_document(to_id, ref_type, dataset, opts) do
      {:ok, _doc} -> true
      {:error, :not_found} -> false
    end
  end

  defp resolve_target_existence(to_id, _ref_type, dataset, opts) do
    pub_id = DraftId.published_id(to_id)

    Document
    |> where([d], d.doc_id == ^pub_id)
    |> WriteScope.scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> Repo.exists?()
  end

  @doc """
  Insert (or REPLACE) a single content edge by its `(from_id, to_id, kind)`
  triple.

  ## Id model — slug `doc_id` IN, `documents.id` UUID stored

  `extract_edges/2` emits `from_id`/`to_id` as STRING slug `doc_id`s (e.g.
  `"art-1"`), but the `content_edges` FKs reference `documents.id` — the
  binary_id UUID PK, NOT the `doc_id` slug (same contract as `task_edges`,
  whose `Tasks.add_dep/3` is called with `child.id`/`parent.id` UUIDs). So
  `add_edge/4` RESOLVES each endpoint slug to its `documents.id` before
  inserting, preferring the published row (mirroring `reference_title/4`'s
  published-before-draft pick). A value that is already a UUID for an existing
  `documents.id` is used as-is. An unresolvable endpoint → `{:error, :no_target}`
  (a dangling edge is UNSTORABLE — the read-time `extract_edges/2` dangling
  signal is the place that surfaces it, not this writer).

  Resolution scope is read from `attrs` (`dataset`, optional `workspace_id` /
  `project_id`) — `extract_edges/2`'s slugs are scope-relative, so a caller
  MUST pass the same `dataset` it extracted under.

  `on_conflict: {:replace, [:weight, :plugin_source, :updated_at]}` with
  `conflict_target: [:from_id, :to_id, :kind]` — REPLACE (not `:nothing`) so a
  re-extracted edge with changed `weight`/`plugin_source` UPDATES rather than
  keeping stale values (gap #9). `updated_at` exists per the schema divergence
  so it is bumped on conflict. The row is reloaded by its unique triple so
  callers always get the canonical struct (same shape as `Tasks.add_dep/3`).

  Returns `{:ok, %Edge{}}` on success, `{:error, :no_target}` when an endpoint
  cannot be resolved to a `documents.id`, or `{:error, %Ecto.Changeset{}}` on
  validation failure (self-edge, unknown kind).
  """
  @spec add_edge(binary(), binary(), String.t(), map()) ::
          {:ok, Barkpark.Content.Edge.t()}
          | {:error, :no_target}
          | {:error, Ecto.Changeset.t()}
  def add_edge(from_id, to_id, kind, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    dataset = attrs["dataset"]
    scope_opts = edge_scope_opts(attrs)

    with from_pk when is_binary(from_pk) <- resolve_doc_pk(from_id, dataset, scope_opts),
         to_pk when is_binary(to_pk) <- resolve_doc_pk(to_id, dataset, scope_opts) do
      base = %{"from_id" => from_pk, "to_id" => to_pk, "kind" => to_string(kind)}

      changeset =
        Barkpark.Content.Edge.changeset(
          %Barkpark.Content.Edge{},
          Map.merge(base, %{
            "weight" => attrs["weight"],
            "plugin_source" => attrs["plugin_source"]
          })
        )

      if changeset.valid? do
        case Repo.insert(changeset,
               on_conflict: {:replace, [:weight, :plugin_source, :updated_at]},
               conflict_target: [:from_id, :to_id, :kind]
             ) do
          {:ok, %Barkpark.Content.Edge{}} ->
            {:ok, fetch_content_edge!(from_pk, to_pk, to_string(kind))}

          {:error, %Ecto.Changeset{} = cs} ->
            {:error, cs}
        end
      else
        {:error, changeset}
      end
    else
      _ -> {:error, :no_target}
    end
  end

  # Resolve a slug `doc_id` (or an already-resolved `documents.id` UUID) to the
  # `documents.id` binary_id PK the content_edges FKs reference. Published row
  # preferred over its `drafts.` twin (CASE-ordered, mirroring reference_title/4)
  # so the stored edge is publish-stable. Returns the UUID string, or nil when
  # nothing in scope matches (caller turns that into {:error, :no_target} — a
  # dangling edge is unstorable).
  defp resolve_doc_pk(nil, _dataset, _scope_opts), do: nil

  defp resolve_doc_pk(id, dataset, scope_opts) when is_binary(id) do
    pub_id = DraftId.published_id(id)
    draft = DraftId.draft_id(pub_id)

    query =
      Document
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft or d.id == ^id)
      |> scope_edge_endpoint(scope_opts)
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(dataset) and dataset != "" do
        WriteScope.scope_to_dataset(query, dataset, scope_opts)
      else
        query
      end

    case query |> Repo.all() |> List.first() do
      %Document{id: pk} -> pk
      _ -> nil
    end
  rescue
    # An `id` that is not a valid binary_id makes `d.id == ^id` raise on cast.
    # Fall back to the slug-only match (drop the `d.id == ^id` disjunct).
    Ecto.Query.CastError -> resolve_doc_pk_by_slug(id, dataset, scope_opts)
  end

  defp resolve_doc_pk_by_slug(id, dataset, scope_opts) do
    pub_id = DraftId.published_id(id)
    draft = DraftId.draft_id(pub_id)

    query =
      Document
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
      |> scope_edge_endpoint(scope_opts)
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(dataset) and dataset != "" do
        WriteScope.scope_to_dataset(query, dataset, scope_opts)
      else
        query
      end

    case query |> Repo.all() |> List.first() do
      %Document{id: pk} -> pk
      _ -> nil
    end
  end

  # Tenancy scope for an edge endpoint resolution. With `require_workspace:
  # true` (the multi-tenant projector, FIX 3) the STRICT `scope_to_workspace/3`
  # is used — a nil workspace_id FAILS CLOSED (where: false), so a nil-scope
  # endpoint resolves to NOTHING and add_edge/4 returns {:error, :no_target}
  # rather than crossing into another tenant's colliding-slug doc. Without the
  # flag (single-tenant / unflagged callers) it is the documented or-global
  # back-compat resolution, byte-identical to before.
  defp scope_edge_endpoint(query, scope_opts) do
    ws = Keyword.get(scope_opts, :workspace_id)
    proj = Keyword.get(scope_opts, :project_id)

    if Keyword.get(scope_opts, :require_workspace, false) do
      scope_to_workspace(query, ws, proj)
    else
      scope_to_workspace_or_global(query, ws, proj)
    end
  end

  defp edge_scope_opts(attrs) do
    []
    |> maybe_put_kw(:dataset_id, attrs["dataset_id"])
    |> maybe_put_kw(:workspace_id, attrs["workspace_id"])
    |> maybe_put_kw(:project_id, attrs["project_id"])
    # FAIL-CLOSED flag (FIX 3) — carried so resolve_doc_pk/3 can refuse a
    # cross-tenant slug match when the multi-tenant projector demands a
    # resolved workspace. Only put when truthy so single-tenant callers keep
    # the default or-global resolution.
    |> maybe_put_kw(:require_workspace, truthy(attrs["require_workspace"]))
  end

  # Keep only a genuinely-true flag (drop nil/false) so `maybe_put_kw` leaves
  # the default resolution untouched on a single-tenant / unflagged caller.
  defp truthy(true), do: true
  defp truthy(_), do: nil

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Insert/replace a batch of edge maps (the `extract_edges/2` shape, or any map
  carrying `from_id`/`to_id`/`kind` + optional `weight`/`plugin_source`).
  Returns the list of CRUD results in order. `dangling`/`field`/`refType` keys
  on the input maps are ignored (they are read-time signals, not stored).

  Because `extract_edges/2` emits scope-relative slug `doc_id`s, the resolution
  `dataset` (and optional `workspace_id`/`project_id`) MUST be passed via
  `opts` so each `add_edge/4` can resolve the slugs to `documents.id` UUIDs in
  the SAME scope they were extracted under. A per-edge `dataset` key wins over
  the batch `opts` default.
  """
  @spec add_edges([map()], keyword()) ::
          [
            {:ok, Barkpark.Content.Edge.t()}
            | {:error, :no_target}
            | {:error, Ecto.Changeset.t()}
          ]
  def add_edges(edges, opts \\ []) when is_list(edges) do
    scope = %{
      "dataset" => Keyword.get(opts, :dataset),
      "dataset_id" => Keyword.get(opts, :dataset_id),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id),
      # FAIL-CLOSED tenancy (Goal ges/graph-edge-seam, FIX 3). When the
      # projector runs in a multi-tenant install it sets this so a nil-workspace
      # endpoint is REFUSED across tenants (→ {:error, :no_target}) instead of
      # resolving a colliding-slug doc in another tenant and storing a
      # cross-tenant content_edges row. Absent/false = the documented
      # single-tenant or-global back-compat resolution.
      "require_workspace" => Keyword.get(opts, :require_workspace, false)
    }

    Enum.map(edges, fn e ->
      from_id = e[:from_id] || e["from_id"]
      to_id = e[:to_id] || e["to_id"]
      kind = e[:kind] || e["kind"]

      attrs =
        scope
        |> Map.put("dataset", e[:dataset] || e["dataset"] || scope["dataset"])
        |> Map.put("weight", e[:weight] || e["weight"])
        |> Map.put("plugin_source", e[:plugin_source] || e["plugin_source"])
        |> Map.put("require_workspace", scope["require_workspace"])

      add_edge(from_id, to_id, kind, attrs)
    end)
  end

  @doc """
  Outbound edges of a document id (indexed `(from_id, kind)` scan). Ordered by
  `inserted_at` ASC — the forward-BFS input for Phase 4. `:kind` opt narrows to
  one kind.
  """
  @spec list_outbound_edges(binary(), keyword()) :: [Barkpark.Content.Edge.t()]
  def list_outbound_edges(from_id, opts \\ []) do
    Barkpark.Content.Edge
    |> where([e], e.from_id == ^from_id)
    |> maybe_filter_edge_kind(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Inbound edges of a document id (indexed `(to_id, kind)` scan). Ordered by
  `inserted_at` ASC — the reverse-walk input for the Studio unpublish guard
  (Phase 4/5). `:kind` opt narrows to one kind.
  """
  @spec list_inbound_edges(binary(), keyword()) :: [Barkpark.Content.Edge.t()]
  def list_inbound_edges(to_id, opts \\ []) do
    Barkpark.Content.Edge
    |> where([e], e.to_id == ^to_id)
    |> maybe_filter_edge_kind(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_edge_kind(query, opts) do
    case Keyword.get(opts, :kind) do
      nil -> query
      kind -> where(query, [e], e.kind == ^to_string(kind))
    end
  end

  defp fetch_content_edge!(from_id, to_id, kind) do
    Repo.one!(
      from(e in Barkpark.Content.Edge,
        where: e.from_id == ^from_id and e.to_id == ^to_id and e.kind == ^kind
      )
    )
  end

  @doc """
  The projection SOURCE corpus — fold `extract_edges/2` over every published
  document of the given `type` in `dataset`. `perspective: :published` so no
  `drafts.<id>` is ever a from_id (drafts decision guard a). The Phase-3
  projector folds this across all types to build the materialised graph.
  """
  @spec corpus_edges(String.t(), String.t(), keyword()) :: [map()]
  def corpus_edges(type, dataset, opts \\ []) do
    list_opts = Keyword.put(opts, :perspective, :published)

    type
    |> Content.list_documents(dataset, list_opts)
    |> Enum.flat_map(fn doc -> extract_edges(doc, opts) end)
  end
end
