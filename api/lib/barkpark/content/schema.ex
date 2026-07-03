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

    # `include_global: true` makes a workspace-scoped read ALSO surface shared
    # global (nil-workspace) schemas — the Studio desk wants the workspace's own
    # types plus the shared/plugin base layer (see Barkpark.Structure.build/3).
    # The default stays the strict, fail-closed workspace-or-global read.
    scope_fun =
      if Keyword.get(opts, :include_global, false),
        do: &scope_to_workspace_including_global/3,
        else: &scope_to_workspace_or_global/3

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

    attrs =
      attrs
      |> Map.put("dataset", dataset)
      |> Content.put_scope_attrs(opts)

    case name && get_schema(name, dataset, opts) do
      {:ok, existing} ->
        existing
        |> SchemaDefinition.changeset(attrs)
        |> Repo.update()

      _ ->
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(attrs)
        |> Repo.insert()
    end
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

  def schema_hash_for_dataset(dataset, opts \\ []) when is_binary(dataset) do
    SchemaDefinition
    |> scope_to_dataset(dataset, opts)
    |> select([s], {count(s.id), max(s.updated_at)})
    |> Repo.one()
    |> hash_schema_tuple()
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
  top-level `datasetSchemaHash` mirroring `schema_hash_for_dataset/1`.
  """
  def list_schemas_for_sdk(dataset, opts \\ []) when is_binary(dataset) do
    schemas = list_schemas(dataset, opts)

    %{
      schemas: Enum.map(schemas, &serialize_schema_for_sdk/1),
      datasetSchemaHash: schema_hash_for_dataset(dataset)
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
