defmodule Barkpark.Content.EmptyListMembers do
  @moduledoc """
  Finds empty rows in scalar and reference list fields, so publish can refuse
  them (owner ruling #47, task-fe2dcfc7cb681922).

  Studio keeps a freshly added list row as `null` in the draft, so the row
  survives the next autosave while the editor fills it in. Publish used to copy
  that `null` (or an empty string, or a reference with no target) to the
  public API, and a site that loops over the list crashed on it. Publish now
  refuses with one message per empty row, for example
  `Keywords row 3 is empty, fill it in or remove it`. Drafts are untouched.

  Checked: `arrayOf` (and Sanity-style `array`) fields whose members are a
  scalar type or a `reference`, at the top level and inside `composite`
  fields. Lists of objects are not checked here; their subfields carry their
  own rules.
  """

  @scalar_types ~w(string text number url email date datetime slug codelist boolean)
  @list_types ~w(arrayOf array)

  @typedoc "One empty row: the top-level field it belongs to, its row index and the message."
  @type finding :: %{field: String.t(), index: non_neg_integer(), message: String.t()}

  @doc """
  Every empty member in `content` per the schema's field list. `schema` is a
  `%Barkpark.Content.Schema{}` or any map with a `fields` (or `"fields"`) list
  of string-keyed field maps. Returns `[]` when there is nothing to report.
  """
  @spec findings(map() | nil, map() | nil) :: [finding()]
  def findings(content, schema) when is_map(content) and is_map(schema) do
    schema
    |> fields_of()
    |> Enum.flat_map(fn field -> field_findings(field, content, nil, field) end)
  end

  def findings(_content, _schema), do: []

  @doc """
  The findings as the flat error map the write doors return in a 422
  `validation_failed` body: `%{field => [message, ...]}`.
  """
  @spec error_map([finding()]) :: %{optional(String.t()) => [String.t()]}
  def error_map(findings) do
    Enum.reduce(findings, %{}, fn %{field: f, message: m}, acc ->
      Map.update(acc, f, [m], &(&1 ++ [m]))
    end)
  end

  defp fields_of(%{fields: fields}) when is_list(fields), do: fields
  defp fields_of(%{"fields" => fields}) when is_list(fields), do: fields
  defp fields_of(_), do: []

  defp field_findings(%{"type" => type, "name" => name} = field, content, prefix, top)
       when is_binary(name) and is_map(content) do
    value = Map.get(content, name)
    label = join_label(prefix, label(field))

    cond do
      type in @list_types and is_list(value) and member_kind(field) != nil ->
        kind = member_kind(field)

        value
        |> Enum.with_index()
        |> Enum.filter(fn {member, _} -> empty?(member, kind) end)
        |> Enum.map(fn {_member, idx} ->
          %{
            field: top["name"],
            index: idx,
            message: "#{label} row #{idx + 1} is empty, fill it in or remove it"
          }
        end)

      type == "composite" and is_map(value) and is_list(field["fields"]) ->
        Enum.flat_map(field["fields"], &field_findings(&1, value, label, top))

      true ->
        []
    end
  end

  defp field_findings(_field, _content, _prefix, _top), do: []

  # :scalar | :reference | nil (a list this check leaves alone).
  defp member_kind(%{"of" => %{"type" => t}}), do: kind_of(t)

  defp member_kind(%{"of" => [_ | _] = descriptors}) do
    kinds = descriptors |> Enum.map(&(is_map(&1) && kind_of(&1["type"]))) |> Enum.uniq()

    case kinds do
      [kind] when kind in [:scalar, :reference] -> kind
      _ -> nil
    end
  end

  defp member_kind(_), do: nil

  defp kind_of("reference"), do: :reference
  defp kind_of(t) when t in @scalar_types, do: :scalar
  defp kind_of(_), do: nil

  defp empty?(nil, _kind), do: true
  defp empty?(s, _kind) when is_binary(s), do: String.trim(s) == ""

  defp empty?(%{} = ref, :reference) do
    case Map.get(ref, "_ref") || Map.get(ref, "ref") do
      r when is_binary(r) -> String.trim(r) == ""
      _ -> true
    end
  end

  defp empty?(_member, _kind), do: false

  defp label(field) do
    case field["title"] do
      t when is_binary(t) and t != "" -> t
      _ -> humanize(field["name"])
    end
  end

  defp humanize(name) do
    name
    |> String.replace(~r/[_-]+/, " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.capitalize()
  end

  defp join_label(nil, label), do: label
  defp join_label(prefix, label), do: "#{prefix} › #{label}"
end
