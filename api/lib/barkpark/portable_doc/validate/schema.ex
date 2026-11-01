defmodule Barkpark.PortableDoc.Validate.Schema do
  @moduledoc """
  Compiles a JSON Schema into the nodes `Barkpark.PortableDoc.Validate` walks,
  the way `compile` in portable-doc's `packages/validate/index.js` does.

  Takes the schema decoded with `Jason.decode!(json, objects: :ordered_objects)`,
  so properties keep the file's order and errors come out in the JS order; plain
  maps work too. Raises `ArgumentError` on a schema the walk cannot follow: an
  unknown keyword or type, a non-primitive `const` or `enum` value, a non-array
  `enum`, or a `$ref` that does not resolve. A new rule in a synced schema then
  fails the compile instead of passing unchecked.

  A node's `at` is its place in the schema document. Two nodes are the same
  node exactly when their `at` is equal, which stands in for JS object identity:
  the root block is `at: []`.
  """

  @keywords ~w($schema $comment title description definitions type const enum minimum maximum
               required properties items allOf anyOf not if then $ref)
  @types ~w(object array string boolean number integer null)

  defstruct [:root, :refs, :type_at]

  @type t :: %__MODULE__{root: map(), refs: %{[String.t()] => map()}, type_at: [String.t()]}

  @spec compile(map()) :: t()
  def compile(root) do
    unless object?(root), do: raise(ArgumentError, "schema at # is not an object")
    refs = resolve(root, %{}, [[]])
    %__MODULE__{root: Map.fetch!(refs, []), refs: refs, type_at: ["properties", "type"]}
  end

  defp resolve(_root, refs, []), do: refs

  defp resolve(root, refs, [at | rest]) when is_map_key(refs, at), do: resolve(root, refs, rest)

  defp resolve(root, refs, [at | rest]) do
    {node, found} = build(lookup!(root, at), at, [])
    resolve(root, Map.put(refs, at, node), found ++ rest)
  end

  defp lookup!(root, at) do
    found = Enum.reduce(at, root, fn key, node -> if object?(node), do: get(node, key) end)

    if object?(found),
      do: found,
      else: raise(ArgumentError, "schema $ref #{show(at)} does not resolve")
  end

  defp build(raw, at, found) do
    unless object?(raw), do: raise(ArgumentError, "schema at #{show(at)} is not an object")
    audit!(raw, at)

    case fetch(raw, "$ref") do
      {:ok, ref} ->
        target = ref_at!(ref, at)
        {%{at: at, ref: target}, [target | found]}

      :error ->
        build_node(raw, at, found)
    end
  end

  defp build_node(raw, at, found) do
    {properties, found} =
      Enum.map_reduce(properties(raw, at), found, fn {key, child}, found ->
        {node, found} = build(child, at ++ ["properties", key], found)
        {{key, node}, found}
      end)

    {single, found} =
      Enum.reduce(~w(items not if then), {%{}, found}, fn key, {acc, found} ->
        case fetch(raw, key) do
          {:ok, child} ->
            {node, found} = build(child, at ++ [key], found)
            {Map.put(acc, key, node), found}

          :error ->
            {acc, found}
        end
      end)

    {all_of, found} = build_list(raw, "allOf", at, found)
    {any_of, found} = build_list(raw, "anyOf", at, found)

    node = %{
      at: at,
      ref: nil,
      type: raw |> get("type") |> then(&(&1 && List.wrap(&1))),
      const: fetch(raw, "const"),
      enum: get(raw, "enum"),
      minimum: get(raw, "minimum"),
      maximum: get(raw, "maximum"),
      required: required(raw, at),
      properties: properties,
      items: single["items"],
      not: single["not"],
      if: single["if"],
      then: single["then"],
      all_of: all_of || [],
      any_of: any_of
    }

    {node, found}
  end

  defp build_list(raw, key, at, found) do
    case get(raw, key) do
      nil ->
        {nil, found}

      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.map_reduce(found, fn {child, i}, found ->
          build(child, at ++ [key, Integer.to_string(i)], found)
        end)

      _ ->
        raise ArgumentError, "schema #{key} at #{show(at)} is not an array"
    end
  end

  defp properties(raw, at) do
    case get(raw, "properties") do
      nil ->
        []

      props ->
        if object?(props), do: entries(props), else: not_shaped!("properties", "an object", at)
    end
  end

  defp required(raw, at) do
    case get(raw, "required") do
      nil ->
        []

      keys ->
        if is_list(keys) and Enum.all?(keys, &is_binary/1),
          do: keys,
          else: not_shaped!("required", "a list of names", at)
    end
  end

  defp not_shaped!(key, shape, at),
    do: raise(ArgumentError, "schema #{key} at #{show(at)} is not #{shape}")

  defp audit!(raw, at) do
    for {key, _} <- entries(raw), not String.starts_with?(key, "x-"), key not in @keywords do
      raise ArgumentError, "unsupported schema keyword #{key} at #{show(at)}"
    end

    enum =
      case fetch(raw, "enum") do
        {:ok, list} when is_list(list) -> list
        {:ok, _} -> raise ArgumentError, "schema enum at #{show(at)} is not an array"
        :error -> []
      end

    consts =
      case fetch(raw, "const") do
        {:ok, value} -> [value]
        :error -> []
      end

    for value <- consts ++ enum, not primitive?(value) do
      raise ArgumentError,
            "unsupported schema const or enum value #{inspect(value)} at #{show(at)}"
    end

    for type <- List.wrap(get(raw, "type")), type not in @types do
      raise ArgumentError, "unsupported schema type #{inspect(type)} at #{show(at)}"
    end

    :ok
  end

  defp ref_at!("#" <> pointer, _at) do
    pointer
    |> String.split("/", trim: true)
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  defp ref_at!(ref, at),
    do: raise(ArgumentError, "schema $ref #{inspect(ref)} at #{show(at)} does not resolve")

  defp show(at), do: Enum.join(["#" | at], "/")

  defp primitive?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp object?(%Jason.OrderedObject{}), do: true
  defp object?(value), do: is_map(value) and not is_struct(value)

  defp entries(%Jason.OrderedObject{values: values}), do: values
  defp entries(map), do: Map.to_list(map)

  defp fetch(raw, key) do
    case List.keyfind(entries(raw), key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp get(raw, key) do
    case fetch(raw, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
