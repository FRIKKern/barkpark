defmodule Barkpark.PortableDoc.Render.Inline do
  @moduledoc """
  Inline-node composition for the PortableDoc render engine — folds
  ProseMirror-style inline nodes and mark lists into Pd-tree text nodes
  (`PdText` / `PdInlineCode` / `PdLink`). Its cross-runtime twin is the
  inline-composition step of the Go `internal/pdrender` renderer, held in parity
  by the shared golden fixtures.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). Self-contained: it produces Pd-tree nodes that the Walk
  family later renders; it never calls back into compose_block or walk. Output
  is byte-identical to the pre-split engine.
  """

  # ── inline walker (inline node/marks → Pd-tree fold) ───────────────────────

  # ── RULINGS on the residual live-corpus INLINE shapes (task-e4833f198e293ed1)
  #
  # The 2026-07-25 census rendered all 537 published papers through the built
  # @barkpark/react emitter and flagged every block whose tag-stripped output was
  # empty. Four shapes were left undecided. The INLINE ones are ruled here; the
  # BLOCK-level ones are NOT this module's readers and are named only so the next
  # reader does not re-derive them.
  #
  #   INLINE · text leaf keyed `text` instead of `value` (13 list items, all in
  #     workspace-bundle-keystone) → RULED A LEGITIMATE ALIAS, not a data defect.
  #     The Hollow predicate already blesses BOTH spellings as text-carrying, so
  #     repairing the data would leave every future writer of that spelling
  #     producing a readable-by-contract, blank-in-fact paper. All three engines
  #     now dual-read it: `compose_inline(%{"type" => "text"})` below,
  #     `textLeafValue` in inline.tsx, `attrStrFirst(n, "value", "text")` in
  #     inline.go. No surface leapfrogs; nothing left to do.
  #
  #   INLINE · `code` leaf whose body is in `children` (66 live paragraphs) →
  #     FIXED CROSS-SURFACE by this row; see `inline_code_source/1`.
  #
  #   INLINE · a bare ARRAY where an inline node was expected, `[[{text…}]]`
  #     (59 paragraphs + 18 list blocks) → FIXED CROSS-SURFACE by this row; the
  #     Elixir and JS halves already shipped (`compose_inline(l) when is_list(l)`
  #     below, `if (Array.isArray(node))` in inline.tsx) and the Go reader was
  #     brought up to them (`case []any` in InlineRenderer.node).
  #
  #   NOT INLINE, DEFERRED to their own rows · a `list` block with its items in
  #     `content` (18 blocks, the authoring contract is genuinely ambiguous — one
  #     paper holds an array OF ARRAYS, another a FLAT inline run), and a
  #     `callout` whose `content` holds BLOCK nodes (4 blocks, a real change to
  #     the block grammar). Both live in `Render.Compose`, not here. A `code`
  #     BLOCK whose body is in `content[]` was closed separately by the
  #     code-block source-key contract (`Compose.code_source/1` +
  #     test/support/fixtures/code-source-aliases.json).
  #
  #   NOT A RENDER DEFECT · `inlineText/1` in js/packages/react/src/toPlainText.ts
  #     is a plain-text EXTRACTOR, not a renderer: it already concatenates a
  #     node's own value AND its children, so an inline `code` with children
  #     always yielded its text there. It does drop a bare-array node, which
  #     understates a search snippet but never blanks a rendered surface — left
  #     alone deliberately rather than changed without a measured need.

  def compose_inline_children(nodes) when is_list(nodes) do
    nodes
    |> unwrap_block_wrappers()
    |> Enum.map(&compose_inline(&1, false))
  end

  # Tolerate scalar cells (a plain string where a list of inline nodes was
  # expected — common in tables emitted by upstream converters that flatten
  # text-only cells). Treat the scalar as a single text node so the cell
  # renders as its string value instead of vanishing.
  def compose_inline_children(s) when is_binary(s), do: [s]
  def compose_inline_children(n) when is_number(n), do: [to_string(n)]
  def compose_inline_children(_), do: []

  # A BLOCK-level node sitting in an inline array — `{"type":"paragraph",
  # "content":[…]}` or `{"type":"list-item","content":[…]}` — carries its text
  # one level deeper than the inline clauses in this module look. Without this, such a
  # node falls to the catch-all `compose_inline/2` and composes to an empty
  # string: the reader serves HTTP 200 and shows an empty bullet while the prose
  # sits on disk, unreported. Measured 2026-09-02 on the live corpus: 75 list
  # items across 4 published papers (56 `paragraph`-wrapped, 19 `list-item`-
  # wrapped) rendered as `<li><span></span></li>` with their text intact in
  # storage.
  #
  # `table_cell_content/1` in `Render.Compose` already unwraps exactly this
  # shape for table cells, so the engine answered the same question two
  # different ways depending on which container asked. This is the shared fix:
  # `compose_inline_children/1` serves paragraphs, headings, list items and
  # callouts alike, so patching the list path alone would leave a heading or a
  # callout carrying the same shape just as blank.
  #
  # ONE LEVEL, and only when `content` is a NON-EMPTY list — a block node
  # without content keeps today's behaviour, and anything nesting deeper is a
  # separate finding, not something to recurse into here. Keyed on `content`
  # rather than on a type allowlist because no inline clause in this module
  # reads `"content"` at all (inline nodes carry `value`, `children` and marks),
  # so the key cannot shadow a legitimate inline node while it does catch a
  # block wrapper this corpus has not produced yet.
  defp unwrap_block_wrappers(nodes) do
    Enum.flat_map(nodes, fn
      %{"content" => [_ | _] = inner} -> inner
      node -> [node]
    end)
  end

  def compose_inline(%{"type" => "text"} = n, inside_link) do
    # Coerce a non-string `value` — a raw API/SDK/CLI mutate can persist a number
    # (or, worse, a map/list) where a text leaf's string was expected. Binaries
    # pass through, numbers stringify, anything else (map/list/bool/nil) → "" so
    # the leaf never carries a non-binary into the walker (which would crash on a
    # bare number child, or 500 on `to_string/1` over a map). Mirrors the
    # `stringish/1` fail-soft in `Render.Compose`.
    #
    # Dual-read `value` || legacy `text`: raw mutate writers persisted whole
    # papers whose text leaves were keyed `{"type":"text","text":…}`. The Hollow
    # predicate blesses BOTH spellings as text-carrying (`@text_keys`), so such
    # a paper passes every write seam as "has content" — and then rendered as
    # structure with ZERO prose (2026-08-23: 2 published papers served HTTP 200
    # with 22–34 headings and an empty-string text_sha256). The renderer must
    # agree with the predicate or the corpus can hold readable-by-contract,
    # blank-in-fact papers. Canonical `value` wins when non-empty; the Go twin
    # does the same via `attrStrFirst(n, "value", "text")` (inline.go).
    value =
      case coerce_text_value(Map.get(n, "value", "")) do
        "" -> coerce_text_value(Map.get(n, "text", ""))
        canonical -> canonical
      end

    case Map.get(n, "marks") do
      nil -> value
      [] -> value
      marks when is_list(marks) -> apply_marks(value, marks, inside_link)
      _ -> value
    end
  end

  def compose_inline(%{"type" => "strong"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "weight" => "bold",
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => "em"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "italic" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => type} = n, inside_link)
      when type in ["strikethrough", "strike", "s"] do
    %{
      "kind" => "PdText",
      "strike" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => "underline"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "underline" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  # Inline `code` leaf. The chip body is a FLAT STRING, never inlines — but a
  # sizeable slice of the live corpus authors it as `children` inline nodes with
  # no `value` at all (66 published paragraphs at the 2026-07-25 census), and
  # this clause read `value` only, so those chips composed to an EMPTY
  # PdInlineCode and the text vanished on the web, in email and in the TUI.
  #
  # @barkpark/react already carries the law this now mirrors —
  # `js/packages/react/src/inline.tsx` `inlineCodeSource`:
  #
  #     return `<code>${escapeHtml(inlineCodeSource(node))}</code>`
  #     // inlineCodeSource = str(node.value) || inlineText(node.children)
  #
  # FIRST NON-EMPTY, not first-non-blank: a `value` of `" "` WINS and keeps its
  # space. That is the opposite of the BLOCK-level `code` contract
  # (`Compose.code_source/1`, which trims to select across value|code|content|
  # text) and the difference is deliberate — a block's source key is a choice
  # among aliases, an inline chip's `value` is the authored body verbatim.
  #
  # The three engines answer to ONE fixture,
  # `api/test/support/fixtures/inline-code-source.json`: this clause via
  # `test/barkpark/portable_doc/render/inline_code_source_parity_test.exs`, the
  # SDK via `js/packages/react/tests/inline-code-source.parity.test.ts`, and the
  # Go TUI via `internal/pdrender/inline_code_source_parity_test.go`.
  def compose_inline(%{"type" => "code"} = n, _inside_link) do
    %{"kind" => "PdInlineCode", "value" => inline_code_source(n)}
  end

  def compose_inline(%{"type" => "link"} = n, inside_link) do
    children = Enum.map(Map.get(n, "children", []), &compose_inline_for_link_children(&1, true))

    if inside_link do
      # Nested link — flatten to a plain text wrapper to keep links non-recursive.
      %{"kind" => "PdText", "children" => children}
    else
      %{"kind" => "PdLink", "href" => Map.get(n, "href", ""), "children" => children}
    end
  end

  # Internal-link node kinds (storage model A — first-class AST nodes, not
  # Markdown). Targets are UNRESOLVED here; a render-time resolver task turns
  # them into hrefs/titles. Renderers degrade gracefully (raw target/name text).
  def compose_inline(%{"type" => "wikilink"} = n, inside_link) do
    children = Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    base = %{"kind" => "PdWikilink", "target" => Map.get(n, "target", ""), "children" => children}

    base =
      case Map.get(n, "alias") do
        nil -> base
        alias_val -> Map.put(base, "alias", alias_val)
      end

    # Id-pinned wikilink — the picker stamps the chosen paper's doc_id under the
    # camelCase "docId" key (JS spelling; accept "doc_id" too defensively). Carry
    # it only when present, exactly like `alias`, so a typed-not-picked wikilink
    # (no id) stays byte-identical and the walker falls back to title resolution.
    case Map.get(n, "doc_id") || Map.get(n, "docId") do
      nil -> base
      doc_id -> Map.put(base, "doc_id", doc_id)
    end
  end

  def compose_inline(%{"type" => "blockref"} = n, _inside_link) do
    %{
      "kind" => "PdBlockref",
      "target" => Map.get(n, "target", ""),
      "anchor" => Map.get(n, "anchor", "")
    }
  end

  def compose_inline(%{"type" => "tag"} = n, _inside_link) do
    %{"kind" => "PdTag", "name" => Map.get(n, "name", "")}
  end

  # Verdict chip — a coloured label with an optional qualifier under it, the
  # cell of a scorecard table and the swatch of a legend. `tone` is the
  # paperCallout tone set (success | warning | danger | info | neutral — the
  # SAME vocabulary `Util.tone_palette/1` resolves, so no sixth colour enters
  # the token system); `strong` fills the chip, the "worse than danger" step a
  # four-band scale needs. `note` renders beneath the chip. Non-string fields
  # degrade to "" — a chip never crashes a cell.
  def compose_inline(%{"type" => "chip"} = n, _inside_link) do
    %{
      "kind" => "PdChip",
      "tone" => string_or_empty(Map.get(n, "tone")),
      "strong" => Map.get(n, "strong") == true,
      "text" => string_or_empty(Map.get(n, "text")),
      "note" => string_or_empty(Map.get(n, "note"))
    }
  end

  # Inline live value (lvw-t1, wire §3). `target` is a doc_id slug; `field` a
  # single top-level declared field name. The node's `children` are the D6
  # dual-written fallback subtree for OLD renderers — NEW renderers IGNORE
  # them (the injected resolver / the `fallback` literal owns the display).
  # `as` / `label` are RESERVED: they round-trip opaquely in the STORED node
  # and are never interpreted here. Resolution happens at walk time off the
  # palette's `:values` map (see `Papers.resolve_values_in_blocks/3`); compose
  # stays pure.
  def compose_inline(%{"type" => "valueref"} = n, _inside_link) do
    %{
      "kind" => "PdValueref",
      "target" => Map.get(n, "target", ""),
      "field" => Map.get(n, "field", ""),
      "fallback" => Map.get(n, "fallback", "")
    }
  end

  # Unknown inline type → DEGRADE, never raise (wire §6). This clause replaces
  # the historical `raise ArgumentError`: one forward-compat inline node
  # reaching the renderer was 500ing the save, the body_html refresh, the
  # delta frames, and the Studio view (block_ops → inline.ex, no rescue
  # anywhere). Children, when present, still render — a D6-style node
  # dual-writes its visible fallback as a text child; a childless unknown
  # composes to the empty string, matching Go pdrender's degrade.
  def compose_inline(%{"type" => _type} = n, inside_link) do
    case Map.get(n, "children") do
      children when is_list(children) and children != [] ->
        %{"kind" => "PdText", "children" => Enum.map(children, &compose_inline(&1, inside_link))}

      _ ->
        ""
    end
  end

  # Typeless inline map (no `"type"` key at all — e.g. a bare `%{"value" => "x"}`
  # a raw mutate persisted) → DEGRADE, never raise. Reuses the unknown-type
  # children-degrade body: render children when present, else "". Must sit AFTER
  # the unknown-type clause so a typed node still hits its specific clause first.
  def compose_inline(%{} = n, inside_link) do
    case Map.get(n, "children") do
      children when is_list(children) and children != [] ->
        %{"kind" => "PdText", "children" => Enum.map(children, &compose_inline(&1, inside_link))}

      _ ->
        ""
    end
  end

  # Tolerate scalar inline nodes — upstream converters (and the list-block
  # `items: [["a"]]` shape in the public ingest contract) flatten text-only
  # inlines to bare strings/numbers. Mirrors `compose_inline_children/1`.
  def compose_inline(s, _inside_link) when is_binary(s), do: s
  def compose_inline(n, _inside_link) when is_number(n), do: to_string(n)

  # A bare list where an inline node was expected (`[["a"]]` cells flattened one
  # level too shallow) → wrap the composed children in a PdText so the contained
  # text survives instead of crashing the walker on a list child.
  def compose_inline(l, _inside_link) when is_list(l) do
    %{"kind" => "PdText", "children" => compose_inline_children(l)}
  end

  # Final catch-all — nil / booleans / anything else compose to "" (matches Go
  # pdrender's degrade), so a poisoned inline node never sinks its siblings.
  def compose_inline(_, _inside_link), do: ""

  # Link children are PdText | string only.
  defp compose_inline_for_link_children(node, inside_link) do
    case compose_inline(node, inside_link) do
      s when is_binary(s) -> s
      %{"kind" => "PdText"} = t -> t
      # `code` or a flattened nested link → wrap in a PdText so the type holds.
      other -> %{"kind" => "PdText", "children" => [other]}
    end
  end

  @doc """
  The body of an inline `code` leaf: `value` when it is a non-empty string,
  else the flattened plain text of `children`.

  Twins: `inlineCodeSource` in `js/packages/react/src/inline.tsx` and
  `inlineCodeSource` in `internal/pdrender/inline.go`. All three are locked to
  `api/test/support/fixtures/inline-code-source.json`.
  """
  def inline_code_source(%{} = n) do
    case coerce_text_value(Map.get(n, "value", "")) do
      "" -> flatten_inline_text(Map.get(n, "children"))
      value -> value
    end
  end

  def inline_code_source(_), do: ""

  # Fold inline nodes to their concatenated plain text (markup is DROPPED — a
  # code chip body is a flat string). Mirrors `inlineText` in inline.tsx:
  # a string/finite number is itself, a map is `value` || legacy `text` || its
  # own children, a nested array recurses, anything else contributes "".
  defp flatten_inline_text(s) when is_binary(s), do: s
  defp flatten_inline_text(n) when is_number(n), do: to_string(n)

  defp flatten_inline_text(nodes) when is_list(nodes),
    do: Enum.map_join(nodes, "", &flatten_inline_text_node/1)

  defp flatten_inline_text(_), do: ""

  defp flatten_inline_text_node(%{} = n) do
    case coerce_text_value(Map.get(n, "value", "")) do
      "" ->
        case coerce_text_value(Map.get(n, "text", "")) do
          "" -> flatten_inline_text(Map.get(n, "children"))
          legacy -> legacy
        end

      value ->
        value
    end
  end

  defp flatten_inline_text_node(other), do: flatten_inline_text(other)

  # Fail-soft coercion for a text leaf's `value` — binaries pass through,
  # numbers stringify, anything else (map / list / bool / nil) → "". NEVER calls
  # `to_string/1` on a map (that raises Protocol.UndefinedError). Mirrors
  # `Render.Compose.stringish/1`.
  defp coerce_text_value(v) when is_binary(v), do: v
  defp coerce_text_value(v) when is_number(v), do: to_string(v)
  defp coerce_text_value(_), do: ""

  # Fold a ProseMirror-style mark list right-to-left around a text leaf,
  # so the first mark in the list ends up as the OUTERMOST wrapper (matches
  # ProseMirror's serializer order). `code` is leaf-only — it produces a
  # PdInlineCode and any remaining marks wrap that node via PdText.
  defp apply_marks(value, marks, inside_link) do
    marks
    |> Enum.reverse()
    |> Enum.reduce(value, fn mark, acc -> apply_mark(mark, acc, inside_link) end)
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["bold", "strong"] do
    %{"kind" => "PdText", "weight" => "bold", "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["italic", "em"] do
    %{"kind" => "PdText", "italic" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => "underline"}, acc, _il) do
    %{"kind" => "PdText", "underline" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["strike", "s", "strikethrough"] do
    %{"kind" => "PdText", "strike" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => "code"}, acc, _il) when is_binary(acc) do
    %{"kind" => "PdInlineCode", "value" => acc}
  end

  defp apply_mark(%{"type" => "code"}, acc, _il) do
    # Already wrapped by an outer mark; keep the wrapper and don't fight it.
    acc
  end

  defp apply_mark(%{"type" => "link"} = mark, acc, inside_link) do
    href = get_in(mark, ["attrs", "href"]) || Map.get(mark, "href", "")
    children = wrap_children(acc) |> Enum.map(&link_child(&1, true))

    if inside_link do
      # Mirror the nested-link clause in compose_inline/2 — flatten to PdText.
      %{"kind" => "PdText", "children" => children}
    else
      %{"kind" => "PdLink", "href" => href, "children" => children}
    end
  end

  defp apply_mark(%{"type" => "wikilink"} = mark, acc, _il) do
    base = %{
      "kind" => "PdWikilink",
      "target" => get_in(mark, ["attrs", "target"]) || "",
      "children" => wrap_children(acc)
    }

    base =
      case get_in(mark, ["attrs", "alias"]) do
        nil -> base
        alias_val -> Map.put(base, "alias", alias_val)
      end

    # Carry the id-pinned doc_id off the mark attrs (TipTap stamps "docId";
    # accept "doc_id" too), only when present — mirrors the node clause above.
    case get_in(mark, ["attrs", "doc_id"]) || get_in(mark, ["attrs", "docId"]) do
      nil -> base
      doc_id -> Map.put(base, "doc_id", doc_id)
    end
  end

  defp apply_mark(%{"type" => "blockref"} = mark, _acc, _il) do
    # Read target/anchor from attrs ONLY — the text leaf carries the "^anchor"
    # DISPLAY token, never the bare anchor (must NOT fall back to acc).
    %{
      "kind" => "PdBlockref",
      "target" => get_in(mark, ["attrs", "target"]) || "",
      "anchor" => get_in(mark, ["attrs", "anchor"]) || ""
    }
  end

  defp apply_mark(%{"type" => "tag"} = mark, _acc, _il) do
    %{"kind" => "PdTag", "name" => get_in(mark, ["attrs", "name"]) || ""}
  end

  # valueref MARK form — the paper editor round-trips the node through a text
  # leaf carrying a `valueref` mark (convert.js `LEAF_KINDS`); read the wire
  # fields from attrs ONLY and DISCARD the display text (`acc` is the D6
  # fallback display token — resolver/fallback own the render, mirroring the
  # node clause above and the blockref mark rule).
  defp apply_mark(%{"type" => "valueref"} = mark, _acc, _il) do
    %{
      "kind" => "PdValueref",
      "target" => get_in(mark, ["attrs", "target"]) || "",
      "field" => get_in(mark, ["attrs", "field"]) || "",
      "fallback" => get_in(mark, ["attrs", "fallback"]) || ""
    }
  end

  # Unknown marks pass through (no wrapper).
  defp apply_mark(_unknown, acc, _il), do: acc

  defp wrap_children(acc) when is_binary(acc), do: [acc]
  defp wrap_children(acc) when is_list(acc), do: acc
  defp wrap_children(acc), do: [acc]

  # Chip fields are display strings; anything else (nil, a number, a map from a
  # hostile payload) reads as empty rather than crashing the cell.
  defp string_or_empty(v) when is_binary(v), do: v
  defp string_or_empty(_), do: ""

  defp link_child(s, _il) when is_binary(s), do: s
  defp link_child(%{"kind" => "PdText"} = t, _il), do: t
  defp link_child(other, _il), do: %{"kind" => "PdText", "children" => [other]}

  @doc """
  Coerce an inline child into a Pd-node for table cells.
  """
  def to_pd_node_from_inline_child(child) when is_binary(child) do
    %{"kind" => "PdText", "children" => [child]}
  end

  def to_pd_node_from_inline_child(child), do: child
end
