defmodule Barkpark.Content.Schema do
  @moduledoc """
  Schema-definition reads, writes, and SDK serialization.

  Owns the `SchemaDefinition` CRUD surface (`list_schemas`, `get_schema`,
  `upsert_schema`, `delete_schema`), the public-visibility / CORS gates
  (`schema_public?`, `allowed_origins_for_dataset`), the deterministic schema
  hashes (`schema_hash_for_*`), the SDK envelope serializers
  (`serialize_schema_for_sdk`, `list_schemas_for_sdk`), the dataset catalog
  (`list_datasets`, `default_dataset`), and `resolve_expectation`.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade so
  every external caller (SchemaController, Bootstrap, SDK serialization,
  capabilities) is unchanged.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_schema_to_dataset/3`
  / `scope_to_dataset/3` (concern K, not yet relocated): resolved via the
  still-on-facade public `Content.resolve_read_dataset_id/2`, then the
  NULL-tolerant legacy-string OR. Write-scope stamping (`upsert_schema`) and the
  Default-project fallback (`list_datasets/0`) call the still-on-facade
  `Content.put_scope_attrs/2` / `Content.read_default_project_id/1`. Workspace
  scope rides the shared `Barkpark.Content.Scope.scope_to_workspace_or_global/3`.
  """

  import Ecto.Query
  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3, scope_to_workspace_including_global: 3]

  def default_dataset, do: "production"

  @doc """
  Return the dataset slugs OWNED by a project, sorted alphabetically.
  Always includes `"production"` so a brand-new project still has something to
  show.

  Datasets are project-owned (the `dataset` STRING is unique only *within* a
  project), so this scopes to a project rather than listing globally. The arity
  resolves to:

    * `list_datasets(project_id)` — the slugs of that project's datasets.
    * `list_datasets/0` — defaults to the seeded Default project (the legacy
      flat-route landing where no workspace/project is in scope). Degrades to a
      bare `"production"` when no Default project exists (fresh sandbox).

  Reads the `dataset` STRING mirror (filtered by `project_id`) rather than the
  Tenancy `datasets` table so pre-`get_or_create_dataset` fixtures still list.
  """
  def list_datasets(project_id \\ :default)

  def list_datasets(:default), do: list_datasets(Content.read_default_project_id())

  def list_datasets(nil), do: ["production"]

  def list_datasets(project_id) when is_binary(project_id) do
    from_schemas =
      from(s in SchemaDefinition,
        where: s.project_id == ^project_id,
        select: s.dataset,
        distinct: true
      )
      |> Repo.all()

    from_docs =
      from(d in Document,
        where: d.project_id == ^project_id,
        select: d.dataset,
        distinct: true
      )
      |> Repo.all()

    (from_schemas ++ from_docs ++ ["production"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def list_schemas(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    scope_fun = workspace_scope_fun(opts)

    SchemaDefinition
    |> scope_schema_to_dataset(dataset, opts)
    |> scope_fun.(workspace_id, project_id)
    # dataset_id-bearing rows before legacy nil-dataset_id fixtures, then dedup
    # by name — one catalog entry per type even on a backfill/fixture overlap.
    |> order_by([s], asc: s.name, asc_nulls_last: s.dataset_id)
    |> Repo.all()
    |> Enum.uniq_by(& &1.name)
  end

  def get_schema(name, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    SchemaDefinition
    |> where([s], s.name == ^name)
    |> scope_schema_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    # A backfilled row (dataset_id set) and a legacy nil-dataset_id fixture of
    # the same name can both match the dataset-OR-string scope. Prefer the
    # backfilled (dataset_id-bearing) row and take exactly one — deterministic.
    |> order_by([s], asc_nulls_last: s.dataset_id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  @doc """
  Resolve a type's `%SchemaDefinition{}` FOR FIELD-VISIBILITY REDACTION — the
  tenant-scoped lookup with the GLOBAL-schema fallback.

  THE ONE chokepoint every Envelope render/redact site resolves its schema
  through. `get_schema/3` with a binary `:workspace_id` filters
  `where workspace_id == ^ws` (`Barkpark.Content.Scope.scope_to_workspace/3`), so
  a schema declared GLOBALLY (`workspace_id: nil`) never matches a document that
  lives in a workspace. `Barkpark.Content.Envelope` is fail-OPEN on a nil schema
  (an undeclared field is public, for legacy parity), so a single scoped lookup
  that misses renders every `private` / `owner_only` / `readable_by` field of
  that type to whoever is reading. The retry — the same lookup with the tenant
  keys DROPPED — recovers the global row so the declared visibility still binds.

  TENANCY GUARD (LOAD-BEARING): the stripped-scope query reads cross-tenant rows,
  so the fallback is accepted ONLY when its `workspace_id` is nil — the genuinely
  global schema. Any non-nil `workspace_id` would substitute a FOREIGN tenant's
  same-named schema, turning a redaction fix into a cross-tenant schema leak (and,
  on the write-through paths, gating this tenant's edits on another's visibility).

  Returns `{:ok, schema}` or `:error` — `:error` (not `{:error, :not_found}`)
  precisely so a caller cannot mistake it for a bare `get_schema/3` result.

  A caller that wants the raw tenant-scoped read (schema CRUD, the schema
  endpoint, reference detection — anything that is not feeding a redaction
  boundary) still calls `get_schema/3` directly.
  """
  @spec get_schema_for_redaction(String.t(), String.t() | nil, keyword()) ::
          {:ok, SchemaDefinition.t()} | :error
  # @canonical capability:schema-resolution-for-redaction aka:get_schema fallback,global schema fallback doc:docs/cards/search-media.md
  def get_schema_for_redaction(name, dataset, opts \\ []) do
    case get_schema(name, dataset, opts) do
      {:ok, schema} ->
        {:ok, schema}

      _ ->
        case get_schema(name, dataset, Keyword.drop(opts, [:workspace_id, :project_id])) do
          {:ok, %SchemaDefinition{workspace_id: nil} = schema} -> {:ok, schema}
          _ -> :error
        end
    end
  end

  @doc """
  Resolve the full Expectation for a schema definition.

  An Expectation is the schema PLUS its SOFT `layout` (ordered field-refs +
  free-content region markers) and `prefill` (create-time scaffold). Explicit
  stored `layout`/`prefill` columns win when non-empty; otherwise a field-order
  default is derived (`SchemaDefinition.default_layout/1` + `default_prefill/1`)
  so nothing has to migrate. The layout is metadata, never a constraint — a
  document with missing or reordered fields is always valid.

  Returns `%{layout: [map()], prefill: map()}`.
  """
  @spec resolve_expectation(SchemaDefinition.t()) :: %{layout: [map()], prefill: map()}
  def resolve_expectation(%SchemaDefinition{} = schema) do
    SchemaDefinition.resolve_expectation(schema)
  end

  def upsert_schema(attrs, dataset, opts \\ []) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    # Fail-closed scope stamp (felix-w26): a refused dataset resolution errors
    # out of the with (SchemaController's action_fallback funnels it through
    # Errors.to_envelope) instead of silently stamping dataset_id=NULL.
    with {:ok, attrs} <-
           attrs
           |> Map.put("dataset", dataset)
           |> Content.put_scope_attrs(opts) do
      case name && get_schema(name, dataset, opts) do
        {:ok, existing} ->
          if owned_by_other_workspace?(existing, attrs) do
            insert_schema(attrs)
          else
            existing
            |> SchemaDefinition.changeset(attrs)
            |> Repo.update()
          end

        _ ->
          insert_schema(attrs)
      end
    end
  end

  defp insert_schema(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Run the FULL `upsert_schema/3` validation pipeline and return its verdict
  WITHOUT touching the store — the server side of `POST /v1/schemas/:dataset`
  with `validate_only: true` (task-19b7ca7ff92fb710 #21).

  `bp schema apply --dry-run` is a CLIENT-side preview only: the global
  `--dry-run` flag prints the resolved request and exits before the send
  (`internal/cli/run.go`), so until now there was no way to ask the SERVER
  "would this schema be accepted?" without also writing it. A caller who wanted
  the answer had to write and then undo, which is not a validation, it is a
  deploy.

  Same gates as the write, in the same order, so a verdict here binds:

    1. `Content.put_scope_attrs/2` — the fail-closed scope stamp. A refused
       dataset resolution errors out of the `with` exactly as on the write
       path, so nobody gets a green verdict for a scope the write would refuse.
    2. The same upsert TARGET selection — an existing in-scope row of that name
       becomes the changeset base, so an UPDATE is validated as an update
       (partial payloads keep the stored values they omit); a row owned by
       another workspace is not, because the write would insert there too.
    3. `SchemaDefinition.changeset/2` + `Ecto.Changeset.apply_action/2` — every
       cast / `validate_required` / `validate_inclusion` / desk-group rule the
       write runs, applied in memory.

  DELIBERATELY NOT CHECKED, because it is only knowable at the database: the
  `unique_constraint`s on `(name, dataset_id)` and `(name, dataset)`.
  `apply_action/2` never reaches Postgres, so a name collision still surfaces
  on the real write. The verdict is "this payload is well-formed and in scope",
  never "this write is guaranteed to succeed" — say so at any door that renders
  it rather than letting a caller read it as a reservation.

  Returns `{:ok, %SchemaDefinition{}}` — the unsaved struct the write WOULD
  have produced — or `{:error, %Ecto.Changeset{}}` / the scope error, both of
  which `Content.Errors` already renders in the write's own envelope shape.
  """
  @spec validate_schema(map(), String.t(), keyword()) ::
          {:ok, SchemaDefinition.t()} | {:error, term()}
  def validate_schema(attrs, dataset, opts \\ []) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    with {:ok, attrs} <-
           attrs
           |> Map.put("dataset", dataset)
           |> Content.put_scope_attrs(opts) do
      base =
        case name && get_schema(name, dataset, opts) do
          {:ok, existing} ->
            if owned_by_other_workspace?(existing, attrs),
              do: %SchemaDefinition{},
              else: existing

          _ ->
            %SchemaDefinition{}
        end

      base
      |> SchemaDefinition.changeset(attrs)
      |> Ecto.Changeset.apply_action(if base.id, do: :update, else: :insert)
    end
  end

  # The cross-tenant ownership guard (pds-bl-bootstrap-cross-tenant-theft).
  #
  # An opts-less caller (Plugins.Bootstrap, Content.TagRegistry) reads through
  # `scope_to_workspace_or_global/3` with NO workspace filter, and the nil arm
  # of `scope_schema_to_dataset/3` (`dataset_id IS NULL AND dataset = <slug>`)
  # can then match a legacy nil-dataset_id row owned by a FOREIGN workspace.
  # Updating that row would clobber its content AND — because
  # `put_scope_attrs/2` stamps the resolved (Default) scope into attrs —
  # rewrite its workspace_id/project_id: a genuine cross-tenant write, proven
  # by probe S3 in bootstrap_default_slot_probe_test.exs.
  #
  # When the matched row carries a non-nil workspace_id DIFFERENT from the
  # server-resolved write-scope workspace, the update is refused and the write
  # lands as a FRESH row in the target scope instead (get_schema's
  # dataset_id-first ordering makes subsequent upserts converge on that row).
  # Everything else is byte-identical: a same-workspace row and a legacy
  # GLOBAL row (nil workspace_id — deliberately adopted into the resolved
  # scope) still update in place, and workspace-scoped callers
  # (SchemaController, provision_schemas) already read workspace-confined rows
  # so this predicate is structurally false for them.
  defp owned_by_other_workspace?(%SchemaDefinition{workspace_id: row_ws}, attrs) do
    target_ws = Map.get(attrs, "workspace_id")
    is_binary(row_ws) and is_binary(target_ws) and row_ws != target_ws
  end

  @doc """
  Delete a schema definition — GUARDED against silently orphaning documents.

  Deleting a schema whose `visibility` is `"public"` used to succeed
  unconditionally; afterwards `schema_public?/3` returns false for the type, so
  every public read of its (now type-less) documents 404s — the docs are
  orphaned with no cascade, count, or warning. This fails CLOSED instead:

    * If ≥1 document of `name` exists in the dataset scope, refuse with
      `{:error, {:schema_has_documents, count}}` (rendered 409) UNLESS the caller
      passes `force: true`.
    * With `force: true` (or a zero-document type) the delete proceeds. When
      forcing over a non-empty type a warning is logged naming the orphan count.

  `force` is additive — existing callers (none pass it) keep the safe default,
  and an empty-type delete is byte-identical to the prior behaviour.
  """
  def delete_schema(name, dataset, opts \\ []) do
    case get_schema(name, dataset, opts) do
      {:ok, schema} ->
        force? = Keyword.get(opts, :force, false)
        doc_count = count_documents_of_type(name, dataset, opts)

        cond do
          doc_count > 0 and not force? ->
            {:error, {:schema_has_documents, doc_count}}

          true ->
            if doc_count > 0 do
              Logger.warning(
                "delete_schema: force-deleting schema #{inspect(name)} in dataset " <>
                  "#{inspect(dataset)} — orphaning #{doc_count} document(s) of this type"
              )
            end

            # A concurrent double-DELETE would raise Ecto.StaleEntryError (→ 500).
            # stale_error_field turns the race into {:error, :not_found} (rendered 404).
            case Repo.delete(schema, stale_error_field: :id) do
              {:error, cs} -> if stale?(cs), do: {:error, :not_found}, else: {:error, cs}
              ok -> ok
            end
        end

      error ->
        error
    end
  end

  # Count every document of `name` in the dataset scope (all perspectives, all
  # owners) — the exact set that would be orphaned by deleting the schema. Reuses
  # the module's dataset + workspace/global scoping so the count reads the SAME
  # tenant the schema row resolves to.
  defp count_documents_of_type(name, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.type == ^name)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> Repo.aggregate(:count)
  end

  # Repo.delete(struct, stale_error_field: :id) turns a would-be
  # Ecto.StaleEntryError into a changeset error tagged `stale: true`.
  defp stale?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, error_opts}} -> Keyword.get(error_opts, :stale) == true
      _ -> false
    end)
  end

  defp stale?(_), do: false

  @doc """
  Whether the schema's public-read gate is open for `type` in `dataset`.

  Threads the caller's tenancy `opts` (`[workspace_id:, project_id:]`) into
  `get_schema/3` so the visibility flag is read from the SAME tenant the row
  read resolves to — never the Default project. Without `opts` (the flat /
  legacy plug caller) it resolves against the Default scope, preserving prior
  behavior. See barkpark-su54: closing the latent split-brain where the gate
  and the row-read could read visibility from two different tenants.
  """
  def schema_public?(type, dataset, opts \\ []) do
    case get_schema(type, dataset, opts) do
      {:ok, %{visibility: "public"}} -> true
      _ -> false
    end
  end

  @doc """
  The visibility invariant applied to a schema ROW (struct or map) instead of a
  `(type, dataset)` pair — `schema_public?/3` with the read already done.

  ONE predicate, four enforcement points: the query route's `schema_public?/3`,
  the anonymous search allowlist (`DocumentsRetriever.public_type_names/2`), the
  corpus graph's per-caller type list (`TasksController.graph_corpus/2`) and the
  ungated legacy schema index (`LegacyController.schemas/2`, which serves
  `fields` to anonymous readers and must show public types only).
  EXPLICITLY `"public"` only — `nil`, `"private"` and any future value are NOT
  public, so a new visibility value fails CLOSED on every surface at once.
  """
  def public_schema?(%{visibility: v}), do: v == "public"
  def public_schema?(%{"visibility" => v}), do: v == "public"
  def public_schema?(_), do: false

  @doc """
  The allowlist of schema type NAMES a public-tier caller may see, derived at
  READ TIME from `public_schema?/1`.

  Two shapes, same invariant: pass an ALREADY-READ schema list (the corpus graph
  has one in hand and must not pay a second query for it), or a dataset +
  tenancy `opts` (the search read path, which has none). Never a hardcoded type
  list — a schema flipped to private, or a private schema created seconds ago,
  must drop out of the allowlist on the very next read.

  Fails closed: an empty allowlist means the caller sees nothing, not everything.
  """
  def public_type_names(schemas) when is_list(schemas) do
    schemas
    |> Enum.filter(&public_schema?/1)
    |> Enum.map(fn
      %{name: name} -> name
      %{"name" => name} -> name
      _ -> nil
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # No default `opts` here: `public_type_names/1` above already owns arity 1
  # (the already-read list), so a defaulted second argument would collide.
  def public_type_names(dataset, opts) when is_binary(dataset) do
    dataset
    |> list_schemas(opts)
    |> public_type_names()
  end

  @doc """
  Has this caller EARNED the unclamped view of schema visibility?

  The single owner of the "which tier is asking" half of every schema-visibility
  decision — the other half being `public_schema?/1` / `public_type_names/2`,
  which decide what the clamped tier may see. It was previously hand-written
  twice (`DocumentsRetriever.bypasses_visibility_gate?/1` and `visible_schemas/2`
  below) and, by omission, not at all on the batch document read — the hole
  `?expand=` walked through. Two copies of one visibility rule is how this
  family recurs, so there is now one.

  DEFAULT-NARROW. The widening arm matches ONLY a `%CallerContext{}` for an
  authenticated principal (`:api_token` or `:user`) outside the public-read
  tier. Anonymous, `nil`, a public-read token, a bare map, a render sentinel
  (`:internal`) and any future principal shape all land in the narrow arm by
  construction — "unrecognised" must never mean "show everything".

  The tier test is `"public-read" in roles` — MEMBERSHIP, never list equality:
  `CallerContext.from_token/1` stores the token's permission list VERBATIM and
  `TokenController` mints `["public-read", "read"]` as a real shape, so a
  `roles == ["public-read"]` pin would be escapable by construction. Same
  predicate as `PublicRead.public_read_token?/1`.
  """
  # @canonical capability:visibility-gate-tier aka:bypasses_visibility_gate,public_read_principal,anonymous type clamp,who may see private types doc:docs/cards/search-media.md
  @spec bypasses_visibility_gate?(any()) :: boolean()
  def bypasses_visibility_gate?(%Barkpark.Content.CallerContext{principal_type: p, roles: roles})
      when p in [:api_token, :user] and is_list(roles),
      do: "public-read" not in roles

  def bypasses_visibility_gate?(_), do: false

  @doc """
  The corpus-graph schema-visibility clamp, keyed on the PRINCIPAL — the ONE
  owner of the "which schemas may this caller see in a whole-corpus read"
  decision. Both corpus derivations (`TasksController.derive_graph_corpus/2`,
  the flat `/v1/graph` twin, and `FinderLive.graph_payload/2`, the public
  finder's inline payload) MUST read through this function; a hand-copied
  derivation at a call site is exactly how the anonymous /finder leak
  (task-336d22b7722ea71e) shipped.

  DEFAULT-NARROW, WIDEN ONLY WHEN EARNED. The predecessor keyed on "is this
  the one restricted tier?" (`PublicRead.public_read_token?/1`) with an
  else-arm of "show everything" — an allow-list of one tier that FAILED OPEN
  for every principal it did not recognise, including a visitor with no token
  at all. This clamp inverts the key: the widening arm matches ONLY a
  `CallerContext` that has earned the full view — an authenticated principal
  (`:api_token` or `:user`) outside the public-read tier — and the catch-all
  clamps. Anonymous, `nil`, a public-read token, a bare map, and any future
  principal shape all land in the narrow arm by construction.

  The tier test itself is `bypasses_visibility_gate?/1` above — one predicate,
  shared with the anonymous search allowlist
  (`DocumentsRetriever.restrict_anonymous_to_public_types/3`) and the batch
  document read (`Query.restrict_to_visible_types/3`).

  The narrow view is `public_schema?/1` over the already-read rows — derived
  at READ TIME, so a schema flipped to private drops out on the very next
  corpus read, and an empty allowlist means the caller sees NOTHING, not
  everything.
  """
  # The TIER half of the decision is `bypasses_visibility_gate?/1` above — the
  # one owner, shared with the anonymous search allowlist and the batch document
  # read. The narrow arm is the DEFAULT: anything that has not affirmatively
  # earned the wider view — anonymous, nil, a non-struct, an unknown future
  # principal — sees public-visibility schemas only. "Unrecognised" must never
  # fall through to "show everything" again.
  # @canonical capability:corpus-visible-schemas aka:visible_schemas,graph_payload,finder leak,private type titles,schema visibility clamp doc:docs/cards/search-media.md
  def visible_schemas(schemas, caller_context) when is_list(schemas) do
    if bypasses_visibility_gate?(caller_context) do
      schemas
    else
      Enum.filter(schemas, &public_schema?/1)
    end
  end

  @doc """
  Returns the union of CORS origin allow-lists across all schemas in the dataset.

  An empty list means "no dataset-level policy" (default-allow).
  A list containing `"*"` means "public, any origin".
  Otherwise the list is an explicit allow-list of origin strings.
  """
  @spec allowed_origins_for_dataset(String.t(), keyword()) :: [String.t()]
  def allowed_origins_for_dataset(dataset, opts \\ []) when is_binary(dataset) do
    SchemaDefinition
    |> scope_to_dataset(dataset, opts)
    |> select([s], s.cors_origins)
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Deterministic 16-char hex digest of a dataset's schema CATALOG — `{row count,
  latest updated_at}` over exactly the rows `list_schemas/2` would return for
  the same `opts`. Served as `datasetSchemaHash` / `schemaHash` so an SDK can
  tell whether its generated types are stale.

  It applies BOTH confinements `list_schemas/2` applies — the dataset filter AND
  `workspace_scope_fun/1` — because either one alone leaks (task-09ea9f28764a8790).
  `scope_to_dataset/3` narrows authoritatively only when the dataset STRING
  resolves to a `dataset_id`; when it does not, it falls back to the bare
  `dataset == <slug>` STRING. That fallback is the NORMAL case on every FLAT
  route: `AssignDefaultScope` deliberately declines to pair a non-Default
  workspace with the Default project, so the opts carry a `workspace_id` with no
  `project_id` and `resolve_read_dataset_id/2` returns nil. Without the
  workspace clause the digest then spanned EVERY workspace's same-named dataset,
  making the value a cross-tenant change oracle: any tenant's admin could watch
  another tenant's schema count and mtime move.

  A nil `workspace_id` (an opts-less internal caller) still reads globally —
  `scope_to_workspace_or_global/3`'s nil arm is the explicit unscoped read, so
  in-process callers are untouched.
  """
  def schema_hash_for_dataset(dataset, opts \\ []) when is_binary(dataset) do
    scope_fun = workspace_scope_fun(opts)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    SchemaDefinition
    |> scope_to_dataset(dataset, opts)
    |> scope_fun.(workspace_id, project_id)
    |> select([s], {count(s.id), max(s.updated_at)})
    |> Repo.one()
    |> hash_schema_tuple()
  end

  # THE one workspace-confinement rule for the schema catalog, shared by
  # `list_schemas/2` (the rows) and `schema_hash_for_dataset/2` (their digest).
  #
  # Extracted rather than copied on purpose: this task exists because the hash
  # applied a STRICT SUBSET of the confinement its own catalog applied, and two
  # inline copies of the rule is how that gap reopens. Sharing the selector
  # makes "the hash covers exactly the rows the array covers" structural.
  #
  # `include_global: true` makes a workspace-scoped read ALSO surface shared
  # global (nil-workspace) schemas — the Studio desk wants the workspace's own
  # types plus the shared/plugin base layer (see Barkpark.Structure.build/2).
  # The default stays the strict, fail-closed workspace-or-global read.
  defp workspace_scope_fun(opts) do
    if Keyword.get(opts, :include_global, false),
      do: &scope_to_workspace_including_global/3,
      else: &scope_to_workspace_or_global/3
  end

  @doc """
  Deterministic 16-char hex content hash of a single schema definition.
  Derived from `{name, fields sorted by name}` so it changes iff the schema
  body changes, regardless of row metadata (updated_at, id).
  """
  def schema_hash_for_schema(%SchemaDefinition{} = schema) do
    normalized_fields =
      (schema.fields || [])
      |> Enum.map(&stringify_keys/1)
      |> Enum.sort_by(& &1["name"])

    payload = :erlang.term_to_binary({schema.name, normalized_fields})

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Render a single schema in SDK envelope shape, with `schemaHash`,
  per-field `required?`, and `of`/`to` specs where applicable.
  """
  def serialize_schema_for_sdk(%SchemaDefinition{} = schema) do
    %{
      id: schema.name,
      name: schema.name,
      title: schema.title,
      icon: schema.icon,
      visibility: schema.visibility,
      # The SOLE desk discriminant (schema_definition.ex): `singleton: true` opts
      # a type out of the generic Content bucket into the siteSettings-style
      # single-document node. The changeset CASTS it, so POST accepts it — this
      # serializer is the body of BOTH the 201 echo and every GET /v1/schemas row,
      # so omitting it made the flag WRITE-ONLY: a consumer could set it and never
      # read back what took (task-567f0fb2429086df). `|| false` normalises a nil
      # (unloaded/legacy) to the schema's own default rather than leaking nil.
      singleton: schema.singleton || false,
      schemaHash: schema_hash_for_schema(schema),
      fields: Enum.map(schema.fields || [], &serialize_field/1),
      actions: schema.actions || [],
      groups: schema.groups || [],
      deskGroups: schema.desk_groups || [],
      crossValidations: schema.cross_validations || [],
      # Generic list-row preview declaration (badge + meta content fields);
      # empty map == no declaration, SDK/TUI rows render unchanged.
      listPreview: schema.list_preview || %{}
    }
  end

  @doc """
  List every schema in a dataset in SDK envelope shape, plus a
  top-level `datasetSchemaHash` mirroring `schema_hash_for_dataset/2`.

  `opts` MUST reach BOTH calls. The hash used to be taken from the arity-1
  `schema_hash_for_dataset(dataset)` on the line right after `list_schemas/2`
  consumed the very same `opts` (task-803991319aa64189). With empty opts,
  `resolve_read_dataset_id/2` falls through to `read_default_project_id/1` — the
  SEEDED DEFAULT project — so every tenant's envelope carried a digest of the
  Default workspace's schema count and last-modified timestamp: a low-entropy
  cross-tenant change oracle, and a hash that never moved when the caller's OWN
  schemas changed (which is exactly what `js/packages/codegen` stamps into the
  generated-types banner to detect staleness).
  """
  def list_schemas_for_sdk(dataset, opts \\ []) when is_binary(dataset) do
    schemas = list_schemas(dataset, opts)

    %{
      schemas: Enum.map(schemas, &serialize_schema_for_sdk/1),
      datasetSchemaHash: schema_hash_for_dataset(dataset, opts)
    }
  end

  defp serialize_field(field) do
    f = stringify_keys(field)
    type = f["type"]

    base = Map.put(f, "required?", truthy?(f["required"]))

    base
    |> maybe_put_of(type, f)
    |> maybe_put_to(type, f)
  end

  defp maybe_put_of(out, "array", f) do
    of =
      cond do
        is_list(f["of"]) ->
          Enum.map(f["of"], &element_spec/1)

        is_list(get_in(f, ["options", "list"])) ->
          Enum.map(f["options"]["list"], &element_spec/1)

        true ->
          [%{"type" => "string"}]
      end

    Map.put(out, "of", of)
  end

  defp maybe_put_of(out, _type, _f), do: out

  defp maybe_put_to(out, "reference", f) do
    to =
      cond do
        is_list(f["to"]) ->
          Enum.map(f["to"], &element_spec/1)

        is_list(get_in(f, ["options", "references"])) ->
          Enum.map(f["options"]["references"], &element_spec/1)

        is_binary(f["refType"]) ->
          [%{"type" => f["refType"]}]

        true ->
          []
      end

    Map.put(out, "to", to)
  end

  defp maybe_put_to(out, _type, _f), do: out

  defp element_spec(%{} = spec) do
    spec
    |> stringify_keys()
    |> Map.take(["type", "to", "name"])
  end

  defp element_spec(type) when is_binary(type), do: %{"type" => type}
  defp element_spec(_), do: %{"type" => "string"}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp stringify_keys(%{} = m) do
    Map.new(m, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  def schema_hash_for_all_datasets do
    from(s in SchemaDefinition,
      group_by: s.dataset,
      select: {s.dataset, count(s.id), max(s.updated_at)}
    )
    |> Repo.all()
    |> Map.new(fn {ds, n, t} -> {ds, hash_schema_tuple({n, t})} end)
  end

  defp hash_schema_tuple({nil, nil}), do: "0000000000000000"

  defp hash_schema_tuple({n, t}) do
    payload = "#{n}|#{inspect(t)}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

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

  # Mirrors `Barkpark.Content`'s private `scope_schema_to_dataset/3` (concern K,
  # still on the facade). Like scope_to_dataset, but ALSO matches rows whose
  # `dataset_id` is NULL but whose `dataset` STRING equals the requested one —
  # legacy/pre-tenancy schema fixtures the W2 dual-write never stamped. The
  # dataset STRING and dataset_id are 1:1 within a project, so the OR never
  # crosses datasets; get_schema/3 orders dataset_id-first + limit 1 to resolve
  # the (rare) backfilled-vs-fixture overlap deterministically.
  defp scope_schema_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [s], s.dataset_id == ^id or (is_nil(s.dataset_id) and s.dataset == ^dataset))

      _ ->
        where(query, [s], s.dataset == ^dataset)
    end
  end
end
