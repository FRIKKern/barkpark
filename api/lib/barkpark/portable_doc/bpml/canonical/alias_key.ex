defmodule Barkpark.PortableDoc.Bpml.Canonical.AliasKey do
  @moduledoc """
  Rule 6 of `Bpml.Canonical`, `:alias_key`: the printer reads a body under any
  of several keys (its `alias_get/2` and `plain_alias/2` reads) and prints it
  once; the parser gives it back under one key. This moves the body to that key
  whole, in the shape the parser writes it (plain text, inline content, or head
  cells), and not one word changes.

  When two keys of one read hold different bodies, the block is left as it is:
  the print shows only the first, so the round trip sees the other one missing
  and refuses.

  `@reads` is a copy of the printer's alias reads. `bpml_canonical_test.exs`
  diffs it against every `alias_get(`, `plain_alias(` and `plain_body(` call in
  `printer.ex`, both ways: it fails when the printer reads an alias this list
  lacks, or this list holds one the printer does not read. Lifting the list into the printer itself is
  task-7b80797938b17417.
  """

  # {block type, scope, canonical key the parser writes, keys in the printer's read order, shape}
  # scope `:block` is the block map; `{:each, key}` is each map in that list.
  @reads [
    {"byline", :block, "items", ["items", "content"], :raw},
    {"code", :block, "value", ["value", "code", "content", "text"], :plain},
    {"steps", :block, "steps", ["steps", "items"], :raw},
    {"steps", {:each, "steps"}, "blocks", ["children", "blocks", "content"], :raw},
    {"table", :block, "head", ["head", "header", "headers", "columns"], :head_cells},
    {"section", :block, "blocks", ["blocks", "children"], :raw},
    {"expandable", :block, "blocks", ["children", "blocks"], :raw},
    {"expandable", :block, "summary", ["summary", "title"], :plain},
    {"paper-links", :block, "refs", ["refs", "items"], :raw},
    {"cards", {:each, "items"}, "text", ["text", "body"], :plain},
    {"terminal", :block, "children", ["children", "blocks"], :raw},
    {"pipeline", :block, "nodes", ["nodes", "items"], :raw},
    {"stat-grid", :block, "items", ["items", "stats"], :raw},
    {"blockquote", :block, "cite", ["cite", "attribution"], :plain},
    {"blockquote", :block, "content", ["content", "text"], :inline},
    {"toc", {:each, "items"}, "text", ["text", "title"], :plain},
    {"bar-chart", :block, "bars", ["bars", "items"], :raw},
    {"lineage", :block, "nodes", ["nodes", "items"], :raw},
    {"quote", :block, "cite", ["cite", "attribution"], :plain},
    {"quote", :block, "content", ["content", "text"], :inline},
    {"heading", :block, "text", ["text", "content"], :plain},
    {"eyebrow", :block, "text", ["text", "content"], :plain},
    {"paragraph", :block, "content", ["content", "text"], :inline},
    {"pullquote", :block, "content", ["content", "text"], :inline},
    {"ingress", :block, "content", ["content", "text"], :inline}
  ]

  @doc false
  def reads, do: @reads

  @doc "The block with each aliased body moved to the key the parser writes."
  @spec rekey(map()) :: map()
  def rekey(%{"type" => type} = b) do
    Enum.reduce(@reads, b, fn
      {^type, :block, key, order, shape}, acc ->
        move(acc, key, order, shape)

      {^type, {:each, list_key}, key, order, shape}, acc ->
        case Map.get(acc, list_key) do
          list when is_list(list) ->
            Map.put(
              acc,
              list_key,
              Enum.map(list, &if(is_map(&1), do: move(&1, key, order, shape), else: &1))
            )

          _ ->
            acc
        end

      _read, acc ->
        acc
    end)
  end

  def rekey(b), do: b

  # The printer's `alias_get/2`: the first key holding a non-empty value wins.
  defp move(m, key, order, shape) do
    held = for k <- order, filled?(Map.get(m, k)), do: shape(Map.get(m, k), shape)

    case held do
      [] ->
        m

      [body | others] ->
        if Enum.all?(others, &(&1 == body)),
          do: m |> Map.drop(order) |> Map.put(key, body),
          else: m
    end
  end

  defp filled?(v), do: v not in [nil, "", [], %{}]

  defp shape(v, :raw), do: v

  # A plain-text position (`<code>`, `<h2>`, an attribute): an unmarked inline
  # list flattens to its text, as the printer's `flatten_plain/1` does.
  defp shape(v, :plain) when is_list(v) do
    if Enum.all?(v, &plain_run?/1),
      do: Enum.map_join(v, "", fn %{"value" => s} -> s end),
      else: v
  end

  defp shape(v, :plain), do: v
  defp shape(s, :inline) when is_binary(s), do: [%{"type" => "text", "value" => s}]
  defp shape(v, :inline), do: v
  defp shape(cells, :head_cells) when is_list(cells), do: Enum.map(cells, &head_cell/1)
  defp shape(v, :head_cells), do: v

  defp plain_run?(%{"type" => "text", "value" => v} = n) when is_binary(v),
    do: Map.get(n, "marks", []) == []

  defp plain_run?(_), do: false

  # The printer's `head_cell/1` shapes, as the parser reads them back.
  defp head_cell(s) when is_binary(s), do: text_cell(s)

  defp head_cell(%{} = cell) do
    cell =
      case cell do
        %{"text" => s} when is_binary(s) ->
          cell |> Map.delete("text") |> Map.put("content", text_cell(s))

        %{"header" => s} when is_binary(s) ->
          cell |> Map.delete("header") |> Map.put("content", text_cell(s))

        _ ->
          cell
      end

    case cell do
      %{"content" => c} when map_size(cell) == 1 and is_list(c) -> c
      _ -> cell
    end
  end

  defp head_cell(cell), do: cell

  defp text_cell(""), do: []
  defp text_cell(s), do: [%{"type" => "text", "value" => s}]
end
