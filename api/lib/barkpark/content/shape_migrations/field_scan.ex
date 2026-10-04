defmodule Barkpark.Content.ShapeMigrations.FieldScan do
  @moduledoc """
  Shared plumbing for the value-shape census and convert tasks (owner
  rulings #42 `{_ref}`, #43 `{current}`, #44 Portable Text).

  A field's kind is read from the schema that governs the DOCUMENT, not from
  any schema with the same type name: two workspaces may both have a `post`
  type where `author` is a reference in one and a plain string in the other.
  `governing_schema/2` picks the most specific stored schema for a document's
  workspace, project, dataset and type (exact project, then the workspace with
  no project, then the shared layer), and a document is only reported or
  converted when THAT schema gives the field the expected kind.

  Plugin-owned types are skipped: Studio keeps their stored shapes because
  outside consumers read them (`Barkpark.Content.CanonicalShapes`).

  `convert/2` is dry-run unless `apply: true`, and refuses `apply: true` while
  the instance flag `:canonical_shape_writes` is off (`CanonicalShapes`). An applied change writes the
  new content and a fresh `_rev` straight to the row. It records no history
  revision and emits no mutation event, so it is an operator step to run
  deliberately, never on boot or deploy.
  """

  import Ecto.Query

  alias Barkpark.Content.{CanonicalShapes, Document, SchemaDefinition, Writer}
  alias Barkpark.Repo

  @typedoc "A field the caller's `kind_fun` classified, keyed by the schema that governs it."
  @type field_key :: {binary() | nil, binary() | nil, String.t(), String.t()}

  @doc """
  Every stored schema, grouped by `{workspace_id, project_id, dataset, type}`.
  """
  @spec schemas() :: %{field_key() => [map()]}
  def schemas do
    from(s in SchemaDefinition,
      select: {{s.workspace_id, s.project_id, s.dataset, s.name}, s.fields}
    )
    |> Repo.all()
    |> Map.new(fn {k, fields} -> {k, List.wrap(fields)} end)
  end

  @doc """
  The fields of the schema that governs `doc`, most specific first: exact
  workspace + project, then the workspace with no project, then the shared
  layer (no workspace). `nil` when no stored schema governs it.
  """
  @spec governing_schema(map(), %Document{}) :: [map()] | nil
  def governing_schema(schemas, %Document{} = doc) do
    Enum.find_value(
      [
        {doc.workspace_id, doc.project_id, doc.dataset, doc.type},
        {doc.workspace_id, nil, doc.dataset, doc.type},
        {nil, nil, doc.dataset, doc.type}
      ],
      &Map.get(schemas, &1)
    ) || only_workspace_schema(schemas, doc)
  end

  # A document with no project under a workspace whose schema names one:
  # use it only when it is the workspace's single schema for this type.
  defp only_workspace_schema(schemas, doc) do
    case for(
           {{ws, _p, ds, t}, fields} <- schemas,
           ws == doc.workspace_id and ds == doc.dataset and t == doc.type,
           do: fields
         ) do
      [fields] -> fields
      _ -> nil
    end
  end

  @doc """
  Names of the fields in `fields` that `kind_fun` classifies as non-nil,
  as `%{name => kind}`.
  """
  @spec field_kinds([map()] | nil, (map() -> atom() | nil)) :: %{String.t() => atom()}
  def field_kinds(nil, _kind_fun), do: %{}

  def field_kinds(fields, kind_fun) do
    for %{} = f <- fields,
        name = f["name"] || f[:name],
        is_binary(name),
        kind = kind_fun.(f),
        kind != nil,
        into: %{},
        do: {name, kind}
  end

  @doc """
  The type names that have at least one field `kind_fun` classifies, across
  all stored schemas, minus the plugin-owned types Studio leaves in their
  stored shape (`CanonicalShapes.exempt_types/0`). Used to narrow the scan.
  """
  @spec candidate_types(map(), (map() -> atom() | nil)) :: [String.t()]
  def candidate_types(schemas, kind_fun) do
    schemas
    |> Enum.filter(fn {_k, fields} -> field_kinds(fields, kind_fun) != %{} end)
    |> Enum.map(fn {{_ws, _p, _ds, type}, _} -> type end)
    |> Enum.uniq()
    |> Enum.reject(&CanonicalShapes.exempt?/1)
  end

  @doc """
  Walk every document of `types` and call `rewrite_fun.(kind, value)` for each
  field its governing schema classifies with `kind_fun`. `rewrite_fun` returns
  `{:rewrite, new_value}` or `:keep`.

  Options: `apply:` (default `false`). Returns
  `%{scanned, changed, applied?, rows}`; each row is
  `%{doc_id, type, field, from, to}`.
  """
  @spec convert(
          (map() -> atom() | nil),
          (atom(), term() -> {:rewrite, term()} | :keep),
          keyword()
        ) ::
          map()
  def convert(kind_fun, rewrite_fun, opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)

    if apply? and not CanonicalShapes.writes_enabled?() do
      raise ArgumentError,
            "refusing to convert: canonical shape writes are off on this instance. " <>
              "Turn on BARKPARK_CANONICAL_SHAPE_WRITES (config :barkpark, " <>
              ":canonical_shape_writes) once this box's consumers read both shapes, " <>
              "then re-run with apply: true. The dry run works either way."
    end

    schemas = schemas()
    types = candidate_types(schemas, kind_fun)

    docs =
      from(d in Document, where: d.type in ^types, order_by: d.id)
      |> Repo.all()

    results =
      Enum.map(docs, fn doc ->
        kinds = schemas |> governing_schema(doc) |> field_kinds(kind_fun)
        content = doc.content || %{}

        rows =
          for {field, kind} <- kinds,
              Map.has_key?(content, field),
              from = content[field],
              {:rewrite, to} <- [rewrite_fun.(kind, from)],
              to != from,
              do: %{doc_id: doc.doc_id, type: doc.type, field: field, from: from, to: to}

        if apply? and rows != [] do
          new_content = Enum.reduce(rows, content, &Map.put(&2, &1.field, &1.to))

          doc
          |> Ecto.Changeset.change(content: new_content, rev: Writer.generate_rev())
          |> Repo.update!()
        end

        rows
      end)

    rows = List.flatten(results)

    %{
      scanned: length(docs),
      changed: results |> Enum.count(&(&1 != [])),
      applied?: apply?,
      rows: rows
    }
  end

  @doc "Documents holding at least one convertible value, per `{type, field}`."
  @spec census_of([map()]) :: [%{type: String.t(), field: String.t(), documents: pos_integer()}]
  def census_of(rows) do
    rows
    |> Enum.group_by(&{&1.type, &1.field}, & &1.doc_id)
    |> Enum.map(fn {{type, field}, ids} ->
      %{type: type, field: field, documents: ids |> Enum.uniq() |> length()}
    end)
    |> Enum.sort_by(&{&1.type, &1.field})
  end
end
