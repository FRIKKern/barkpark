defmodule BarkparkWeb.Studio.Desk.Refs do
  @moduledoc """
  The documents a desk-slice document points at, so its pane can offer each
  reference as a link that opens the target in the next pane (the TanStack
  Studio's endless pane chain).

  A reference is stored as `%{"_ref" => id}` or, on older rows, a bare id
  string. A reference field is `type: "reference"`; an array of them is
  `type: "arrayOf"` (or `"array"`) whose `of` is, or holds, a reference.
  All targets of one document are read in one query, whatever their types.
  """

  alias Barkpark.Content

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

    Map.new(ids_by_field, fn {name, ids} ->
      {name, Enum.map(ids, &target(&1, found[&1]))}
    end)
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

  defp target(id, nil), do: %{id: id, type: nil, title: id}

  defp target(id, doc) do
    title = if is_binary(doc.title) and String.trim(doc.title) != "", do: doc.title, else: id
    %{id: id, type: doc.type, title: title}
  end

  defp ref_id(%{"_ref" => id}) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(id) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(_value), do: nil
end
