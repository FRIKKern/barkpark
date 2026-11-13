defmodule BarkparkWeb.Studio.Desk.Refs do
  @moduledoc """
  The documents a desk-slice document points at, so its pane can offer each
  reference as a link that opens the target in the next pane (the TanStack
  Studio's endless pane chain).

  A reference is stored as `%{"_ref" => id}` or, on older rows, a bare id
  string. A reference field is `type: "reference"`; an array of them is
  `type: "arrayOf"` (or `"array"`) whose `of` is, or holds, a reference.
  All targets of one document are read in one query, whatever their types.

  A target is named as the desk's rows name it: a type with no `title` field
  by its `list_preview.title` field (an author's `name`), which a rename
  moves, while the stored `title` column keeps the first name the document
  had (refs.spec:179). Each target type's schema is read once per call.
  """

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation

  @type target :: %{id: String.t(), type: String.t() | nil, title: String.t()}

  @doc "The reference fields of `schema`, as `{name, :one | :many}`."
  @spec fields(map()) :: [{String.t(), :one | :many}]
  def fields(schema) do
    for %{"name" => name} = field <- Map.get(schema, :fields) || [],
        kind = kind(field),
        do: {name, kind}
  end

  defp kind(%{"type" => "reference"}), do: :one

  defp kind(%{"type" => type, "of" => of}) when type in ["arrayOf", "array"] do
    if Enum.any?(List.wrap(of), &match?(%{"type" => "reference"}, &1)), do: :many
  end

  defp kind(_field), do: nil

  @doc """
  The document types the reference fields of `schema` can point at (their
  `to`), or `:any` when one of them names none. A document of another type
  is never among its references, so a save of one changes nothing it shows.
  """
  @spec target_types(map()) :: MapSet.t(String.t()) | :any
  def target_types(schema) do
    refs =
      for %{"type" => type} = field <- Map.get(schema, :fields) || [],
          ref <- if(type == "reference", do: [field], else: of_refs(field)),
          do: ref["to"] |> List.wrap() |> Enum.map(&to_name/1)

    if Enum.any?(refs, &(&1 == [] or nil in &1)),
      do: :any,
      else: refs |> List.flatten() |> MapSet.new()
  end

  @doc """
  The document types a list row's preview of `schema` reads through a
  reference (`list_preview.subtitle: "author.name"`, or an `each` over a
  reference array), or `:any` when such a reference names none. A list of
  `schema`'s documents shows those documents' values, so a change of one of
  them changes its rows.
  """
  @spec preview_target_types(map()) :: MapSet.t(String.t()) | :any
  def preview_target_types(schema) do
    heads = preview_heads(Map.get(schema, :list_preview) || Map.get(schema, "list_preview"))

    fields =
      for %{"name" => name} = field <- Map.get(schema, :fields) || [],
          MapSet.member?(heads, name),
          do: field

    target_types(%{fields: fields})
  end

  # The first segment of every path the preview walks further (`author` of
  # `author.name` or `{author.name}`), and every `each` path.
  defp preview_heads(preview) when is_map(preview) or is_list(preview) do
    each = for {"each", path} <- flat(preview), is_binary(path), do: path

    dotted =
      for {_key, text} <- flat(preview),
          is_binary(text),
          [_, head] <- Regex.scan(~r/(?<![\w.])([A-Za-z_]\w*)(?:\.\d+)*\.[A-Za-z_]/, text),
          do: head

    MapSet.new(each ++ dotted)
  end

  defp preview_heads(_preview), do: MapSet.new()

  # Every key and string value of a nested spec, as `{key, value}`.
  defp flat(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> if is_binary(v), do: [{k, v}], else: flat(v) end)

  defp flat(list) when is_list(list),
    do: Enum.flat_map(list, fn v -> if is_binary(v), do: [{nil, v}], else: flat(v) end)

  defp flat(_value), do: []

  defp of_refs(%{"type" => type, "of" => of}) when type in ["arrayOf", "array"],
    do: for(%{"type" => "reference"} = ref <- List.wrap(of), do: ref)

  defp of_refs(_field), do: []

  defp to_name(name) when is_binary(name) and name != "", do: name
  defp to_name(%{"type" => name}) when is_binary(name) and name != "", do: name
  defp to_name(_to), do: nil

  @doc """
  The targets of every reference field of `doc`, by field name, in stored
  order. A target that cannot be read (deleted, or outside the caller's
  scope) keeps its id and has no type.
  """
  @spec resolve(map(), map(), String.t(), keyword()) :: %{optional(String.t()) => [target()]}
  def resolve(doc, schema, dataset, scope) do
    ids_by_field = ids(doc, schema)

    found = lookup(ids_by_field |> Map.values() |> List.flatten() |> Enum.uniq(), dataset, scope)
    schemas = schemas(found, dataset, scope)

    Map.new(ids_by_field, fn {name, ids} ->
      {name, Enum.map(ids, &target(&1, found[&1], schemas))}
    end)
  end

  # The schema of each type among the targets: one read per type.
  defp schemas(found, dataset, scope) do
    for %{type: type} when is_binary(type) <- Map.values(found), uniq: true, into: %{} do
      case Content.resolve_schema(type, dataset, scope) do
        {:ok, schema} -> {type, schema}
        _ -> {type, nil}
      end
    end
  end

  @doc """
  The ids every reference field of `doc` holds, by field name, in stored
  order. Read from the document alone: no query.
  """
  @spec ids(map(), map()) :: %{optional(String.t()) => [String.t()]}
  def ids(doc, schema) do
    content = Map.get(doc, :content) || %{}

    for {name, kind} <- fields(schema), into: %{} do
      values = if kind == :one, do: [content[name]], else: List.wrap(content[name])
      {name, values |> Enum.map(&ref_id/1) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc "The type of the document `id`, whatever it is, or nil when it cannot be read."
  @spec type_of(String.t(), String.t(), keyword()) :: String.t() | nil
  def type_of(id, dataset, scope) do
    case lookup([id], dataset, scope)[Content.published_id(id)] do
      %{type: type} -> type
      _ -> nil
    end
  end

  # Published id => the draft when there is one, else the published row.
  defp lookup([], _dataset, _scope), do: %{}

  defp lookup(ids, dataset, scope) do
    rows = Content.get_documents_by_ids(ids ++ Enum.map(ids, &("drafts." <> &1)), dataset, scope)

    Map.new(ids, fn id -> {id, rows["drafts." <> id] || rows[id]} end)
  end

  defp target(id, nil, _schemas), do: %{id: id, type: nil, title: id}

  defp target(id, doc, schemas) do
    title =
      TitleDerivation.preview_title(doc, schemas[doc.type]) ||
        if(is_binary(doc.title) and String.trim(doc.title) != "", do: doc.title, else: id)

    %{id: id, type: doc.type, title: title}
  end

  defp ref_id(%{"_ref" => id}) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(id) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(_value), do: nil
end
