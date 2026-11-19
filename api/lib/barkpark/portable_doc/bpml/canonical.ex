defmodule Barkpark.PortableDoc.Bpml.Canonical do
  @moduledoc """
  `normalize/1`: the spelling a document has after a BPML print and parse, when
  the text carries all of it. It is the one place the printer's rewrites live:
  `Bpml.WriteWall` compares `parse(print(view))` with `normalize(stored)` to
  find what a pull did not show. Each rewrite fires on an exact key set and
  drops no key. Twenty-three rewrites, no others:

    1. `:mark_node` — an inline mark written as a node (`code`, `strong`, `em`, `underline`, `strike`) becomes text carrying that mark, only when the node holds nothing else (exactly type and children, or type, value and its own marks).
    2. `:expandable_children` — an `expandable`'s body key `children` becomes `blocks`.
    3. `:unchecked_item` — a list item `%{"content" => c, "checked" => false}` and nothing else becomes the plain item `c`.
    4. `:heading_level` — a heading level written as a string (`"2"`) becomes the integer.
    5. `:text_merge` — adjacent text nodes with no marks merge into one.
    6. `:alias_key` — a body the printer reads under an alias key moves whole to the key the parser writes (`Canonical.AliasKey`).
    7. `:empty_text` — a text node whose value is "" and whose marks are decorators only (no link or other annotation) is dropped.
    8. `:empty_step_body` — a step with no `blocks` (and no `children` or `content`) has `blocks: []`; no other absent list.
    9. `:empty_marks` — a text node's `marks: []` is dropped; the node carries no mark either way.
    10. `:inline_shape` — in a block's inline `content`, a bare string beside inline nodes becomes a text node, and a single inline node becomes a one-node list.
    11. `:byline_value_item` — a byline item `%{"value" => s}` and nothing else becomes the string `s` (the byline value-map shape stored by the wave-5/6 epic Papers).
    12. `:bare_note` — a notes item that is a bare string `s` becomes `%{"text" => s}` (the bare-string notes shape of the heggemsnes-act remedies block).
    13. `:absent_step_children` — a step's `children` holding nil or false is dropped; the printer reads past it to `blocks` or `content`.
    14. `:object_mark` — a text node's mark written as a map holding only its type (`%{"type" => "bold"}`) is that name.
    15. `:mark_alias` — a text node's marks `bold` and `italic` are `strong` and `em`: the printer writes both pairs as `<b>` and `<i>`.
    16. `:typed_text_value` — a text node that is exactly type and value, whose value is a code node holding only type and a string value, is text carrying the `code` mark.
    17. `:number_value` — a text node's number `value` is the string the printer writes for it.
    18. `:nil_marks` — a text node's `marks: nil` is dropped.
    19. `:bare_inline_strings` — a block's inline `content` that is bare strings only becomes text nodes.
    20. `:bare_list_item` — a list item that is a bare string, or a map holding only `text` (a string), is the one-text-node item.
    21. `:bare_table_cell` — a table row cell that is a bare string is a one-text-node cell.
    22. `:empty_step_children` — a step's `children: []` is dropped (rule 8 then gives it an empty `blocks`).
    23. `:empty_note_content` — a `note` block's `content: []` is dropped; its words are in `text`.

  Nothing lost means: no character, no mark on a character, no link, no
  checked state, no block, no item child, no slot. A mark on zero characters
  (rule 7) and an empty `marks` list (rule 9) mark no character, so they are not
  in that list. It never drops a key that holds content (`children`, `slots`,
  `items`, `blocks`) and never changes a word; an empty list or nil holds no
  content. Another rewrite is its own change, with its own careful review.
  """

  alias Barkpark.PortableDoc.Bpml.Canonical.AliasKey

  @rules [
    :mark_node,
    :expandable_children,
    :unchecked_item,
    :heading_level,
    :text_merge,
    :alias_key,
    :empty_text,
    :empty_step_body,
    :empty_marks,
    :inline_shape,
    :byline_value_item,
    :bare_note,
    :absent_step_children,
    :object_mark,
    :mark_alias,
    :typed_text_value,
    :number_value,
    :nil_marks,
    :bare_inline_strings,
    :bare_list_item,
    :bare_table_cell,
    :empty_step_children,
    :empty_note_content
  ]

  # The printer's decorator marks (`mark_tag/1`); any other mark is an annotation.
  @decorators ~w(strong em code underline strike highlight sub sup bold italic)

  # Keys whose value is blocks (or a list of block lists, or of step maps).
  # `slots` holds a map of named block lists; `items` holds list items; every
  # other key holds inline content or attributes.
  @block_keys ~w(blocks children child columns steps)

  @mark_node_types ~w(strong em code underline strike)

  # Inline node types: what `:inline_shape` recognises as inline content.
  @inline_types ~w(text link strong em code underline strike)

  @doc "The rewrites, by name."
  @spec rules() :: [atom()]
  def rules, do: @rules

  @doc """
  The stored blocks as a BPML print and parse spells them. `rules` limits the
  rewrites (all of them by default); a test can name a subset.
  """
  @spec normalize(term(), [atom()]) :: term()
  def normalize(blocks, rules \\ @rules)
  def normalize(blocks, rules) when is_list(blocks), do: Enum.map(blocks, &block(&1, rules))
  def normalize(other, _rules), do: other

  defp block(%{} = b, r) do
    b = if :absent_step_children in r, do: step_children(b, &(&1 in [nil, false])), else: b
    b = if :empty_step_children in r, do: step_children(b, &(&1 == [])), else: b
    if :alias_key in r, do: b |> AliasKey.rekey() |> shape(r), else: shape(b, r)
  end

  defp block(other, _r), do: other

  defp shape(%{"type" => "expandable", "children" => children} = b, r)
       when not is_map_key(b, "blocks") do
    if :expandable_children in r,
      do: b |> Map.delete("children") |> Map.put("blocks", children) |> walk_block(r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "heading", "level" => level} = b, r) when is_binary(level) do
    case :heading_level in r and Integer.parse(level) do
      {n, ""} when n in 1..6 -> walk_block(%{b | "level" => n}, r)
      _ -> walk_block(b, r)
    end
  end

  defp shape(%{"type" => "steps", "steps" => steps} = b, r) when is_list(steps) do
    if :empty_step_body in r,
      do: walk_block(%{b | "steps" => Enum.map(steps, &empty_step_body/1)}, r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "byline", "items" => items} = b, r) when is_list(items) do
    if :byline_value_item in r,
      do: walk_block(%{b | "items" => Enum.map(items, &byline_item/1)}, r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "notes", "items" => items} = b, r) when is_list(items) do
    if :bare_note in r,
      do: walk_block(%{b | "items" => Enum.map(items, &bare_note/1)}, r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "list", "items" => items} = b, r) when is_list(items) do
    if :bare_list_item in r,
      do: walk_block(%{b | "items" => Enum.map(items, &bare_list_item/1)}, r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "table", "rows" => rows} = b, r) when is_list(rows) do
    if :bare_table_cell in r,
      do: walk_block(%{b | "rows" => Enum.map(rows, &bare_cells/1)}, r),
      else: walk_block(b, r)
  end

  defp shape(%{"type" => "note", "content" => []} = b, r) do
    if :empty_note_content in r,
      do: b |> Map.delete("content") |> walk_block(r),
      else: walk_block(b, r)
  end

  defp shape(b, r), do: walk_block(b, r)

  defp bare_list_item(s) when is_binary(s), do: [string_to_text(s)]

  defp bare_list_item(%{"text" => s} = it) when map_size(it) == 1 and is_binary(s),
    do: [string_to_text(s)]

  defp bare_list_item(it), do: it

  defp bare_cells(row) when is_list(row),
    do: Enum.map(row, fn cell -> if is_binary(cell), do: [string_to_text(cell)], else: cell end)

  defp bare_cells(row), do: row

  defp byline_item(%{"value" => s} = it) when map_size(it) == 1 and is_binary(s), do: s
  defp byline_item(it), do: it

  defp bare_note(s) when is_binary(s), do: %{"text" => s}
  defp bare_note(it), do: it

  # A step's `children` that `drop?` says holds no body is dropped.
  defp step_children(%{"type" => "steps", "steps" => steps} = b, drop?) when is_list(steps) do
    %{b | "steps" => Enum.map(steps, &drop_children(&1, drop?))}
  end

  defp step_children(b, _drop?), do: b

  defp drop_children(%{"children" => c} = step, drop?) do
    if drop?.(c), do: Map.delete(step, "children"), else: step
  end

  defp drop_children(step, _drop?), do: step

  defp empty_step_body(%{} = step) do
    if Enum.any?(["blocks", "children", "content"], &Map.has_key?(step, &1)),
      do: step,
      else: Map.put(step, "blocks", [])
  end

  defp empty_step_body(step), do: step

  defp walk_block(b, r) do
    Map.new(b, fn
      {"slots", %{} = slots} -> {"slots", Map.new(slots, fn {n, v} -> {n, block_value(v, r)} end)}
      {k, v} when k in @block_keys -> {k, block_value(v, r)}
      {"items", v} when is_list(v) -> {"items", Enum.map(v, &item(&1, r))}
      {"content", v} -> {"content", v |> inline_shape(r) |> then(&inline(&1, r))}
      {k, v} -> {k, inline(v, r)}
    end)
  end

  defp inline_shape(v, r) do
    cond do
      :inline_shape not in r -> v
      inline_node?(v) -> [v]
      is_list(v) and Enum.any?(v, &inline_node?/1) -> Enum.map(v, &string_to_text/1)
      bare_strings?(v, r) -> Enum.map(v, &string_to_text/1)
      true -> v
    end
  end

  defp bare_strings?(v, r),
    do: :bare_inline_strings in r and is_list(v) and v != [] and Enum.all?(v, &is_binary/1)

  defp inline_node?(%{"type" => t}), do: t in @inline_types
  defp inline_node?(_), do: false

  defp string_to_text(s) when is_binary(s), do: %{"type" => "text", "value" => s}
  defp string_to_text(n), do: n

  defp block_value(v, r) when is_list(v), do: Enum.map(v, &block_value(&1, r))
  defp block_value(%{"type" => _} = v, r), do: block(v, r)
  # A step map: its own keys say what they hold.
  defp block_value(%{} = v, r), do: walk_block(v, r)
  defp block_value(v, _r), do: v

  defp item(%{"content" => c, "checked" => false} = it, r)
       when map_size(it) == 2 and is_list(c) do
    if :unchecked_item in r, do: inline(c, r), else: walk_block(it, r)
  end

  defp item(%{} = it, r), do: walk_block(it, r)
  defp item(other, r), do: inline(other, r)

  defp inline(l, r) when is_list(l) do
    l
    |> Enum.flat_map(fn
      %{"type" => t, "children" => cs} = node
      when t in @mark_node_types and is_list(cs) and map_size(node) == 2 ->
        if :mark_node in r, do: mark_children(node, r), else: [inline(node, r)]

      item ->
        [inline(item, r)]
    end)
    |> then(&if(:empty_marks in r, do: Enum.map(&1, fn n -> empty_marks(n) end), else: &1))
    |> then(&if(:empty_text in r, do: Enum.reject(&1, fn n -> empty_text?(n) end), else: &1))
    |> then(&if(:text_merge in r, do: merge_text(&1), else: &1))
  end

  defp inline(%{"type" => t, "value" => v} = node, r)
       when t in @mark_node_types and is_binary(v) do
    if :mark_node in r and Map.keys(node) -- ["type", "value", "marks"] == [],
      do: %{"type" => "text", "value" => v, "marks" => [t | Map.get(node, "marks", [])]},
      else: node
  end

  # A link's children are inline content, as the printer prints them.
  defp inline(%{"type" => "link", "children" => cs} = link, r) when is_list(cs),
    do: link |> Map.delete("children") |> inline(r) |> Map.put("children", inline(cs, r))

  defp inline(%{} = m, r) do
    Map.new(m, fn
      {k, v} when k in @block_keys -> {k, block_value(v, r)}
      {k, v} -> {k, inline(v, r)}
    end)
  end

  defp inline(other, _r), do: other

  defp empty_text?(%{"type" => "text", "value" => ""} = n) do
    marks = Map.get(n, "marks", [])

    Map.keys(n) -- ["type", "value", "marks"] == [] and is_list(marks) and
      Enum.all?(marks, &(&1 in @decorators))
  end

  defp empty_text?(_), do: false

  defp empty_marks(%{"type" => "text", "marks" => []} = n), do: Map.delete(n, "marks")
  defp empty_marks(n), do: n

  # The mark covers every run the element holds.
  defp mark_children(%{"type" => t, "children" => children}, r) do
    children
    |> inline(r)
    |> Enum.map(fn
      %{"marks" => marks} = c -> %{c | "marks" => [t | marks]}
      %{} = c -> Map.put(c, "marks", [t])
      other -> other
    end)
  end

  defp merge_text([
         %{"type" => "text", "value" => a} = x,
         %{"type" => "text", "value" => b} = y | rest
       ])
       when map_size(x) == 2 and map_size(y) == 2 and is_binary(a) and is_binary(b),
       do: merge_text([%{"type" => "text", "value" => a <> b} | rest])

  defp merge_text([x | rest]), do: [x | merge_text(rest)]
  defp merge_text([]), do: []
end
