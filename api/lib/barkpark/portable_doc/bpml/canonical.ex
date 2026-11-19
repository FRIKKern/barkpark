defmodule Barkpark.PortableDoc.Bpml.Canonical do
  @moduledoc """
  `normalize/1`: the spelling a document has after a BPML print and parse, when
  the text carries all of it. It is the one place the printer's rewrites live;
  `Bpml.RoundTrip` compares `parse(print(doc))` with `normalize(doc)`, and
  `bpml_seal_papers_roundtrip_test.exs` uses it too. Six rewrites, no others:

    1. `:mark_node` — an inline mark written as a node (`code`, `strong`, `em`, `underline`, `strike`) becomes text carrying that mark.
    2. `:expandable_children` — an `expandable`'s body key `children` becomes `blocks`.
    3. `:unchecked_item` — a list item `%{"content" => c, "checked" => false}` and nothing else becomes the plain item `c`.
    4. `:heading_level` — a heading level written as a string (`"2"`) becomes the integer.
    5. `:text_merge` — adjacent text nodes with no marks merge into one.
    6. `:alias_key` — a body the printer reads under an alias key moves whole to the key the parser writes (`Canonical.AliasKey`).

  It never drops a key that holds content (`children`, `slots`, `items`,
  `blocks`) and never changes a word. A seventh rewrite is its own change, with
  its own careful review.
  """

  alias Barkpark.PortableDoc.Bpml.Canonical.AliasKey

  @rules [
    :mark_node,
    :expandable_children,
    :unchecked_item,
    :heading_level,
    :text_merge,
    :alias_key
  ]

  # Keys whose value is blocks (or a list of block lists, or of step maps).
  # `slots` holds a map of named block lists; `items` holds list items; every
  # other key holds inline content or attributes.
  @block_keys ~w(blocks children child columns steps)

  @mark_node_types ~w(strong em code underline strike)

  @doc "The six rewrites, by name."
  @spec rules() :: [atom()]
  def rules, do: @rules

  @doc """
  The stored blocks as a BPML print and parse spells them. `rules` limits the
  rewrites (all six by default); the sweep test counts each one with it.
  """
  @spec normalize(term(), [atom()]) :: term()
  def normalize(blocks, rules \\ @rules)
  def normalize(blocks, rules) when is_list(blocks), do: Enum.map(blocks, &block(&1, rules))
  def normalize(other, _rules), do: other

  defp block(%{} = b, r) do
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

  defp shape(b, r), do: walk_block(b, r)

  defp walk_block(b, r) do
    Map.new(b, fn
      {"slots", %{} = slots} -> {"slots", Map.new(slots, fn {n, v} -> {n, block_value(v, r)} end)}
      {k, v} when k in @block_keys -> {k, block_value(v, r)}
      {"items", v} when is_list(v) -> {"items", Enum.map(v, &item(&1, r))}
      {k, v} -> {k, inline(v, r)}
    end)
  end

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
      when t in @mark_node_types and is_list(cs) ->
        if :mark_node in r, do: mark_children(node, r), else: [inline(node, r)]

      item ->
        [inline(item, r)]
    end)
    |> then(&if(:text_merge in r, do: merge_text(&1), else: &1))
  end

  defp inline(%{"type" => t, "value" => v} = node, r)
       when t in @mark_node_types and is_binary(v) do
    if :mark_node in r,
      do: %{"type" => "text", "value" => v, "marks" => [t | Map.get(node, "marks", [])]},
      else: node
  end

  defp inline(%{} = m, r) do
    Map.new(m, fn
      {k, v} when k in @block_keys -> {k, block_value(v, r)}
      {k, v} -> {k, inline(v, r)}
    end)
  end

  defp inline(other, _r), do: other

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
