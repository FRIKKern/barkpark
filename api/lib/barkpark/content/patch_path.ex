defmodule Barkpark.Content.PatchPath do
  @moduledoc """
  Sanity-style paths for `patch` ops (task-bfb66a2ff491f6e7).

  A patch key that contains `.` or `[` is a path into the document instead of
  a top-level field name:

      seo.metaTitle                 a key inside the `seo` object
      body[_key=="b1"].text         a field of the array item whose `_key` is b1
      tags[0]   tags[-1]            an array item by index (negative counts from the end)

  Keys without `.` or `[` keep the old top-level meaning, so existing patches
  are unchanged.

  Semantics follow Sanity's mutation API: `set` and `inc`/`dec` create missing
  intermediate objects; a selector that matches no array item leaves the
  document unchanged (the caller gets a `patch.path_unmatched` warning so the
  miss is visible); walking a key into a string, number or list is refused,
  as is a path that does not parse. `unset` on an array item removes the item.
  `insert` places items `before`/`after` an array item, or `replace`s it.
  """

  @type segment :: {:key, String.t()} | {:keyed, String.t()} | {:index, integer()}
  @type error :: {:error, String.t()}

  @doc "True when `key` is a path rather than a plain top-level field name."
  @spec path?(term()) :: boolean()
  def path?(key) when is_binary(key), do: String.contains?(key, [".", "["])
  def path?(_), do: false

  @doc "The first key of a path — the top-level field it writes under."
  @spec root(String.t()) :: String.t()
  def root(path), do: path |> String.split([".", "["], parts: 2) |> hd()

  @doc """
  Parse a path into segments. The first segment is always a key.
  """
  @spec parse(String.t()) :: {:ok, [segment]} | error
  def parse(path) when is_binary(path) do
    case take_key(path) do
      {:ok, key, rest} when key != "" -> parse_rest(rest, [{:key, key}], path)
      _ -> bad(path, "it must start with a field name")
    end
  end

  def parse(path), do: bad(inspect(path), "a path must be a string")

  defp parse_rest("", acc, _path), do: {:ok, Enum.reverse(acc)}

  defp parse_rest("." <> rest, acc, path) do
    case take_key(rest) do
      {:ok, key, rest} when key != "" -> parse_rest(rest, [{:key, key} | acc], path)
      _ -> bad(path, "a `.` must be followed by a field name")
    end
  end

  defp parse_rest("[" <> rest, acc, path) do
    with [selector, rest] <- String.split(rest, "]", parts: 2),
         {:ok, seg} <- parse_selector(String.trim(selector)) do
      parse_rest(rest, [seg | acc], path)
    else
      _ -> bad(path, ~s(a `[...]` selector must be `_key=="…"` or an integer index))
    end
  end

  defp parse_rest(_rest, _acc, path), do: bad(path, "unexpected character after a segment")

  defp take_key(str) do
    case Regex.run(~r/^([^.\[\]"'\s]*)(.*)$/s, str) do
      [_, key, rest] -> {:ok, key, rest}
      _ -> :error
    end
  end

  defp parse_selector(sel) do
    cond do
      m = Regex.run(~r/^_key\s*==\s*"([^"]*)"$/, sel) -> {:ok, {:keyed, Enum.at(m, 1)}}
      m = Regex.run(~r/^_key\s*==\s*'([^']*)'$/, sel) -> {:ok, {:keyed, Enum.at(m, 1)}}
      Regex.match?(~r/^-?\d+$/, sel) -> {:ok, {:index, String.to_integer(sel)}}
      true -> :error
    end
  end

  defp bad(path, why), do: {:error, "path #{inspect(path)} is not valid: #{why}"}

  # ── Reads and writes ───────────────────────────────────────────────────────
  #
  # Every writer returns {:ok, data}, :unmatched (a selector found no item, or
  # an index was out of range) or {:error, message} (the path walks into a
  # value that cannot hold it).

  @doc "Read the value at `segs`; `:unmatched` when any step is absent."
  @spec get(term(), [segment]) :: {:ok, term()} | :unmatched
  def get(data, []), do: {:ok, data}

  def get(data, [seg | rest]) do
    case locate(data, seg) do
      {:ok, child} -> get(child, rest)
      _ -> :unmatched
    end
  end

  @doc """
  Apply `fun` to the value at `segs`. `fun` receives `{:ok, value}` or
  `:absent` and returns `{:put, value}`, `:delete` or `:keep`. Missing map keys
  on the way down are created as empty objects when `create?` is true.
  """
  @spec update(term(), [segment], boolean(), (term() -> term())) ::
          {:ok, term()} | :unmatched | error
  def update(data, [seg], _create?, fun), do: update_leaf(data, seg, fun)

  def update(data, [seg | rest], create?, fun) do
    case locate(data, seg) do
      {:ok, child} ->
        with {:ok, new_child} <- update(child, rest, create?, fun),
             do: replace_child(data, seg, new_child)

      :absent_key when create? ->
        with {:ok, new_child} <- update(%{}, rest, create?, fun),
             do: replace_child(data, seg, new_child)

      :absent_key ->
        :unmatched

      other ->
        other
    end
  end

  defp update_leaf(data, {:key, k}, fun) when is_map(data) do
    current = if Map.has_key?(data, k), do: {:ok, Map.fetch!(data, k)}, else: :absent

    case fun.(current) do
      {:put, v} -> {:ok, Map.put(data, k, v)}
      :delete -> {:ok, Map.delete(data, k)}
      :keep -> {:ok, data}
      {:error, _} = e -> e
    end
  end

  defp update_leaf(data, {tag, _} = seg, fun) when is_list(data) and tag != :key do
    case item_index(data, seg) do
      nil ->
        :unmatched

      i ->
        case fun.({:ok, Enum.at(data, i)}) do
          {:put, v} -> {:ok, List.replace_at(data, i, v)}
          :delete -> {:ok, List.delete_at(data, i)}
          :keep -> {:ok, data}
          {:error, _} = e -> e
        end
    end
  end

  defp update_leaf(data, seg, _fun), do: not_a_container(data, seg)

  @doc """
  Insert `items` relative to the array item at `segs` (`:before`, `:after`) or
  in its place (`:replace`). The last segment must select an array item.
  """
  @spec insert(term(), [segment], :before | :after | :replace, list()) ::
          {:ok, term()} | :unmatched | error
  def insert(data, segs, position, items) when is_list(items) do
    {parent_segs, [last]} = Enum.split(segs, -1)

    if match?({:key, _}, last) do
      {:error, "an insert path must end in an array item selector such as [_key==\"…\"] or [-1]"}
    else
      update_container(data, parent_segs, fn
        list when is_list(list) ->
          case item_index(list, last) do
            nil ->
              :unmatched

            i ->
              {before, [item | after_]} = Enum.split(list, i)

              case position do
                :before -> {:ok, before ++ items ++ [item | after_]}
                :after -> {:ok, before ++ [item | items] ++ after_}
                :replace -> {:ok, before ++ items ++ after_}
              end
          end

        other ->
          not_a_container(other, last)
      end)
    end
  end

  # Walk to the value at `segs` (without creating anything) and transform it.
  defp update_container(data, [], fun), do: fun.(data)

  defp update_container(data, [seg | rest], fun) do
    case locate(data, seg) do
      {:ok, child} ->
        with {:ok, new_child} <- update_container(child, rest, fun),
             do: replace_child(data, seg, new_child)

      :absent_key ->
        :unmatched

      other ->
        other
    end
  end

  defp locate(data, {:key, k}) when is_map(data) do
    case Map.fetch(data, k) do
      {:ok, v} -> {:ok, v}
      :error -> :absent_key
    end
  end

  defp locate(data, {tag, _} = seg) when is_list(data) and tag != :key do
    case item_index(data, seg) do
      nil -> :unmatched
      i -> {:ok, Enum.at(data, i)}
    end
  end

  defp locate(data, seg), do: not_a_container(data, seg)

  defp replace_child(data, {:key, k}, v) when is_map(data), do: {:ok, Map.put(data, k, v)}

  defp replace_child(data, seg, v) when is_list(data),
    do: {:ok, List.replace_at(data, item_index(data, seg), v)}

  defp item_index(list, {:keyed, key}),
    do: Enum.find_index(list, &(is_map(&1) and Map.get(&1, "_key") == key))

  defp item_index(list, {:index, i}) do
    n = length(list)
    idx = if i < 0, do: n + i, else: i
    if idx >= 0 and idx < n, do: idx, else: nil
  end

  defp item_index(_list, {:key, _}), do: nil

  defp not_a_container(data, {:key, k}),
    do: {:error, "cannot read field #{inspect(k)} inside #{kind(data)}"}

  defp not_a_container(data, _seg),
    do: {:error, "cannot select an array item inside #{kind(data)}"}

  defp kind(v) when is_map(v), do: "an object"
  defp kind(v) when is_list(v), do: "an array"
  defp kind(v) when is_binary(v), do: "a string"
  defp kind(v) when is_number(v), do: "a number"
  defp kind(nil), do: "null"
  defp kind(v) when is_boolean(v), do: "a boolean"
  defp kind(_), do: "a value"
end
