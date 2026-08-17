defmodule Barkpark.PortableDoc.Bpml.Printer do
  @moduledoc """
  Blocks → canonical BPML. The other half of the isomorphism in
  `Barkpark.PortableDoc.Bpml` — every choice here (indentation, attribute
  order, escaping, when a tag self-closes) defines THE canonical spelling the
  parser round-trips against. Pure string emission; no Repo, no I/O.
  """

  @indent "  "

  # ── public ──────────────────────────────────────────────────────────────────

  def print_paper(%{} = paper) do
    attrs = attr_str(paper, ["slug", "title"])
    meta = meta_lines(paper)
    body = Enum.map(Map.get(paper, "blocks", []), &block(&1, 1))
    "<paper#{attrs}>\n" <> Enum.join(meta ++ body, "\n") <> "\n</paper>\n"
  end

  def print_blocks(blocks) when is_list(blocks) do
    blocks |> Enum.map(&block(&1, 0)) |> Enum.join("\n") |> Kernel.<>("\n")
  end

  # ── paper meta ──────────────────────────────────────────────────────────────

  defp meta_lines(paper) do
    desc = Map.get(paper, "description")
    tags = Map.get(paper, "tags", [])

    if desc || tags != [] do
      inner =
        List.wrap(desc && "#{@indent}#{@indent}<description>#{esc(desc)}</description>") ++
          Enum.map(tags, fn t ->
            "#{@indent}#{@indent}<tag#{attr_str(t, ["tag", "strength"])}>#{esc(Map.get(t, "rationale", ""))}</tag>"
          end)

      ["#{@indent}<meta>" | inner] ++ ["#{@indent}</meta>"]
    else
      []
    end
  end

  # ── blocks ──────────────────────────────────────────────────────────────────

  defp block(%{"type" => "eyebrow"} = b, d), do: text_tag("eyebrow", b, d)

  defp block(%{"type" => "heading", "level" => l} = b, d) when l in 1..3,
    do: pad(d) <> "<h#{l}#{attr_str(b, ["id"])}>#{esc(Map.get(b, "text", ""))}</h#{l}>"

  defp block(%{"type" => "paragraph"} = b, d), do: inline_tag("p", b, d)
  defp block(%{"type" => "pullquote"} = b, d), do: inline_tag("pullquote", b, d)
  defp block(%{"type" => "ingress"} = b, d), do: inline_tag("ingress", b, d)

  defp block(%{"type" => "byline"} = b, d) do
    items = Enum.map(Map.get(b, "items", []), &"#{pad(d + 1)}<item>#{esc(&1)}</item>")
    wrap("byline", attr_str(b, ["id"]), items, d)
  end

  defp block(%{"type" => "callout"} = b, d) do
    pad(d) <>
      "<callout#{attr_str(b, ["id", "tone", "title"])}>" <>
      inline(Map.get(b, "content", [])) <> "</callout>"
  end

  defp block(%{"type" => "list"} = b, d) do
    items = Enum.map(Map.get(b, "items", []), &"#{pad(d + 1)}<li>#{inline(&1)}</li>")
    wrap("ul", attr_str(b, ["id"]), items, d)
  end

  defp block(%{"type" => "code"} = b, d),
    do: pad(d) <> "<code#{attr_str(b, ["id"])}>#{esc(Map.get(b, "value", ""))}</code>"

  defp block(%{"type" => "diagram"} = b, d),
    do:
      pad(d) <>
        "<diagram#{attr_str(b, ["id", "caption"])}>#{esc(Map.get(b, "source", ""))}</diagram>"

  defp block(%{"type" => "stats"} = b, d) do
    items =
      Enum.map(Map.get(b, "items", []), fn i ->
        "#{pad(d + 1)}<stat#{attr_str(i, ["label", "value", "denom"])}>#{esc(Map.get(i, "body", ""))}</stat>"
      end)

    wrap("stats", attr_str(b, ["id"]), items, d)
  end

  defp block(%{"type" => "steps"} = b, d) do
    items =
      Enum.map(Map.get(b, "steps", []), fn s ->
        case Map.get(s, "blocks", []) do
          [] ->
            "#{pad(d + 1)}<step#{attr_str(s, ["title"])}/>"

          children ->
            wrap("step", attr_str(s, ["title"]), Enum.map(children, &block(&1, d + 2)), d + 1)
        end
      end)

    wrap("steps", attr_str(b, ["id"]), items, d)
  end

  defp block(%{"type" => "table"} = b, d) do
    head =
      case Map.get(b, "head", []) do
        [] ->
          []

        cells ->
          ths = Enum.map_join(cells, "", &"<th>#{head_cell(&1)}</th>")
          ["#{pad(d + 1)}<tr>#{ths}</tr>"]
      end

    rows =
      Enum.map(Map.get(b, "rows", []), fn cells ->
        tds = Enum.map_join(cells, "", &"<td>#{inline(&1)}</td>")
        "#{pad(d + 1)}<tr>#{tds}</tr>"
      end)

    wrap("table", attr_str(b, ["id"]), head ++ rows, d)
  end

  defp block(%{"type" => "section"} = b, d) do
    children = Enum.map(Map.get(b, "blocks", []), &block(&1, d + 1))
    wrap("section", attr_str(b, ["id", "title"]), children, d)
  end

  defp block(%{"type" => type}, _d),
    do:
      raise(
        ArgumentError,
        "BPML printer: block type #{inspect(type)} is outside the kernel vocabulary"
      )

  # Head cells arrive in TWO shapes: the write chokepoint normalizes them to
  # inline-node lists (the canonical form BPML round-trips), while hand-authored
  # payloads may still carry the legacy %{"text" => …} map — accepted as input,
  # canonicalized on round-trip.
  defp head_cell(cells) when is_list(cells), do: inline(cells)
  defp head_cell(%{} = cell), do: esc(Map.get(cell, "text", ""))

  # ── inline ──────────────────────────────────────────────────────────────────

  defp inline(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &inline_node/1)

  defp inline_node(%{"type" => "text"} = n) do
    Map.get(n, "marks", [])
    |> Enum.reverse()
    |> Enum.reduce(esc(Map.get(n, "value", "")), fn mark, acc ->
      tag = mark_tag(mark)
      "<#{tag}>#{acc}</#{tag}>"
    end)
  end

  defp inline_node(%{"type" => "link"} = n),
    do:
      ~s(<a href="#{esc_attr(Map.get(n, "href", ""))}">) <>
        inline(Map.get(n, "children", [])) <> "</a>"

  defp mark_tag("strong"), do: "b"
  defp mark_tag("em"), do: "i"
  defp mark_tag("code"), do: "code"
  defp mark_tag("underline"), do: "u"
  defp mark_tag("strike"), do: "s"

  defp mark_tag(other),
    do: raise(ArgumentError, "BPML printer: unknown inline mark #{inspect(other)}")

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp text_tag(tag, b, d),
    do: pad(d) <> "<#{tag}#{attr_str(b, ["id"])}>#{esc(Map.get(b, "text", ""))}</#{tag}>"

  defp inline_tag(tag, b, d),
    do: pad(d) <> "<#{tag}#{attr_str(b, ["id"])}>#{inline(Map.get(b, "content", []))}</#{tag}>"

  defp wrap(tag, attrs, [], d), do: pad(d) <> "<#{tag}#{attrs}/>"

  defp wrap(tag, attrs, lines, d),
    do: Enum.join([pad(d) <> "<#{tag}#{attrs}>" | lines] ++ [pad(d) <> "</#{tag}>"], "\n")

  defp attr_str(map, keys) do
    Enum.map_join(keys, "", fn k ->
      case Map.get(map, k) do
        nil -> ""
        v -> ~s( #{k}="#{esc_attr(to_string(v))}")
      end
    end)
  end

  defp pad(d), do: String.duplicate(@indent, d)

  defp esc(s) when is_binary(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp esc(other), do: esc(to_string(other))

  defp esc_attr(s), do: s |> esc() |> String.replace("\"", "&quot;")
end
