defmodule Barkpark.PortableDoc.Bpml.ListItems do
  @moduledoc """
  A list item in BPML (task-0b448ea0847a6b4f): how the printer spells it, how
  the parser shapes it, and what a push carries back by its id.

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

  An item with an id needs no fallback for what the printer cannot spell.
  `carry/2` brings it back on push from the stored item with that id: its
  other keys, a `text` the reader does not show, a `checked` that is not
  `true`, and `children` entries that are not lists, in their places. It
  looks only in the stored top-level block with the pushed block's id. An id
  that matches no stored item carries nothing, and a push that adds a second
  item with an id already in the block is refused by that id.

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
  `pushed` with each item that has an id given back what the printer could
  not spell, from the stored item with that id in the stored top-level block
  with the same id: `{:ok, blocks}`, or `{:refused, body}` when a pushed
  block holds an item id more often than its stored block does.
  """
  @spec carry([map()], [map()]) :: {:ok, [map()]} | {:refused, map()}
  def carry(pushed, stored) do
    stored_by_id = for %{"id" => id} = b <- stored, is_binary(id), into: %{}, do: {id, b}

    Enum.reduce_while(pushed, {:ok, []}, fn block, {:ok, acc} ->
      s = Map.get(stored_by_id, block["id"])
      index = s |> item_ids() |> Enum.reverse() |> Map.new()

      case added_twice(block, s) do
        nil -> {:cont, {:ok, [walk(block, index) | acc]}}
        id -> {:halt, twice(id, block)}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      refused -> refused
    end
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

  # Every `{id, item}` of the lists in `value`, at any depth, in order; the
  # first of a repeated stored id wins (the reversed list is put last-first).
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

  defp walk(%{"type" => t, "items" => items} = list, index)
       when t in @list_types and is_list(items) do
    list
    |> Map.new(fn {k, v} -> {k, if(k == "items", do: v, else: walk(v, index))} end)
    |> Map.put("items", Enum.map(items, &carry_item(&1, index)))
  end

  defp walk(%{} = map, index), do: Map.new(map, fn {k, v} -> {k, walk(v, index)} end)
  defp walk(list, index) when is_list(list), do: Enum.map(list, &walk(&1, index))
  defp walk(other, _index), do: other

  defp carry_item(%{} = item, index) do
    item = Map.update(item, "children", nil, &walk(&1, index)) |> drop_nil("children")

    case Map.fetch(index, id(item)) do
      {:ok, stored} -> merge(item, stored)
      :error -> item
    end
  end

  defp carry_item(item, _index), do: item

  defp merge(item, stored) do
    item = Map.merge(Map.drop(stored, @spelled), item)

    item = if unshown_text?(stored), do: Map.put(item, "text", stored["text"]), else: item

    item =
      if Map.has_key?(stored, "checked") and stored["checked"] != true and
           not Map.has_key?(item, "checked"),
         do: Map.put(item, "checked", stored["checked"]),
         else: item

    merge_children(item, stored)
  end

  # Stored children entries that are not lists stay in their places; the
  # pushed lists fill the list places in order, and any more come after.
  defp merge_children(item, stored) do
    case Map.fetch(stored, "children") do
      {:ok, children} when is_list(children) ->
        if Enum.all?(children, &list?/1),
          do: item,
          else: Map.put(item, "children", interleave(children, item))

      {:ok, children} ->
        if Map.has_key?(item, "children"), do: item, else: Map.put(item, "children", children)

      :error ->
        item
    end
  end

  defp interleave(stored_children, item) do
    lists = item |> Map.get("children", []) |> Enum.filter(&list?/1)

    {placed, rest} =
      Enum.flat_map_reduce(stored_children, lists, fn
        entry, rest ->
          cond do
            not list?(entry) -> {[entry], rest}
            rest == [] -> {[], []}
            true -> {[hd(rest)], tl(rest)}
          end
      end)

    placed ++ rest
  end

  defp drop_nil(map, key), do: if(map[key] == nil, do: Map.delete(map, key), else: map)
end
