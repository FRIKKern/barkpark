defmodule Barkpark.Content.SchemaDefinition.ArrayOfCheck do
  @moduledoc """
  An `arrayOf` must say what its items are (task-33f3ce6c95c48851).

  `SchemaDefinition.parse/2` refuses an `arrayOf` whose `of` is missing, not
  a map or a list, an empty list, or a shape with no string `type`
  (`array_missing_of`, `field_type_must_be_string`). `/v1/schemas` runs it
  before the write, but every other door writes through
  `Content.upsert_schema/3` alone (workspace schema provisioning, the tag
  registry, plugin bootstrap, seeds) and stored such a schema, and then:

    * `Content.Validation` could not parse it and fell back to the legacy
      validator, so every composite, arrayOf and localizedText check was off
      for that type's documents;
    * the editor drew the array as strings (no `of`) or crashed on open (an
      untyped `of`, task-04004b6d634dd535).

  `problems/1` names each such array by its path (`seo.links`,
  `rows[].tags`), at any depth, in exactly the places `parse/2` parses:
  a composite's, image's or file's `fields`, an `arrayOf`'s `of` shape and
  each member of an `of` list. The changeset runs it only
  on a changed `fields` list, so an unrelated update to a stored row is
  never blocked.
  """

  # The types whose `fields` `SchemaDefinition.parse/2` parses as fields.
  @with_fields ~w(composite image file)

  @doc "One message per `arrayOf` whose `of` names no item type, by path."
  @spec problems([map()]) :: [String.t()]
  def problems(fields) when is_list(fields) do
    fields
    |> paths([])
    |> Enum.map(fn {path, why} -> ~s("#{path}": #{why}) end)
  end

  def problems(_fields), do: []

  defp paths(fields, prefix) when is_list(fields) do
    Enum.flat_map(fields, fn
      %{} = field ->
        name = to_string(get(field, "name") || "?")
        field_paths(field, prefix ++ [name])

      _other ->
        []
    end)
  end

  defp paths(_fields, _prefix), do: []

  # A field, or an `of` shape at `at` (a shape has no name of its own).
  defp field_paths(field, at) do
    path = Enum.join(at, ".")
    item = List.update_at(at, -1, &(&1 <> "[]"))

    case get(field, "type") do
      "arrayOf" ->
        own = Enum.map(of_problems(get(field, "of")), &{path, &1})

        shapes =
          case get(field, "of") do
            %{} = shape -> field_paths(shape, item)
            list when is_list(list) -> Enum.flat_map(list, &member_paths(&1, item))
            _ -> []
          end

        own ++ shapes

      type when type in @with_fields ->
        paths(get(field, "fields"), at)

      # Any other type's `fields` or `of` is not parsed (`parse_field_type`),
      # so it is not read here either: an `object` or a legacy `array` passes
      # `/v1/schemas` and this check alike.
      _ ->
        []
    end
  end

  defp member_paths(%{} = member, item), do: field_paths(member, item)
  defp member_paths(_member, _item), do: []

  defp of_problems(nil), do: ["an arrayOf needs `of`, the type of its items"]
  defp of_problems([]), do: ["an arrayOf needs `of`, the type of its items"]

  defp of_problems(%{} = shape) do
    if typed?(shape),
      do: [],
      else: [
        "`of` needs a string `type` (for an array of strings: `\"of\": {\"type\": \"string\"}`)"
      ]
  end

  defp of_problems(list) when is_list(list) do
    if Enum.all?(list, &(is_map(&1) and typed?(&1))),
      do: [],
      else: ["each member of `of` needs a string `type`"]
  end

  defp of_problems(_other), do: ["`of` must be an object with a `type`, or a list of them"]

  defp typed?(shape), do: is_binary(get(shape, "type")) and get(shape, "type") != ""

  # The keys are fixed literals, so a fixed map gives the atom form and no
  # string is ever turned into a new atom (Sobelow DOS.StringToAtom).
  @atoms %{"name" => :name, "type" => :type, "of" => :of, "fields" => :fields}

  defp get(map, key), do: Map.get(map, key, Map.get(map, Map.fetch!(@atoms, key)))
end
