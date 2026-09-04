defmodule BarkparkWeb.Studio.StudioLive.Path do
  @moduledoc """
  Path-based navigation for nested `arrayOf` inside composites, extracted from
  `BarkparkWeb.Studio.StudioLive`. Pure string→key-list parsing
  (`parse_path/1`), schema descent (`field_at/2`), and the hand-rolled
  get/put on the editor form (`list_value_at/2`, `put_value_at/3`,
  `empty_for_of/1`). No socket — the schema-side entry point takes the
  `editor_schema` fields list directly.

  The ArrayField component emits `phx-value-path` on every reorder button.
  The string has the shape `doc[a][b].c[d]` — top-level uses bracket form
  (from `Studio.Plugins.Adapter.render/2`: `"doc[<name>]"`), composite descents use dot
  form (from composite_field.ex `child_path`: `"<parent>.<child>"`),
  and array rows append `[<idx>]`. We strip the `doc[` envelope, then
  tokenize on `]` / `.` / `[` to recover the key list.

  Numeric segments (array row indices) are PRESERVED as Elixir integers
  so the data-access helpers (`do_get_in`, `put_value_at`) can descend
  into lists via `Enum.at` / `List.replace_at`. The schema-descent helper
  (`descend_field`) skips integer segments because the schema has no
  per-row variation — an integer in the path tells us "we're inside an
  arrayOf row," not which schema field to resolve to.

  Without the integer being preserved, walking
  `productSupplies[0].market.territory.countries` would replace the
  `productSupplies` list with a `%{"market" => …}` map — catastrophic
  data corruption. See barkpark-i2d4.
  """

  @doc false
  def parse_path("doc[" <> rest), do: parse_brackets(rest, [])
  def parse_path(""), do: []

  def parse_path(other) when is_binary(other) do
    # Accept paths from nested array_field / composite_field components
    # that don't carry the doc[ envelope. Routes through parse_dots so
    # brackets and dots both work, e.g.
    # `productSupplies[0].market.territory.countries`.
    parse_dots(other, [])
  end

  def parse_path(_), do: []

  defp parse_brackets("", acc), do: Enum.reverse(convert_indices(acc))

  defp parse_brackets(rest, acc) do
    case String.split(rest, "]", parts: 2) do
      [key, "[" <> more] -> parse_brackets(more, [key | acc])
      [key, "." <> more] -> parse_dots(more, [key | acc])
      [key, ""] -> Enum.reverse(convert_indices([key | acc]))
      _ -> Enum.reverse(convert_indices(acc))
    end
  end

  defp parse_dots(rest, acc) do
    case String.split(rest, ~r/[\.\[]/, parts: 2, include_captures: true) do
      [key, ".", more] -> parse_dots(more, [key | acc])
      [key, "[", more] -> parse_brackets(more, [key | acc])
      [key] when key != "" -> Enum.reverse(convert_indices([key | acc]))
      _ -> Enum.reverse(convert_indices(acc))
    end
  end

  # Drop empty segments (from malformed input like `doc[]`) and convert
  # numeric strings to Elixir integers in place. Integers stay in the path
  # so `put_value_at` / `do_get_in` can descend into list rows; named-field
  # resolution (`descend_field`) skips them.
  defp convert_indices(acc) do
    acc
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn s ->
      if is_binary(s) do
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> s
        end
      else
        s
      end
    end)
  end

  # Walk a schema `fields` list by string-keyed name to find the field at the
  # deepest path position. `descend_field` traverses composite → fields and
  # arrayOf → of transparently so the caller's path doesn't need to mention
  # the `of` envelope. Integer segments (array row indices) are consumed
  # transparently — they carry no schema meaning.
  @doc false
  def field_at(fields, [head | rest]) when is_integer(head) do
    # Defensive: a path starting with an integer is nonsensical at the
    # schema root, but if it ever happens we just skip it and continue.
    field_at(fields, rest)
  end

  def field_at(fields, [head | rest]) when is_list(fields) do
    case Enum.find(fields, fn f -> Map.get(f, "name") == head end) do
      nil -> nil
      f -> descend_field(f, rest)
    end
  end

  def field_at(_, []), do: nil
  def field_at(_, _), do: nil

  defp descend_field(field, []), do: field

  defp descend_field(field, [head | rest]) when is_integer(head) do
    # An integer index = "we're inside an arrayOf row." Drop it; the
    # schema-side descent stays on the named-field axis. The arrayOf
    # clause below will collapse `arrayOf → of` automatically if the
    # next segment is named.
    descend_field(field, rest)
  end

  defp descend_field(%{"type" => "composite", "fields" => subs}, [head | rest])
       when is_list(subs) do
    case Enum.find(subs, fn s -> Map.get(s, "name") == head end) do
      nil -> nil
      s -> descend_field(s, rest)
    end
  end

  defp descend_field(%{"type" => "arrayOf", "of" => of}, path), do: descend_field(of, path)
  defp descend_field(_, _), do: nil

  # Read the list value at the path from editor_form.
  @doc false
  def list_value_at(form, path) when is_list(path) do
    case do_get_in(form, path) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Hand-rolled get_in that tolerates nil/non-map intermediates and walks
  # both maps (string-keyed) and lists (integer-indexed).
  defp do_get_in(value, []), do: value

  defp do_get_in(list, [idx | rest]) when is_list(list) and is_integer(idx) do
    case Enum.at(list, idx) do
      nil -> nil
      v -> do_get_in(v, rest)
    end
  end

  defp do_get_in(map, [key | rest]) when is_map(map),
    do: do_get_in(Map.get(map, key), rest)

  defp do_get_in(_, _), do: nil

  # Write the list value at the path in editor_form. Initializes missing
  # intermediate maps along the way so adding a row to a yet-unset nested
  # arrayOf works on first click. Integer segments descend into lists via
  # List.replace_at — out-of-bounds indices return the list unchanged
  # rather than corrupting the structure.
  @doc false
  def put_value_at(form, [], _value), do: form
  def put_value_at(nil, [key], value) when is_binary(key), do: %{key => value}
  def put_value_at(form, [key], value) when is_binary(key), do: Map.put(form || %{}, key, value)

  def put_value_at(list, [idx], value) when is_list(list) and is_integer(idx) do
    if idx >= 0 and idx < length(list) do
      List.replace_at(list, idx, value)
    else
      list
    end
  end

  def put_value_at(list, [idx | rest], value) when is_list(list) and is_integer(idx) do
    case Enum.at(list, idx) do
      nil ->
        # Out-of-bounds — leave the list alone. Better silent no-op than
        # auto-extending with placeholders the schema didn't ask for.
        list

      existing ->
        List.replace_at(list, idx, put_value_at(existing, rest, value))
    end
  end

  def put_value_at(form, [head | rest], value) when is_binary(head) do
    inner =
      case form do
        %{} -> Map.get(form, head)
        _ -> nil
      end

    cond do
      # If the existing value at `head` is a list and the next path step
      # is a string key (not an integer index), the caller's path is
      # malformed for the data shape. Silently leave the list alone
      # rather than replacing it with a map (the pre-fix data-loss bug).
      is_list(inner) and rest != [] and is_binary(hd(rest)) ->
        form || %{}

      true ->
        base =
          case inner do
            %{} -> inner
            list when is_list(list) -> list
            _ -> %{}
          end

        Map.put(form || %{}, head, put_value_at(base, rest, value))
    end
  end

  # Anything else (e.g. integer head into a non-list form) → no-op.
  def put_value_at(form, _, _), do: form

  # Empty-element factory — picks a sensible default for a freshly-added row
  # based on the arrayOf element's declared type. composite → empty map;
  # arrayOf → empty list; localizedText → empty map; everything else → nil.
  @doc false
  # A new composite row is seeded with each subfield's declared `default`
  # (Sanity's `initialValue` on an array member — Gyldendal parity E1.5), so a
  # freshly added feature card already reads linkType=document / variant=auto
  # instead of every select sitting on "— Select —".
  def empty_for_of(%{"of" => %{"type" => "composite"} = of}) do
    Enum.reduce(of["fields"] || [], %{}, fn sub, acc ->
      Map.put(acc, sub["name"], Map.get(sub, "default", empty_for_type(sub["type"])))
    end)
  end

  def empty_for_of(%{"of" => %{"type" => "arrayOf"}}), do: []
  def empty_for_of(%{"of" => %{"type" => "codelist"}}), do: nil
  def empty_for_of(%{"of" => %{"type" => "localizedText"}}), do: %{}
  def empty_for_of(%{"of" => %{"type" => _}}), do: nil
  def empty_for_of(_), do: nil

  defp empty_for_type("composite"), do: %{}
  defp empty_for_type("arrayOf"), do: []
  defp empty_for_type("localizedText"), do: %{}
  # strings, codelists, booleans, datetimes, etc. — all start as nil so the
  # validator surfaces "required" errors instead of fake-empty values.
  defp empty_for_type(_), do: nil
end
