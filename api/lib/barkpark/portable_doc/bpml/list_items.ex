defmodule Barkpark.PortableDoc.Bpml.ListItems do
  @moduledoc """
  A list item in BPML (task-0b448ea0847a6b4f): how the printer spells it and
  how the parser shapes it.

  An item prints as `<li id checked>` with the reader's words (its `content`
  when that is a non-empty list, else its `text`), then each child list as a
  nested `<ul>`:

      <ul id="steps">
        <li id="plan"><b>Plan</b>
          <ul ordered="true">
            <li>Build</li>
          </ul>
        </li>
      </ul>

  A child list may be any list type the reader draws (`list` and its
  aliases); it prints as `<ul>`, an ordered alias with `ordered="true"`. Lists
  nest at most `Validate.max_depth/0` levels, the depth a stored Paper may
  have; the parser refuses one level more.

  What the printer cannot round-trip, it does not print: the whole top-level
  block prints as one `<kept>` line (`Bpml.Unwritable`). The shapes that do so
  are `@fallbacks`, here and nowhere else.

  An item with an id prints what the printer can spell, even when it holds
  more: the pull shows its words, and `Bpml.WriteWall` refuses an edit to its
  block (422 `bpml_unshown`), so what BPML cannot spell keeps its stored bytes.
  Editing nested lists from a text copy needs a bp that sends the pull's
  fingerprint (`Bpml.PrintMark`); without it, a list holding nested lists or
  item ids comes home byte-equal or the push is refused.

  A push that adds a second item with an id already in the block is refused
  by that id (`check_ids/2`).

  Read back, a plain item is an inline array, as before; an item with an id,
  `checked` or nested lists is a map of `content` and those keys.
  """

  alias Barkpark.PortableDoc.Validate

  @unordered_aliases ~w(bulletList bullet_list bulleted-list bulleted_list)
  @ordered_aliases ~w(ordered-list numbered_list)
  @list_types ["list" | @unordered_aliases ++ @ordered_aliases]

  # Keys the printer spells, one way or another. Any other key on an item
  # without an id is a field BPML cannot write.
  @spelled ~w(id content text checked children)

  # The shapes the printer cannot round-trip, one row each (lead condition a).
  # Each prints the whole top-level block as one <kept> line.
  @fallbacks %{
    # F1: an item without an id holding a field the printer cannot spell, or
    # any item whose `content` is not a list (the reader shows its `text`).
    f1: "holds a field BPML cannot write",
    # F2: an item without an id whose `children` is not a list, or holds an
    # entry that is not a list the reader draws.
    f2: "holds children that are not lists",
    # F3: a string item holding JSON inline nodes: the reader draws the nodes,
    # BPML would show the JSON.
    f3: "is a JSON string of inline nodes",
    # F4: lists nested deeper than a stored Paper may nest them.
    f4: "nests lists deeper than #{Validate.max_depth()} levels"
  }

  @doc "The fallback rows: `%{row => why}`."
  @spec fallbacks() :: %{atom() => String.t()}
  def fallbacks, do: @fallbacks

  @doc """
  How the printer spells item `n` of a list at nesting `level` (the top list
  is level 1): `{:ok, attrs, inline, child_lists}`, or `{:fallback, why}`.
  `attrs` holds `id` and `checked` when they print; child lists come back as
  `list` blocks.
  """
  @spec spell(term(), pos_integer(), pos_integer()) ::
          {:ok, map(), term(), [map()]} | {:fallback, String.t()}
  def spell(item, n, level) do
    case fallback(item, level) do
      nil -> spelled(item)
      {row, detail} -> {:fallback, "its item #{n} #{@fallbacks[row]}#{detail}"}
    end
  end

  defp fallback(item, _level) when is_binary(item),
    do: if(json_nodes?(item), do: {:f3, ""})

  defp fallback(%{} = item, level) do
    id? = id(item) != nil
    fields = unwritable(item, id?)

    cond do
      fields != [] -> {:f1, " (" <> Enum.join(fields, ", ") <> ")"}
      not id? and not children_lists?(item) -> {:f2, ""}
      level >= Validate.max_depth() and child_lists(item) != [] -> {:f4, ""}
      true -> nil
    end
  end

  defp fallback(_item, _level), do: nil

  defp unwritable(item, id?) do
    content = if is_list(item["content"]) or item["content"] == nil, do: [], else: ["content"]

    if id? do
      content
    else
      others = item |> Map.keys() |> Enum.reject(&(&1 in @spelled)) |> Enum.sort()
      text = if unshown_text?(item), do: ["text"], else: []
      checked = if item["checked"] in [nil, true, false], do: [], else: ["checked"]
      bad_id = if Map.has_key?(item, "id"), do: ["id"], else: []
      Enum.uniq(bad_id ++ others ++ content ++ text ++ checked)
    end
  end

  defp spelled(%{} = item) do
    attrs =
      %{}
      |> put_present("id", id(item))
      |> put_present("checked", if(item["checked"] == true, do: true))

    {:ok, attrs, words(item), child_lists(item)}
  end

  defp spelled(item), do: {:ok, %{}, item, []}

  # The reader's words for an item map (Render.Compose `paragraph_inline/1`).
  defp words(item) do
    case item do
      %{"content" => [_ | _] = content} -> content
      %{"text" => text} when is_binary(text) and text != "" -> [text_node(text)]
      _ -> []
    end
  end

  defp unshown_text?(item) do
    case Map.get(item, "text") do
      nil -> false
      "" -> false
      text -> not (is_binary(text) and not match?([_ | _], item["content"]))
    end
  end

  defp children_lists?(item) do
    case Map.get(item, "children") do
      nil -> true
      children when is_list(children) -> Enum.all?(children, &list?/1)
      _ -> false
    end
  end

  defp child_lists(item) do
    case Map.get(item, "children") do
      children when is_list(children) -> for c <- children, list?(c), do: normalize(c)
      _ -> []
    end
  end

  @doc "True for a child the reader draws as a list: a list type with an `items` list."
  @spec list?(term()) :: boolean()
  def list?(%{"type" => type, "items" => items}) when type in @list_types, do: is_list(items)
  def list?(_other), do: false

  # The reader's own alias rule (Render.Compose): an unordered alias is a
  # `list`, an ordered one a `list` with `ordered: true`.
  defp normalize(%{"type" => t} = list) when t in @unordered_aliases,
    do: Map.put(list, "type", "list")

  defp normalize(%{"type" => t} = list) when t in @ordered_aliases,
    do: list |> Map.put("type", "list") |> Map.put("ordered", true)

  defp normalize(list), do: list

  defp json_nodes?(s) do
    match?({:ok, [%{} | _]}, Jason.decode(s))
  end

  defp id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp id(_item), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp text_node(text), do: %{"type" => "text", "value" => text}

  # ── the print mark's row (`Bpml.PrintMark`) ─────────────────────────────────

  @doc """
  True when `value` holds, at any depth, a list item the printer before this
  form spelled without something: a child list, or an id.
  """
  @spec marked?(term()) :: boolean()
  def marked?(%{"type" => t, "items" => items} = list) when t in @list_types and is_list(items),
    do: Enum.any?(items, &item_marked?/1) or marked?(Map.delete(list, "items"))

  def marked?(%{} = map), do: Enum.any?(Map.values(map), &marked?/1)
  def marked?(list) when is_list(list), do: Enum.any?(list, &marked?/1)
  def marked?(_other), do: false

  defp item_marked?(%{} = item),
    do: id(item) != nil or child_lists(item) != [] or marked?(Map.get(item, "children"))

  defp item_marked?(_item), do: false

  @doc """
  `value` as the printer before this form spelled its lists: an item without
  its id and children, its words its `content` when that is a list, else its
  `text`.
  """
  @spec before_print(term()) :: term()
  def before_print(%{"type" => t, "items" => items} = list)
      when t in @list_types and is_list(items) do
    list
    |> Map.new(fn {k, v} -> {k, if(k == "items", do: v, else: before_print(v))} end)
    |> Map.put("items", Enum.map(items, &item_before_print/1))
  end

  def before_print(%{} = map), do: Map.new(map, fn {k, v} -> {k, before_print(v)} end)
  def before_print(list) when is_list(list), do: Enum.map(list, &before_print/1)
  def before_print(other), do: other

  defp item_before_print(%{} = item) do
    item = Map.drop(item, ["id", "children"])
    if is_list(item["content"]), do: Map.delete(item, "text"), else: item
  end

  defp item_before_print(item), do: item

  @doc "What an old copy's refusal says block `v` holds."
  @spec stale_words(map()) :: String.t()
  def stale_words(v), do: "#{v["type"]} #{v["id"]} has nested lists or item ids"

  @doc """
  The stored paths of every item id and every item's child lists in `block`
  (canonical spelling); lists inside an item's children are under its
  `.children` path already.
  """
  @spec stale_paths(term(), String.t()) :: [String.t()]
  def stale_paths(%{"type" => t, "items" => items} = list, path)
      when t in @list_types and is_list(items) do
    own =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> item_paths(item, "#{path}.items[#{i}]") end)

    own ++ stale_paths(Map.delete(list, "items"), path)
  end

  def stale_paths(%{} = map, path),
    do: map |> Enum.sort() |> Enum.flat_map(fn {k, v} -> stale_paths(v, "#{path}.#{k}") end)

  def stale_paths(list, path) when is_list(list),
    do:
      list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> stale_paths(v, "#{path}[#{i}]") end)

  def stale_paths(_other, _path), do: []

  defp item_paths(%{} = item, path) do
    ids = if id(item), do: ["#{path}.id"], else: []

    if marked?(Map.get(item, "children")) or child_lists(item) != [],
      do: ids ++ ["#{path}.children"],
      else: ids
  end

  defp item_paths(_item, _path), do: []

  # ── the parser's side ───────────────────────────────────────────────────────

  @doc """
  An `<li>` read back: its inline nodes, then its nested lists. A plain item
  stays an inline array; `id`, `checked` or nested lists make it a map.
  """
  @spec parsed([{String.t(), String.t()}], list(), [map()]) :: list() | map()
  def parsed(attrs, nodes, lists) do
    item =
      %{"content" => nodes}
      |> put_present("id", attr(attrs, "id"))
      |> put_present("checked", checked(attr(attrs, "checked")))
      |> put_present("children", if(lists != [], do: lists))

    if map_size(item) == 1, do: nodes, else: item
  end

  @doc """
  The inline nodes before a nested `<ul>`, without the one line break and
  indent the printer puts there. Nothing else is trimmed.
  """
  @spec before_list(list()) :: list()
  def before_list(nodes) do
    case List.last(nodes) do
      %{"type" => "text", "value" => value} = last when is_binary(value) ->
        case String.replace(value, ~r/\n[ \t]*\z/, "") do
          "" -> Enum.drop(nodes, -1)
          trimmed -> Enum.drop(nodes, -1) ++ [%{last | "value" => trimmed}]
        end

      _ ->
        nodes
    end
  end

  defp checked(nil), do: nil
  defp checked(value), do: value == "true"

  defp attr(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  # ── the push's side ─────────────────────────────────────────────────────────

  @doc """
  `:ok`, or `{:refused, body}` when a pushed top-level block holds a list item
  id more often than the stored top-level block with its id does.
  """
  @spec check_ids([map()], [map()]) :: :ok | {:refused, map()}
  def check_ids(pushed, stored) do
    stored_by_id = for %{"id" => id} = b <- stored, is_binary(id), into: %{}, do: {id, b}

    Enum.find_value(pushed, :ok, fn
      %{} = block ->
        s = Map.get(stored_by_id, block["id"])

        case added_twice(block, s) do
          nil -> nil
          id -> twice(id, block)
        end

      _other ->
        nil
    end)
  end

  defp added_twice(block, stored) do
    pushed = block |> item_ids() |> Enum.frequencies_by(&elem(&1, 0))
    before = stored |> item_ids() |> Enum.frequencies_by(&elem(&1, 0))

    pushed
    |> Enum.filter(fn {id, n} -> n > 1 and n > Map.get(before, id, 0) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> List.first()
  end

  defp twice(id, block) do
    where = if is_binary(block["id"]), do: "#{block["type"]} #{block["id"]}", else: block["type"]

    {:refused,
     %{
       code: "bpml",
       message: "list item id \"#{id}\" appears more than once in #{where}; nothing was written",
       hint: "an item id names one stored item: take the id off the <li> you added"
     }}
  end

  # Every `{id, item}` of the lists in `value`, at any depth, in order.
  defp item_ids(value), do: value |> collect([]) |> Enum.reverse()

  defp collect(%{"type" => t, "items" => items} = list, acc) when t in @list_types do
    acc =
      if is_list(items),
        do: Enum.reduce(items, acc, &collect_item/2),
        else: acc

    list |> Map.delete("items") |> Map.values() |> Enum.reduce(acc, &collect/2)
  end

  defp collect(%{} = map, acc), do: map |> Map.values() |> Enum.reduce(acc, &collect/2)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  defp collect_item(%{} = item, acc) do
    acc = if id = id(item), do: [{id, item} | acc], else: acc
    collect(Map.get(item, "children"), acc)
  end

  defp collect_item(_item, acc), do: acc
end
