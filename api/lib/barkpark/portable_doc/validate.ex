defmodule Barkpark.PortableDoc.Validate do
  @moduledoc """
  Barkpark's answer to "is this a PortableDoc?": the same refusals, codes,
  JSON-pointer paths and order as `@portable-doc/validate`
  (FRIKKern/portable-doc `packages/validate/index.js`, codes in its `CODES.md`).

  **Report-only.** Nothing calls it on a write yet; turning it on is a later
  decision.

  The checks come from `priv/portable_doc/spec/blocks.schema.json`, the schema
  the JS validator reads, compiled once at build time by
  `Barkpark.PortableDoc.Validate.Schema`. A schema keyword the walk cannot follow
  fails the build. Two checks are Barkpark's own: `portable_text_block`
  (`portable_text_block?/1`, which `Content.Validation` uses too) and
  `duplicate_block_id`.

  The walk reaches only what the schema describes; open fields are not checked.
  Every error is reported. Top-level blocks are depth 0; a block reached at
  depth `max_depth/0` gets only `too_deep` and nothing in or under it is
  checked, not even whether it is an object, and its `id` does not count toward
  duplicates. The Portable Text check runs first on every value the walk
  reaches, so a Portable Text block at that depth gets `portable_text_block`
  instead of `too_deep`, exactly as in the JS.
  """

  alias Barkpark.PortableDoc.Spec
  alias Barkpark.PortableDoc.Validate.Schema

  @codes ~w(not_a_doc block_not_object portable_text_block missing_required_field
            unknown_block_type wrong_field_type value_not_allowed duplicate_block_id too_deep)a
  @max_depth 100

  @external_resource Spec.path()
  @schema Spec.path()
          |> File.read!()
          |> Jason.decode!(objects: :ordered_objects)
          |> Schema.compile()

  @type code ::
          :not_a_doc
          | :block_not_object
          | :portable_text_block
          | :missing_required_field
          | :unknown_block_type
          | :wrong_field_type
          | :value_not_allowed
          | :duplicate_block_id
          | :too_deep
  @type error :: %{code: code(), path: String.t()}

  @spec codes() :: [code()]
  def codes, do: @codes

  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "A Sanity Portable Text block: `_type: \"block\"` with `children`, `markDefs` or `listItem`."
  @spec portable_text_block?(term()) :: boolean()
  def portable_text_block?(%{"_type" => "block"} = value),
    do: Enum.any?(~w(children markDefs listItem), &Map.has_key?(value, &1))

  def portable_text_block?(_value), do: false

  @doc "Validates a decoded JSON doc: a blocks array, or an object with a `blocks` array."
  @spec validate(term(), Schema.t()) :: :ok | {:error, [error()]}
  def validate(doc, schema \\ @schema)

  def validate(blocks, schema) when is_list(blocks), do: walk(blocks, "", schema)

  def validate(%{"blocks" => blocks}, schema) when is_list(blocks),
    do: walk(blocks, "/blocks", schema)

  def validate(doc, _schema) when is_map(doc),
    do: {:error, [%{code: :not_a_doc, path: "/blocks"}]}

  def validate(_doc, _schema), do: {:error, [%{code: :not_a_doc, path: ""}]}

  defp walk(blocks, base, schema) do
    {errors, ids} =
      blocks
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {block, i}, acc ->
        check(block, schema.root, pointer(base, i), 0, schema, acc)
      end)

    case Enum.reverse(errors, duplicates(Enum.reverse(ids))) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp duplicates(ids) do
    {dups, _first} =
      Enum.reduce(ids, {[], MapSet.new()}, fn {id, path}, {dups, seen} ->
        if MapSet.member?(seen, id),
          do: {[%{code: :duplicate_block_id, path: path} | dups], seen},
          else: {dups, MapSet.put(seen, id)}
      end)

    Enum.reverse(dups)
  end

  defp check(value, node, path, depth, schema, acc) do
    target = deref(node, schema)

    cond do
      portable_text_block?(value) -> error(acc, :portable_text_block, path)
      target.at == [] -> check_block(value, path, depth, schema, acc)
      true -> check_node(value, target, path, depth, schema, acc)
    end
  end

  defp check_block(_value, path, @max_depth, _schema, acc), do: error(acc, :too_deep, path)

  defp check_block(value, path, _depth, _schema, acc) when not is_map(value),
    do: error(acc, :block_not_object, path)

  defp check_block(value, path, depth, schema, {errors, ids}) do
    ids =
      case value do
        %{"id" => id} when is_binary(id) and id != "" -> [{id, pointer(path, "id")} | ids]
        _ -> ids
      end

    check_node(value, schema.root, path, depth + 1, schema, {errors, ids})
  end

  defp check_node(value, node, path, depth, schema, acc) do
    if node.type && not accepts?(node, value, schema) do
      error(acc, :wrong_field_type, path)
    else
      acc
      |> check_values(value, node, path, schema)
      |> check_fields(value, node, path, depth, schema)
      |> check_items(value, node, path, depth, schema)
      |> check_all_of(value, node, path, depth, schema)
      |> check_if_then(value, node, path, depth, schema)
      |> check_any_of(value, node, path, depth, schema)
      |> check_not(value, node, path, depth, schema)
    end
  end

  defp check_values(acc, value, node, path, schema) do
    acc
    |> error_if(match?({:ok, c} when c != value, node.const), :value_not_allowed, path)
    |> error_if(
      node.enum != nil and not Enum.any?(node.enum, &(&1 == value)),
      if(node.at == schema.type_at, do: :unknown_block_type, else: :value_not_allowed),
      path
    )
    |> error_if(
      is_number(value) and node.minimum != nil and value < node.minimum,
      :value_not_allowed,
      path
    )
    |> error_if(
      is_number(value) and node.maximum != nil and value > node.maximum,
      :value_not_allowed,
      path
    )
  end

  defp check_fields(acc, value, node, path, depth, schema) when is_map(value) do
    acc =
      Enum.reduce(node.required, acc, fn key, acc ->
        error_if(acc, not Map.has_key?(value, key), :missing_required_field, pointer(path, key))
      end)

    Enum.reduce(node.properties, acc, fn {key, child}, acc ->
      case value do
        %{^key => field} -> check(field, child, pointer(path, key), depth, schema, acc)
        _ -> acc
      end
    end)
  end

  defp check_fields(acc, _value, _node, _path, _depth, _schema), do: acc

  defp check_items(acc, value, %{items: items}, path, depth, schema)
       when is_list(value) and items != nil do
    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, i}, acc ->
      check(item, items, pointer(path, i), depth, schema, acc)
    end)
  end

  defp check_items(acc, _value, _node, _path, _depth, _schema), do: acc

  defp check_all_of(acc, value, node, path, depth, schema),
    do: Enum.reduce(node.all_of, acc, &check(value, &1, path, depth, schema, &2))

  defp check_if_then(acc, value, %{if: if_node, then: then} = _node, path, depth, schema)
       when if_node != nil and then != nil do
    if passes?(trial(value, if_node, path, depth, schema)),
      do: check(value, then, path, depth, schema, acc),
      else: acc
  end

  defp check_if_then(acc, _value, _node, _path, _depth, _schema), do: acc

  defp check_any_of(acc, _value, %{any_of: nil}, _path, _depth, _schema), do: acc

  defp check_any_of(acc, value, %{any_of: branches}, path, depth, schema) do
    trials = Enum.map(branches, &{&1, trial(value, &1, path, depth, schema)})

    case Enum.find(trials, fn {_branch, result} -> passes?(result) end) ||
           Enum.find(trials, fn {branch, _result} -> accepts?(branch, value, schema) end) do
      {_branch, result} -> merge(acc, result)
      nil -> error(acc, :wrong_field_type, path)
    end
  end

  defp check_not(acc, _value, %{not: nil}, _path, _depth, _schema), do: acc

  defp check_not(acc, value, %{not: not_node}, path, depth, schema),
    do:
      error_if(
        acc,
        passes?(trial(value, not_node, path, depth, schema)),
        :value_not_allowed,
        path
      )

  defp accepts?(node, value, schema) do
    target = deref(node, schema)

    cond do
      target.type -> Enum.any?(target.type, &type?(&1, value))
      match?({:ok, _}, target.const) -> js_typeof(elem(target.const, 1)) == js_typeof(value)
      target.enum -> Enum.any?(target.enum, &(js_typeof(&1) == js_typeof(value)))
      true -> true
    end
  end

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("number", value), do: is_number(value)

  defp type?("integer", value),
    do: is_integer(value) or (is_float(value) and value == trunc(value))

  defp type?("null", value), do: is_nil(value)

  defp js_typeof(value) when is_binary(value), do: :string
  defp js_typeof(value) when is_number(value), do: :number
  defp js_typeof(value) when is_boolean(value), do: :boolean
  defp js_typeof(_value), do: :object

  defp deref(%{ref: nil} = node, _schema), do: node
  defp deref(%{ref: at}, schema), do: deref(Map.fetch!(schema.refs, at), schema)

  defp trial(value, node, path, depth, schema),
    do: check(value, node, path, depth, schema, {[], []})

  defp passes?({errors, _ids}), do: errors == []

  defp merge({errors, ids}, {more_errors, more_ids}), do: {more_errors ++ errors, more_ids ++ ids}

  defp error_if(acc, true, code, path), do: error(acc, code, path)
  defp error_if(acc, false, _code, _path), do: acc

  defp error({errors, ids}, code, path), do: {[%{code: code, path: path} | errors], ids}

  defp pointer(path, key) when is_integer(key), do: pointer(path, Integer.to_string(key))

  defp pointer(path, key),
    do: path <> "/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))
end
