defmodule Barkpark.PortableDoc.Bpml.Printer do
  @moduledoc """
  Blocks → canonical BPML. The other half of the isomorphism in
  `Barkpark.PortableDoc.Bpml` — every choice here (indentation, attribute
  order, escaping, when a tag self-closes) defines THE canonical spelling the
  parser round-trips against. Pure string emission; no Repo, no I/O.

  It is TOTAL over its input: every shape the kernel vocabulary cannot spell
  raises `Barkpark.PortableDoc.Bpml.UnprintableError` (kind `:block`, `:inline`,
  `:mark` or `:head_cell`) — never a bare `FunctionClauseError`, and never a
  lossy `""`. Callers turn that into an honest 422.
  """

  alias Barkpark.PortableDoc.Bpml.UnprintableError

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
    items = Enum.map(Map.get(b, "items", []), &"#{pad(d + 1)}<item>#{byline_item(&1)}</item>")
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

  defp block(%{"type" => "route"} = b, d),
    do:
      pad(d) <>
        "<route#{attr_str(b, ["id", "sport", "distance", "elevation", "duration", "caption"])}>" <>
        "#{esc(Map.get(b, "polyline", ""))}</route>"

  defp block(%{"type" => "stats"} = b, d) do
    items =
      Enum.map(Map.get(b, "items", []), fn i ->
        "#{pad(d + 1)}<stat#{attr_str(i, ["label", "value", "denom"])}>#{esc(Map.get(i, "body", ""))}</stat>"
      end)

    wrap("stats", attr_str(b, ["id"]), items, d)
  end

  # The notes grid — the browser twin ships at
  # components.ex:Barkpark.PortableDoc.Render.Components.notes_html/1, the TUI
  # leg at pdrender notesRenderer; this is the BPML leg. Each item is a
  # `<note>` carrying its body in the `text` key (the legacy `notes` vocab; a
  # `body` key would render every note EMPTY). Item shapes and their handling
  # mirror the head-cell/inline tolerance rules: a dict item spells its attrs +
  # text; a BARE STRING escapes verbatim (the heggemsnes-act remedies shape, a
  # lossless read-only tolerance); anything else (an inline-array item) refuses.
  defp block(%{"type" => "notes"} = b, d) do
    items = Enum.map(Map.get(b, "items", []), &"#{pad(d + 1)}#{note_item(&1)}")
    wrap("notes", attr_str(b, ["id"]), items, d)
  end

  # The singular `note` widget (composition-doctrine split) — the same `<note>`
  # spelling as one grid item, at block level. A CONTENT-shaped note (non-empty
  # `content`, no binary `text` — the one legacy corpus block whose accessors
  # read it as "") would print as an empty `<note>`, a silent loss; it refuses.
  defp block(%{"type" => "note"} = b, d) do
    cond do
      is_binary(Map.get(b, "text")) -> pad(d) <> note_item(b)
      empty_content?(Map.get(b, "content")) -> pad(d) <> note_item(b)
      true -> raise(UnprintableError.new(:block, "note"))
    end
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
    wrap("section", attr_str(drop_nonscalar_variant(b), ["id", "title", "variant"]), children, d)
  end

  # The divider is a self-closing leaf — the kernel's one rule (<hr/>). Web
  # (compose.ex :439 → PdHr) and TUI (pdrender.go) legs already ship; this is
  # the BPML leg that dominates the one-blocker-away set (82 of 93 papers).
  defp block(%{"type" => "divider"} = b, d), do: pad(d) <> "<hr#{attr_str(b, ["id"])}/>"

  # A generic disclosure container — same wrapping shape as `section`, carrying
  # a `summary` attr and a body of blocks. Web (compose.ex :1529 → <details>)
  # and TUI legs already ship; this is the missing BPML leg. The body is read
  # with the SAME key preference as the renderer (compose.ex container_children:
  # "children" first, then "blocks") — a `children`-keyed expandable renders
  # fully on the web, so printing it empty would be a silent loss through sync.
  # The parser emits canonical "blocks", so the second print is byte-stable.
  defp block(%{"type" => "expandable"} = b, d) do
    body = Map.get(b, "children") || Map.get(b, "blocks") || []
    children = Enum.map(body, &block(&1, d + 1))
    wrap("expandable", attr_str(b, ["id", "summary"]), children, d)
  end

  # Fail-honest catchalls. EVERY shape the kernel cannot spell raises the ONE
  # typed refusal (UnprintableError) so the read path can label it 422 and the
  # sync path can tell "unprintable paper" from "printer bug" — never a bare
  # FunctionClauseError, which escaped the callers' rescue as a raw 500.
  defp block(%{"type" => type}, _d), do: raise(UnprintableError.new(:block, type))
  defp block(_other, _d), do: raise(UnprintableError.new(:block, nil))

  # `variant` must be a SCALAR string to print — `attr_str`'s `to_string/1`
  # raises Protocol.UndefinedError on a map. A non-binary variant is DROPPED
  # (fail-soft, mirroring the render side's unknown-variant fall-through),
  # never crashed: a hand-authored map here is noise, not an unprintable paper.
  defp drop_nonscalar_variant(%{"variant" => v} = b) when not is_binary(v),
    do: Map.delete(b, "variant")

  defp drop_nonscalar_variant(b), do: b

  # Head cells arrive in TWO shapes: the write chokepoint normalizes them to
  # inline-node lists (the canonical form BPML round-trips), while hand-authored
  # payloads may still carry the legacy %{"text" => …} map — accepted as input,
  # canonicalized on round-trip. A map WITHOUT a binary "text" (and a bare
  # string cell) used to print "" — a silent cell loss; it now refuses.
  defp head_cell(cells) when is_list(cells), do: inline(cells)
  defp head_cell(%{"text" => text}) when is_binary(text), do: esc(text)
  # A bare-string head cell (census: 6 papers, formerly a silent 500) — a legacy
  # untyped cell. Escaped verbatim; canonicalized to an inline-node list on read.
  defp head_cell(s) when is_binary(s), do: esc(s)
  defp head_cell(_other), do: raise(UnprintableError.new(:head_cell, nil))

  # One `<note>` element (grid item OR the singular widget's body). A dict item
  # spells id/label/lead + its `text` body; a BARE STRING escapes verbatim (the
  # heggemsnes-act remedies shape, a lossless read-only tolerance); an
  # inline-array (or any other) item refuses via the ONE typed refusal.
  defp note_item(%{} = i),
    do: "<note#{attr_str(i, ["id", "label", "lead"])}>#{esc(Map.get(i, "text", ""))}</note>"

  defp note_item(s) when is_binary(s), do: "<note>#{esc(s)}</note>"
  defp note_item(_other), do: raise(UnprintableError.new(:block, "notes"))

  defp empty_content?(c), do: c in [nil, [], ""]

  # Byline items are canonically BARE STRINGS (parser `tag_text`). A map item
  # `%{"value" => binary}` (generator/producer drift — the wave papers' own
  # shape) used to crash `esc(to_string(map))` with Protocol.UndefinedError,
  # escaping the callers' rescue as a RAW 500. It now coerces to the string
  # (fail-soft, mirroring head-cell/inline string coercion); any other non-binary
  # item refuses via the ONE typed refusal so the read path labels it 422.
  defp byline_item(s) when is_binary(s), do: esc(s)
  defp byline_item(%{"value" => v}) when is_binary(v), do: esc(v)
  defp byline_item(_other), do: raise(UnprintableError.new(:block, "byline"))

  # ── inline ──────────────────────────────────────────────────────────────────

  defp inline(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &inline_node/1)
  # A single inline node where a LIST belongs (census: 16 papers) — coerced
  # through the node printer rather than crashed.
  defp inline(%{} = node), do: inline_node(node)
  # A bare string where inline CONTENT belongs — a legacy string table cell /
  # list item. Escaped verbatim, not a crash.
  defp inline(s) when is_binary(s), do: esc(s)
  # Anything else (a number, nil, a boolean) is genuinely unspellable.
  defp inline(_other), do: raise(UnprintableError.new(:inline, nil))

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

  # Node-spelled inline marks — the corpus's real shapes (census: `code` 87
  # papers, `strong` 84, `em` 34). `code` carries its text in the VALUE key (a
  # scalar, no children); `strong`/`em` carry an inline-node LIST in `children`
  # (no value). Each prints to the SAME mark spelling the parser round-trips
  # into canonical text-node marks — so the SECOND print is byte-stable.
  # Guarded: a node carrying its content in the OTHER key (a `code` smuggling
  # `children`, a `strong`/`em` smuggling a `value`) would print empty — a
  # silent loss. Those shapes refuse (fail-honest) rather than guess.
  defp inline_node(%{"type" => "code"} = n) do
    case Map.get(n, "children") || [] do
      [] -> "<code>#{esc(Map.get(n, "value", ""))}</code>"
      _children -> raise(UnprintableError.new(:inline, "code"))
    end
  end

  defp inline_node(%{"type" => "strong"} = n), do: child_mark(n, "strong", "b")
  defp inline_node(%{"type" => "em"} = n), do: child_mark(n, "em", "i")

  # A raw string where an inline node belongs (census: 18 papers) — a legacy
  # untyped text run. Escaped verbatim, not a crash.
  defp inline_node(s) when is_binary(s), do: esc(s)

  # Fail-honest catchalls. `valueref` (12 papers) and `paragraph` (20) STAY a
  # typed refusal (kind :inline): a valueref resolves against live data the
  # printer cannot reach, and a paragraph is a BLOCK, unspellable inline — both
  # are honest 422s, not a lossy guess. Every other unspelled inline node type
  # lands here too, so the read path can label it 422 rather than 500.
  defp inline_node(%{"type" => type}), do: raise(UnprintableError.new(:inline, type))
  defp inline_node(_other), do: raise(UnprintableError.new(:inline, nil))

  defp child_mark(n, type, tag) do
    children = Map.get(n, "children") || []
    value = Map.get(n, "value")

    if children == [] and is_binary(value) and value != "" do
      raise(UnprintableError.new(:inline, type))
    else
      "<#{tag}>#{inline(children)}</#{tag}>"
    end
  end

  defp mark_tag("strong"), do: "b"
  defp mark_tag("em"), do: "i"
  defp mark_tag("code"), do: "code"
  defp mark_tag("underline"), do: "u"
  defp mark_tag("strike"), do: "s"

  defp mark_tag(other) when is_binary(other) or is_atom(other),
    do: raise(UnprintableError.new(:mark, other))

  defp mark_tag(_other), do: raise(UnprintableError.new(:mark, nil))

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
