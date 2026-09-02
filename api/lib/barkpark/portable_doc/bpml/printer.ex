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
    do: heading_line(l, b, d)

  # The stored corpus spells the heading level BOTH ways: 283 integer levels and
  # 225 numeric STRINGS ("2" 119, "3" 102, "1" 9) across the 26 published papers
  # that refuse on a KERNEL block type (census 2026-08-24, re-measured
  # 2026-09-02). A string level matched no heading clause and fell through to
  # the fail-honest catch-all, so `bp paper pull` answered 422 with
  # `block type "heading" is outside the BPML kernel vocabulary` — a refusal on
  # a type this module spells, over the SPELLING of one scalar.
  #
  # Coercing is not a guess. The RENDER side already collapses both spellings
  # onto one outline level (`heading_level("2") -> 2`,
  # render/compose.ex heading_level/1), so printing them identically spells the
  # heading every reader already sees.
  #
  # DELIBERATELY NARROW — exactly "1" / "2" / "3". "01", " 2", "4" and every
  # junk spelling keep falling through; see the note above the catch-all.
  defp block(%{"type" => "heading", "level" => l} = b, d) when l in ~w(1 2 3),
    do: heading_line(String.to_integer(l), b, d)

  defp block(%{"type" => "paragraph"} = b, d), do: inline_tag("p", b, d)
  defp block(%{"type" => "pullquote"} = b, d), do: inline_tag("pullquote", b, d)
  defp block(%{"type" => "ingress"} = b, d), do: inline_tag("ingress", b, d)

  defp block(%{"type" => "byline"} = b, d) do
    items =
      Enum.map(
        alias_get(b, ["items", "content"]) || [],
        &"#{pad(d + 1)}<item>#{byline_item(&1)}</item>"
      )

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
    do:
      pad(d) <>
        "<code#{attr_str(b, ["id"])}>" <>
        "#{esc(plain_alias(b, ["value", "code", "content", "text"]) || "")}</code>"

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
      Enum.map(alias_get(b, ["steps", "items"]) || [], fn s ->
        # A step's body is canonically `blocks`; the corpus also spells it
        # `content` (a nested block list, not inline nodes).
        case alias_get(s, ["blocks", "content"]) || [] do
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
      case alias_get(b, ["head", "header", "headers", "columns"]) || [] do
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
    children = Enum.map(alias_get(b, ["blocks", "children"]) || [], &block(&1, d + 1))
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
    body = alias_get(b, ["children", "blocks"]) || []
    children = Enum.map(body, &block(&1, d + 1))
    summary = plain_alias(b, ["summary", "title"])
    attrs = attr_str(%{"id" => Map.get(b, "id"), "summary" => summary}, ["id", "summary"])
    wrap("expandable", attrs, children, d)
  end

  # THE HEADING-LEVEL DECISION, recorded. A NIL/ABSENT level (20 blocks / 4
  # papers: barkpark-cli-reliability-wave-2026-07-22,
  # bp-cloud-build-doneset-audit-2026-08-18,
  # enterprise-auth-done-set-audit-wave-2026-08-18, felix-pristine-wave-2026-08-18)
  # and a JUNK level ("h2" 6, "w14-h2" 5, "h3" 5, "state", "live", … — 28 blocks
  # / 4 papers) both KEEP REFUSING, by decision, through the catch-all below.
  #
  # The renderer's own fallback for both is `heading_level(_) -> 2`
  # (render/compose.ex heading_level/1) and this printer deliberately does NOT
  # borrow it. The renderer's default is a DISPLAY choice: the stored block
  # keeps its real shape and an author can still state the level later. This
  # printer's output is what `bp paper push` writes BACK, so defaulting here
  # would persist an invented `<h2>` over the block — a pull/push the author
  # never edited would silently restructure the document outline, and
  # "w14-h2" is not an outline level in the first place. Charter D3: a shape
  # the kernel cannot spell HONESTLY takes the typed refusal. Those 8 papers
  # stay at 422 until an author states a level.
  #
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
  # The header-row ALIAS keys (`header`/`headers`/`columns`) carry their cells
  # in two further dict shapes — `%{"header" => binary}` (371 cells) and
  # `%{"content" => inline_nodes}` (298). Both spell losslessly, so they are
  # read rather than refused; the parser returns the canonical inline-node
  # list, so the second print is byte-stable.
  defp head_cell(%{"header" => text}) when is_binary(text), do: esc(text)
  defp head_cell(%{"content" => content}) when is_list(content), do: inline(content)
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

  # Inline content is emitted as a MARK TREE, not node by node: adjacent runs
  # that share a leading mark are wrapped in it ONCE.
  #
  # WHY — the round trip was not a fixed point. A `%{"type" => "strong",
  # "children" => [text "Phase ", code "Ping"]}` printed
  # `<b>Phase <code>Ping</code></b>`. The parser then (correctly) distributes
  # the mark over every run the element covers and returned two text nodes,
  # `marks: ["strong"]` and `marks: ["strong", "code"]`; printing those one at
  # a time re-emitted `<b>Phase </b><b><code>Ping</code></b>` — the same
  # characters, different element boundaries. So `bp paper pull` followed by
  # `bp paper push` with NO EDIT rewrote the stored paper and `bp paper diff`
  # reported a change on an untouched file: 12 of the 570 printable published
  # papers (census 2026-08-24, re-measured 2026-09-02 — the same 12).
  #
  # The fix belongs HERE and not in the parser: the parser's output should stay
  # faithful to the markup it read (each run carries the marks that actually
  # cover it), and this module's moduledoc already claims to be the one place
  # that defines THE canonical spelling. Coalescing is that decision.
  #
  # TWO PASSES, because the corpus spells the same thing two ways and both must
  # take part in the same run:
  #
  #   `expand/2`     every inline spelling → `{marks, body}` — the marks that
  #                  cover a run of characters, and the rendered characters. A
  #                  text node's `marks` list and the NODE-spelled `strong` /
  #                  `em` / `code` inlines collapse onto the same
  #                  representation, so `<b>a</b><b><code>b</code></b>` stored
  #                  as three sibling `strong` nodes prints as one `<b>` too
  #                  (2 papers churned on exactly that until this pass existed).
  #   `inline_run/2` walks that flat list and opens each shared mark once.
  defp inline(content), do: content |> expand([]) |> inline_run([])

  # ── pass 1: every inline spelling → {marks, body} ───────────────────────────

  defp expand(nodes, marks) when is_list(nodes),
    do: Enum.flat_map(nodes, &expand_node(&1, marks))

  # A single inline node where a LIST belongs (census: 16 papers) — coerced
  # rather than crashed.
  defp expand(%{} = node, marks), do: expand_node(node, marks)
  # A bare string where inline CONTENT belongs — a legacy string table cell /
  # list item. Escaped verbatim, not a crash.
  defp expand(s, marks) when is_binary(s), do: [{marks, esc(s)}]
  # Anything else (a number, nil, a boolean) is genuinely unspellable.
  defp expand(_other, _marks), do: raise(UnprintableError.new(:inline, nil))

  defp expand_node(%{"type" => "text"} = n, marks),
    do: [{marks ++ node_marks(n), text_value(Map.get(n, "value", ""))}]

  # Node-spelled inline marks — the corpus's real shapes (census: `code` 87
  # papers, `strong` 84, `em` 34). `code` carries its text in the VALUE key (a
  # scalar, no children); `strong`/`em` carry an inline-node LIST in `children`
  # (no value). Guarded: a node carrying its content in the OTHER key (a `code`
  # smuggling `children`, a `strong`/`em` smuggling a `value`) would print
  # empty — a silent loss. Those shapes refuse (fail-honest) rather than guess.
  defp expand_node(%{"type" => "code"} = n, marks) do
    case Map.get(n, "children") || [] do
      [] -> [{marks ++ ["code"], esc(Map.get(n, "value", ""))}]
      _children -> raise(UnprintableError.new(:inline, "code"))
    end
  end

  defp expand_node(%{"type" => "strong"} = n, marks), do: expand_child_mark(n, "strong", marks)
  defp expand_node(%{"type" => "em"} = n, marks), do: expand_child_mark(n, "em", marks)

  # A link is opaque to the run: it spells its own element and its children are
  # a fresh inline context (the parser refuses a link INSIDE a mark, so a link
  # never carries an enclosing mark of its own).
  defp expand_node(%{"type" => "link"} = n, marks),
    do: [
      {marks,
       ~s(<a href="#{esc_attr(Map.get(n, "href", ""))}">) <>
         inline(Map.get(n, "children", [])) <> "</a>"}
    ]

  # A raw string where an inline node belongs (census: 18 papers) — a legacy
  # untyped text run. Escaped verbatim, not a crash.
  defp expand_node(s, marks) when is_binary(s), do: [{marks, esc(s)}]

  # Fail-honest catchalls. `valueref` (12 papers) and `paragraph` (20) STAY a
  # typed refusal (kind :inline): a valueref resolves against live data the
  # printer cannot reach, and a paragraph is a BLOCK, unspellable inline — both
  # are honest 422s, not a lossy guess. Every other unspelled inline node type
  # lands here too, so the read path can label it 422 rather than 500.
  defp expand_node(%{"type" => type}, _marks), do: raise(UnprintableError.new(:inline, type))
  defp expand_node(_other, _marks), do: raise(UnprintableError.new(:inline, nil))

  defp expand_child_mark(n, type, marks) do
    children = Map.get(n, "children") || []
    value = Map.get(n, "value")

    if children == [] and is_binary(value) and value != "" do
      raise(UnprintableError.new(:inline, type))
    else
      expand(children, marks ++ [type])
    end
  end

  # Only a TEXT node carries a `marks` list. A value that is not a list used to
  # reach `Enum.reverse/1` and escape as a raw 500; it takes the ONE typed
  # refusal instead.
  defp node_marks(%{"marks" => marks}) when is_list(marks), do: marks
  defp node_marks(%{"marks" => nil}), do: []
  defp node_marks(%{"marks" => _other}), do: raise(UnprintableError.new(:mark, nil))
  defp node_marks(_n), do: []

  # ── pass 2: open each shared mark exactly once ──────────────────────────────

  # `open` is the mark prefix already emitted around every run in the list; the
  # entry point opens nothing. Every run carries `open` as a prefix of its own
  # marks, which is what makes `Enum.at(marks, length(open))` the next mark to
  # open. It terminates: a group always holds at least its head, so both
  # recursive calls take a strictly shorter list.
  defp inline_run([], _open), do: ""

  defp inline_run([{marks, body} | rest] = runs, open) do
    if marks == open do
      body <> inline_run(rest, open)
    else
      mark = Enum.at(marks, length(open))
      tag = mark_tag(mark)
      prefix = open ++ [mark]

      {group, tail} =
        runs
        |> Enum.split_while(fn {m, _} -> Enum.take(m, length(prefix)) == prefix end)
        |> keep_sibling_boundary(marks)

      "<#{tag}>" <> inline_run(group, prefix) <> "</#{tag}>" <> inline_run(tail, open)
    end
  end

  # The ONE boundary that is not churn: two adjacent runs carrying EXACTLY the
  # same marks were two elements, and the parser hands them back as two nodes.
  # `<code>tr -d '</code><code>x</code>` is not `<code>tr -d 'x</code>`, so
  # merging those would make the round trip churn in the other direction (it
  # did, on 3 papers, before this clause). Only a boundary that SPLITS a mark
  # shared by runs of DIFFERENT depth gets closed — that split is the defect.
  defp keep_sibling_boundary({[single], tail}, _marks), do: {[single], tail}

  defp keep_sibling_boundary({[first | rest] = group, tail}, marks) do
    if Enum.all?(rest, fn {m, _} -> m == marks end),
      do: {[first], rest ++ tail},
      else: {group, tail}
  end

  defp mark_tag("strong"), do: "b"
  defp mark_tag("em"), do: "i"
  defp mark_tag("code"), do: "code"
  defp mark_tag("underline"), do: "u"
  defp mark_tag("strike"), do: "s"

  defp mark_tag(other) when is_binary(other) or is_atom(other),
    do: raise(UnprintableError.new(:mark, other))

  defp mark_tag(_other), do: raise(UnprintableError.new(:mark, nil))

  # ── alias-key read tolerance ────────────────────────────────────────────────
  #
  # The corpus stores the SAME body under more than one key per block type:
  # producers drifted over time, and the RENDER side reads several spellings
  # while this printer read exactly one. Reading one key meant the element
  # printed EMPTY, the pull answered 200, and `bp paper push` wrote that
  # emptiness back over the stored paper — silent destruction of 2974 blocks in
  # 254 of the 567 pullable published papers (census 2026-08-24).
  #
  # The rule — the same read-tolerance / canonical-write contract `head_cell/2`
  # and the `expandable` body already document: ACCEPT every spelling on read,
  # EMIT the canonical one. The BODY is the invariant, not the key. The parser
  # returns the canonical key, so printing the parse is a fixed point (the
  # idempotence leg of bpml_roundtrip_property_test.exs pins exactly that).
  #
  # A key present but EMPTY is not an answer — it falls through to the next
  # spelling, which is what makes `%{"content" => [], "text" => "x"}` print "x".
  defp alias_get(b, keys) do
    Enum.find_value(keys, fn k ->
      case Map.get(b, k) do
        v when v in [nil, "", [], %{}] -> nil
        v -> v
      end
    end)
  end

  # `<h1..3>` and `<eyebrow>` hold PLAIN escaped text — the spelling carries no
  # marks. An UNMARKED inline array flattens losslessly (all 4878 content-keyed
  # heading bodies in the corpus are exactly that shape). A body carrying a MARK
  # or a non-text node cannot be spelled here, so it takes the ONE typed refusal
  # rather than dropping the mark silently — the whole point of this module.
  defp plain_body(b, keys), do: esc(plain_alias(b, keys) || "")

  # The PLAIN-TEXT reading of an alias body, for every position that holds
  # escaped text rather than inline markup: `<h1..3>`, `<eyebrow>`, `<code>`,
  # and the `summary` ATTRIBUTE. An alias key can hold the body as a bare
  # string OR as an inline-node list (14 `code` blocks and 1 `expandable`
  # carry a list in the corpus) — a list reaches `esc/1`'s `to_string/1`
  # fallback and raises ArgumentError, which is NOT an UnprintableError and so
  # would escape the read path's rescue as a raw 500. It flattens instead.
  defp plain_alias(b, keys) do
    case alias_get(b, keys) do
      nil -> nil
      s when is_binary(s) -> s
      nodes when is_list(nodes) -> flatten_plain(nodes)
      _other -> raise(UnprintableError.new(:inline, nil))
    end
  end

  defp flatten_plain(nodes) do
    Enum.map_join(nodes, "", fn
      %{"type" => "text", "value" => v} = n when is_binary(v) ->
        if Map.get(n, "marks", []) == [],
          do: v,
          else: raise(UnprintableError.new(:mark, "plain-text position"))

      s when is_binary(s) ->
        s

      %{"type" => type} ->
        raise(UnprintableError.new(:inline, type))

      _other ->
        raise(UnprintableError.new(:inline, nil))
    end)
  end

  # A text node's `value` is canonically a binary. Producer drift also nests a
  # TYPED INLINE NODE there (`%{"type" => "code", "value" => …}`). That shape
  # used to reach `esc/1`'s `to_string/1` fallback, which raises
  # Protocol.UndefinedError on a map — NOT an UnprintableError, so it escaped
  # the read path's rescue as a raw HTTP 500 (1 paper on the 2026-08-24 census:
  # ctx-compression-handle-doctrine). A typed node now prints through the node
  # printer (lossless); any other non-binary takes the typed refusal.
  defp text_value(v) when is_binary(v), do: esc(v)
  defp text_value(%{"type" => _} = node), do: inline([node])
  defp text_value(v) when is_number(v) or is_boolean(v), do: esc(to_string(v))
  defp text_value(nil), do: ""
  defp text_value(_other), do: raise(UnprintableError.new(:inline, "text"))

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp heading_line(l, b, d),
    do: pad(d) <> "<h#{l}#{attr_str(b, ["id"])}>#{plain_body(b, ["text", "content"])}</h#{l}>"

  defp text_tag(tag, b, d),
    do: pad(d) <> "<#{tag}#{attr_str(b, ["id"])}>#{plain_body(b, ["text", "content"])}</#{tag}>"

  defp inline_tag(tag, b, d),
    do:
      pad(d) <>
        "<#{tag}#{attr_str(b, ["id"])}>#{inline(alias_get(b, ["content", "text"]) || [])}</#{tag}>"

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
