defmodule BarkparkWeb.Studio.EditorSchema do
  @moduledoc """
  The schema the Studio editor works from, made from the stored one when a
  document opens (`Shared.rebuild_panes/1`).

  1. A content plugin's chrome in the Studio language
     (`PluginSchemaCopy.localize/1`).
  2. An array declared with a LIST of one plain-value member,
     `"of" => [%{"type" => "string"}]` (Sanity's shape), reads as the single
     member, `"of" => %{"type" => "string"}` (task-7655868c8b346c43).

  The editor reads a list-shaped `of` as several named OBJECT members, each
  row a map with `_type` and `_key`. A list of one `string` is not that: its
  rows are plain strings. Read as objects, "Add item" made the row
  `{"_key": …, "_type": "string"}`, drawn read-only with no input, and saved
  that object where a string belongs. Rows already holding strings were
  read-only too.

  Only the editor's copy changes: the stored schema, the stored documents and
  every other reader of the schema keep the list. A member that is an object,
  a reference, an image or a named type is left alone, and so is a list of
  two or more members.
  """

  alias BarkparkWeb.Studio.PluginSchemaCopy

  # The member types whose rows are plain values, one input each.
  @plain ~w(string text number boolean url email date datetime)

  @doc "The editor's schema for a stored `schema` (nil stays nil)."
  def load(%{fields: fields} = schema) when is_list(fields) do
    schema = PluginSchemaCopy.localize(schema)
    %{schema | fields: Enum.map(schema.fields || [], &field/1)}
  end

  def load(schema), do: PluginSchemaCopy.localize(schema)

  @doc false
  def field(%{"type" => "arrayOf", "of" => [%{"type" => type} = member]} = field)
      when type in @plain and not is_map_key(member, "fields"),
      do: Map.put(field, "of", member)

  def field(%{} = field) do
    field
    |> nested("fields")
    |> nested("of")
  end

  def field(other), do: other

  defp nested(field, key) do
    case Map.get(field, key) do
      list when is_list(list) -> Map.put(field, key, Enum.map(list, &field/1))
      %{} = one -> Map.put(field, key, field(one))
      _ -> field
    end
  end
end
