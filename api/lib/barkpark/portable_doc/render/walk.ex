defmodule Barkpark.PortableDoc.Render.Walk do
  @moduledoc """
  Pd-tree → inline-styled HTML string emission for the PortableDoc render
  engine — `walk/3` plus one private renderer per PdNode kind.

  `walk/3` threads the render `palette` (email default) alongside the width.
  Email values equal the module constants, so email output is byte-identical
  to the pre-palette walker; the article palette only diverges where the
  compose clauses stamped a `_role` / `_heading_level` hint.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). This is the WALK recursive tree (`walk` ↔ `render_children`
  ↔ per-kind renderers); it never calls compose_block / compose_inline. It
  depends only on `Render.Util` (escape / safe_url / tone) and the mono-font
  constant. Output is byte-identical to the pre-split engine.
  """

  import Barkpark.PortableDoc.Render.Util,
    only: [escape_html: 1, escape_attr: 1, safe_url: 1, tone_palette: 1]

  @font_mono Barkpark.PortableDoc.Render.Palettes.font_mono()
  @brand_text Barkpark.PortableDoc.Render.Palettes.brand_text()

  # Max cells a single sheet merge may cover before this public render path
  # drops it. Papers never pass the sheet plugin's before_save merge
  # sanitizer, so an author-crafted embed can carry an oversized merge here.
  # Mirrors the canonical `Barkpark.Plugins.Sheets.merge_area_cap/0` value; a
  # local attr keeps portable_doc decoupled from the plugin namespace.
  @merge_area_cap 10_000

  # Engine error vocabulary, single-sourced from the sheet engine (never a
  # copied literal) so a new code lights up the paper embed's red marking in
  # lockstep with Studio's `sheet-err`. A cell whose plain string is in this
  # set renders red/bold in BOTH palettes.
  @error_values Barkpark.Plugins.Sheets.Engine.error_values()

  # A sheet cell whose ENTIRE value is an http(s) URL renders as a clickable
  # anchor in the paper embed (and thus the .html export). The regex pins
  # http(s) and bans whitespace/quote/angle chars so an attribute-breaking
  # payload can never match ("see http://x" stays plain text); `safe_url/1`
  # re-checks the scheme allowlist as belt-and-suspenders. Twin of Studio
  # `Cells.link?/1` and web `isHttpUrl`.
  @sheet_url_re ~r/^https?:\/\/[^\s<>"']+$/i

  # Spreadsheet-default alignment, mirrored from the Studio grid's
  # `Cells.default_align_class/1` (cycle-14): numbers and number-fmt values
  # read right-aligned like Sheets/Excel General, booleans/checkboxes center,
  # text inherits the table's left. The snapshot grid is all display STRINGS
  # (`Core.display_value/1` already ran), so the value-shape rule re-derives from
  # the display shapes that formatter vocabulary can emit: General numbers
  # (incl. the kept exponent forms), `thousands` grouping, `currency` `$`,
  # `percent` `%`, `fixed` decimals — plus the ISO date/datetime strings.
  @sheet_numeric_display_re ~r/^-?\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?%?$/
  @sheet_temporal_display_re ~r/^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}:\d{2})?$/

  @doc """
  Render a Pd-tree node (or list) to its HTML body fragment under the given
  width budget + palette. The `doctype: false` body twin of `render_html` —
  used by the facade's full-document render and by the generic `figure_html`
  bridge to walk a composed child.
  """
  def render_body(node, width, pal), do: walk(node, width, pal)

  # ── walk: one clause per PdNode kind ───────────────────────────────────────

  def walk(%{"kind" => "PdContainer"} = n, width, pal), do: container(n, width, pal)
  def walk(%{"kind" => "PdBox"} = n, width, pal), do: box(n, width, pal)
  def walk(%{"kind" => "PdHeading"} = n, width, pal), do: heading(n, width, pal)
  def walk(%{"kind" => "PdParagraph"} = n, width, pal), do: paragraph(n, width, pal)
  def walk(%{"kind" => "PdText"} = n, width, pal), do: text(n, width, pal)
  def walk(%{"kind" => "PdLink"} = n, width, pal), do: link(n, width, pal)

  # Article chip mirrors the editor's own CSS byte-for-byte: root.html.heex
  # `.bp-paper-surface code` (:2340-2343) and `.bp-paper-editor-body code`
  # (:2912-2915) both declare 0.92em / 0.08em 0.35em padding / 3px radius —
  # so View↔Edit no longer jump on a mode toggle, and standalone `/papers`
  # pages get the rounded chip even where the surface CSS doesn't reach.
  # Palette-gated so the generic clause below keeps email output byte-identical.
  def walk(%{"kind" => "PdInlineCode"} = n, _width, %{style: :article} = pal) do
    ~s(<code style="background:#{pal.code_bg};padding:0.08em 0.35em;border-radius:3px;font-family:#{@font_mono};font-size:0.92em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  def walk(%{"kind" => "PdInlineCode"} = n, _width, pal) do
    ~s(<code style="background:#{pal.code_bg};padding:2px 6px;font-family:#{@font_mono};font-size:0.95em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  def walk(%{"kind" => "PdWikilink"} = n, width, pal), do: wikilink(n, width, pal)
  def walk(%{"kind" => "PdEmbed"} = n, _width, pal), do: embed(n, pal)
  def walk(%{"kind" => "PdBlockref"} = n, _width, pal), do: blockref(n, pal)
  def walk(%{"kind" => "PdTag"} = n, _width, pal), do: tag_node(n, pal)
  def walk(%{"kind" => "PdValueref"} = n, _width, pal), do: valueref(n, pal)

  def walk(%{"kind" => "PdButton"} = n, _width, pal), do: button(n, pal)
  def walk(%{"kind" => "PdHr"} = n, _width, pal), do: hr(n, pal)
  def walk(%{"kind" => "PdImage"} = n, _width, _pal), do: image(n)
  def walk(%{"kind" => "PdTable"} = n, width, pal), do: table(n, width, pal)
  def walk(%{"kind" => "PdSheet"} = n, width, pal), do: sheet(n, width, pal)
  def walk(%{"kind" => "PdCallout"} = n, width, pal), do: callout(n, width, pal)
  def walk(%{"kind" => "PdList"} = n, width, pal), do: list(n, width, pal)
  def walk(%{"kind" => "PdListItem"} = n, width, pal), do: list_item(n, width, pal)

  # `_raw` is a pre-rendered HTML escape hatch. The diagram / figure compose
  # clauses emit it because their `<figure>` / `<pre class="mermaid">` markup
  # must reach the DOM byte-exact (the Mermaid engine selects on `pre.mermaid`)
  # — they can't round-trip through the PdText escape path. The HTML they carry
  # is built from already-escaped parts in `diagram_html` / `figure_html`.
  def walk(%{"kind" => "_raw", "html" => html}, _width, _pal), do: html

  # Tolerant NUMBER leaf — a bare number can reach the walker as a child (a
  # coerced-away text value, a malformed Pd node). Emit its escaped string
  # instead of crashing (`render_children` calls walk on every child, with no
  # binary special-casing). Mirrors the inline binary-child escaping above.
  def walk(n, _width, _pal) when is_number(n), do: escape_html(to_string(n))

  # Unknown PdNode kind → DEGRADE, never raise (mirrors compose.ex's
  # `unknown_block_node/1`, #857). Papers are schemaless; a forward-compat or
  # corrupt Pd-node reaching the walker used to 500 every render surface. The
  # kind is stringished then escape_html'd so a hostile kind can't inject markup.
  def walk(%{"kind" => kind}, _width, _pal) do
    ~s(<div class="bp-unknown-block">Unsupported block: ) <>
      escape_html(to_string(kind)) <> "</div>"
  end

  # Final catch-all — a map with no `"kind"`, a list, nil, a boolean: any
  # non-node leaf degrades to "" so a poisoned child never sinks the render.
  def walk(_, _width, _pal), do: ""

  # ── per-kind renderers ──────────────────────────────────────────────────────

  defp container(n, width, pal) do
    # Trap: clamp container width with min(maxWidth, width).
    # Match TS `n.maxWidth ?? width` (nullish, not falsy) so a literal `0`
    # maxWidth is honored rather than silently replaced by the budget.
    w = min(Map.get(n, "maxWidth", width), width)
    inner = render_children(Map.get(n, "children", []), w, pal)

    ~s(<div style="max-width:#{w}px;margin:0 auto;padding:24px;font-family:#{pal.font_body};color:#{pal.text};background:#{pal.paper}">) <>
      inner <> "</div>"
  end

  defp box(n, width, pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)
    ~s(<div style="#{box_style(Map.get(n, "style"))}">) <> inner <> "</div>"
  end

  defp box_style(nil), do: ""

  defp box_style(s) do
    []
    |> maybe_flex(s)
    |> maybe_push(s, "width", fn v -> "width:#{escape_attr(to_string(v))}px" end)
    |> maybe_push(s, "height", fn v -> "height:#{escape_attr(to_string(v))}px" end)
    |> maybe_push(s, "padding", fn v -> "padding:#{escape_attr(to_string(v))}px" end)
    |> maybe_push(s, "margin", fn v -> "margin:#{escape_attr(to_string(v))}px" end)
    |> maybe_border(s)
    |> maybe_push(s, "backgroundColor", fn v ->
      "background-color:#{escape_attr(to_string(v))}"
    end)
    |> maybe_push(s, "verticalAlign", fn v -> "vertical-align:#{escape_attr(to_string(v))}" end)
    |> Enum.reverse()
    |> Enum.join(";")
  end

  defp maybe_flex(out, s) do
    case Map.get(s, "flexDirection") do
      nil -> out
      dir -> ["flex-direction:#{escape_attr(to_string(dir))}", "display:flex" | out]
    end
  end

  # Numeric / string keys that are emitted only when present (not nil).
  defp maybe_push(out, s, key, fmt) do
    case Map.get(s, key) do
      nil -> out
      v -> [fmt.(v) | out]
    end
  end

  defp maybe_border(out, s) do
    bw = Map.get(s, "borderWidth")
    bc = Map.get(s, "borderColor")
    bs = Map.get(s, "borderStyle")

    if (bw != nil and bc) && bs do
      [
        "border:#{escape_attr(to_string(bw))}px #{css_border_style(bs)} #{escape_attr(to_string(bc))}"
        | out
      ]
    else
      out
    end
  end

  # 'single' and 'bold' both map to solid in HTML; thickness conveys bold-ness.
  defp css_border_style("double"), do: "double"
  defp css_border_style(_), do: "solid"

  defp text(n, width, pal) do
    # Trap: PdText.children mixes raw strings (escaped) and child nodes (recursed).
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    out = []
    out = if Map.get(n, "weight") == "bold", do: ["font-weight:bold" | out], else: out
    out = if Map.get(n, "italic"), do: ["font-style:italic" | out], else: out

    deco = []
    deco = if Map.get(n, "underline"), do: ["underline" | deco], else: deco
    deco = if Map.get(n, "strike"), do: ["line-through" | deco], else: deco

    out =
      if deco != [] do
        ["text-decoration:#{deco |> Enum.reverse() |> Enum.join(" ")}" | out]
      else
        out
      end

    out = if Map.get(n, "color"), do: ["color:#{Map.get(n, "color")}" | out], else: out

    # Article-only typographic roles. These prepend their own declarations and,
    # for headings, REPLACE the plain `font-weight:bold` with a level-sized rule.
    # In email mode (or with no hint) `out` is untouched → byte-identical span.
    {out, inner} = apply_text_role(out, inner, n, pal)

    out = Enum.reverse(out)

    # Trap: emit NO style= attr when the style list is empty.
    if out == [] do
      "<span>#{inner}</span>"
    else
      ~s(<span style="#{Enum.join(out, ";")}">#{inner}</span>)
    end
  end

  # Article-mode paragraph — same role-aware styling as PdText, but emits a
  # semantic `<p>` instead of `<span>`. The editor's
  # `.bp-paper-surface p { margin: 12pt 0 0; hyphens: auto }` rule
  # (root.html.heex ~:2068) only matches real `<p>` elements; the previous
  # `<span>`-wrapped paragraphs collapsed against each other in the desk View
  # pane because there were no `<p>` margins to space them. compose_block
  # paragraph/ingress/byline emit PdParagraph in article mode so the editor's
  # body typography (font-size 18px, line-height 1.70, margin rhythm)
  # actually applies. Email/default mode keeps PdText (`<span>`) for
  # byte-stable export.
  defp paragraph(n, width, pal) do
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    out = []
    out = if Map.get(n, "weight") == "bold", do: ["font-weight:bold" | out], else: out
    out = if Map.get(n, "italic"), do: ["font-style:italic" | out], else: out

    deco = []
    deco = if Map.get(n, "underline"), do: ["underline" | deco], else: deco
    deco = if Map.get(n, "strike"), do: ["line-through" | deco], else: deco

    out =
      if deco != [] do
        ["text-decoration:#{deco |> Enum.reverse() |> Enum.join(" ")}" | out]
      else
        out
      end

    out = if Map.get(n, "color"), do: ["color:#{Map.get(n, "color")}" | out], else: out
    {out, inner} = apply_text_role(out, inner, n, pal)
    out = Enum.reverse(out)

    if out == [] do
      "<p>#{inner}</p>"
    else
      ~s(<p style="#{Enum.join(out, ";")}">#{inner}</p>)
    end
  end

  # Real semantic heading (article mode only — the compose clause emits this
  # kind exclusively under `:article`). Renders `<h1>` / `<h2>` / `<h3>` by
  # clamped level with the level-sized article rule inline. Children mix raw
  # strings (escaped) and child nodes (recursed), same contract as PdText.
  defp heading(n, width, pal) do
    level = heading_level(Map.get(n, "level"))

    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    style = heading_style(level, pal) |> Enum.join(";")
    ~s(<h#{level} style="#{style}">#{inner}</h#{level}>)
  end

  # Clamp a heading level to 1..3; default to 2 when absent/out of range.
  defp heading_level(l) when l in [1, 2, 3], do: l
  defp heading_level("1"), do: 1
  defp heading_level("2"), do: 2
  defp heading_level("3"), do: 3
  defp heading_level(_), do: 2

  # ── article typographic roles ──────────────────────────────────────────────
  # Applied only when the compose clause stamped a hint AND the palette is the
  # article palette. The accumulator `out` is in REVERSE-build order (it gets
  # `Enum.reverse`d before joining), so we APPEND role declarations here — they
  # land at the FRONT of the final style string, ahead of weight/italic/deco.

  defp apply_text_role(out, inner, n, %{style: :article} = pal) do
    cond do
      Map.get(n, "_role") == "eyebrow" ->
        {[
           "font-family:#{pal.font_heading}",
           "color:#{pal.accent}",
           "letter-spacing:0.08em",
           "text-transform:uppercase",
           "font-weight:600",
           "font-size:0.78rem"
           | out
         ], inner}

      Map.get(n, "_role") == "byline" ->
        {[
           "border-bottom:1px solid #{pal.rule}",
           "padding-bottom:0.6rem",
           "margin:0 0 1.4rem",
           "color:#{pal.muted}",
           "font-family:#{pal.font_heading}",
           "font-size:0.9rem"
           | out
         ], inner}

      Map.get(n, "_role") == "ingress" ->
        {[
           "color:#{pal.text}",
           "line-height:1.5",
           "font-weight:500",
           "font-size:1.28rem"
           | out
         ], inner}

      Map.get(n, "_role") == "pullquote" ->
        # `display:block` so the left-border + margins read as a block quote
        # even though the node walks out as a `<span>`. `italic` is already on
        # the node (set by compose), so `font-style:italic` is in `out` here.
        {[
           "margin:1.6rem 0",
           "padding:0.2rem 0 0.2rem 1.2rem",
           "border-left:3px solid #{pal.accent}",
           "color:#{pal.muted}",
           "line-height:1.5",
           "font-size:1.2rem",
           "display:block"
           | out
         ], inner}

      true ->
        {out, inner}
    end
  end

  defp apply_text_role(out, inner, _n, _pal), do: {out, inner}

  # Heading declarations by clamped level (article palette).
  #
  # Three values align to the Edit pane's `.bp-paper-surface h1, h2, h3`
  # rules (root.html.heex ~:2067-2069) so View ↔ Edit stays byte-aligned:
  #   • font-family: serif (set in article_palette/0; was sans-serif system-ui)
  #   • font-weight: 600 across all levels (was 700/700/600)
  #   • margin: 0 — the user controls vertical rhythm via block-level
  #     spacing, not via heading-internal margin. Baking margin into the
  #     heading itself made the end result hard to author (the desk editor
  #     rule swallowed user-set gaps). Cross-surface implication: standalone
  #     /papers/<slug> and the email backend lose the heading shoulders too,
  #     which is what we want for a uniform block-driven look.
  defp heading_style(1, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "letter-spacing:-0.02em",
      "line-height:1.1",
      "margin:0",
      "font-weight:600",
      "font-size:32px"
    ]
  end

  defp heading_style(2, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.2",
      "margin:0",
      "font-weight:600",
      "font-size:24px"
    ]
  end

  defp heading_style(_3, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.25",
      "margin:0",
      "font-weight:600",
      "font-size:20px"
    ]
  end

  defp link(n, width, pal) do
    # Trap: PdLink.children mixes raw strings (escaped) and child nodes (recursed).
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    # Article links match the editor's designed at-rest treatment — no baseline
    # underline, a soft border-bottom instead (parity: root.html.heex:2334-2337,
    # `.bp-paper-surface a { text-decoration:none; border-bottom:1px solid
    # var(--paper-accent-soft) }`). The rgba fallback is the light-theme
    # --paper-accent-soft token (root.html.heex:2230/:2266) so the standalone
    # /papers reader paints the same tone when the CSS var doesn't resolve.
    # Email/default keeps the real underline — the correct convention there.
    deco =
      case pal do
        %{style: :article} ->
          "text-decoration:none;border-bottom:1px solid var(--paper-accent-soft, rgba(162,57,37,0.10))"

        _ ->
          "text-decoration:underline"
      end

    ~s(<a href="#{safe_url(Map.get(n, "href", ""))}" style="color:#{pal.link_color};#{deco}">#{inner}</a>)
  end

  # Internal-link kinds. A RESOLVED target (present in the palette's `:wikilinks`
  # map, stamped by the caller via Content.resolve_wikilink) renders a real
  # navigable <a href> — or, when the hit's `:kind` is "task", the live TASK
  # CHIP (lvw-t7, wire §4); an UNRESOLVED target degrades to the styled,
  # non-navigating dotted span (the Obsidian broken-link look) — byte-identical
  # to the pre-resolution render whenever the map is empty. The visible label
  # follows the ordered fallback alias → children → target (wire §4 amended —
  # a chip node ships `alias` + `children: []`, which previously rendered
  # empty). escape_html escapes quotes too, so it is attr-safe.
  defp wikilink(n, width, pal) do
    inner = wikilink_label(n, width, pal)
    raw = Map.get(n, "target", "")
    target = escape_html(raw)
    links = Map.get(pal, :wikilinks, %{})

    # Id-pin fast path: a wikilink picked from the autocomplete carries the
    # exact target `doc_id`. Branch by the palette's `{:id, id}`-keyed hit
    # FIRST (a picker-stamped TASK link must render the chip, never a dead
    # /papers/<task-id> 404); a paper (or palette-less) pin resolves straight
    # to /papers/<doc_id>, bypassing the title-keyed lookup — so a
    # duplicate-title pin lands on the picked paper, and it works even when the
    # palette has no entry for the title. A typed-not-picked wikilink has no
    # doc_id and falls through to the existing title resolution below
    # (byte-identical to before).
    case Map.get(n, "doc_id") do
      id when is_binary(id) and id != "" ->
        case Map.get(links, {:id, id}) do
          %{kind: "task"} = hit ->
            task_chip(hit, n, target, width, pal)

          _ ->
            href = escape_html("/papers/" <> id)

            ~s(<a href="#{href}" data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:none">#{inner}</a>)
        end

      _ ->
        case Map.get(links, raw) do
          %{kind: "task"} = hit ->
            task_chip(hit, n, target, width, pal)

          %{id: id} ->
            href = escape_html("/papers/" <> id)

            ~s(<a href="#{href}" data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:none">#{inner}</a>)

          _ ->
            ~s(<span data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:underline dotted">#{inner}</span>)
        end
    end
  end

  # The visible wikilink label: ordered fallback alias → children → target
  # (wire §4 amended). Every branch is escaped; children walk through the
  # normal renderer (marks and all).
  defp wikilink_label(n, width, pal) do
    case Map.get(n, "alias") do
      a when is_binary(a) and a != "" ->
        escape_html(a)

      _ ->
        inner =
          Map.get(n, "children", [])
          |> Enum.map(fn
            k when is_binary(k) -> escape_html(k)
            k -> walk(k, width, pal)
          end)
          |> Enum.join("")

        if inner != "", do: inner, else: escape_html(Map.get(n, "target", ""))
    end
  end

  # The live TASK CHIP (lvw-t7, wire §4): `[<glyph> <status> · P<priority> ·
  # <met>/<total>] <title>`. Segments degrade independently and GARBAGE-
  # TOLERANTLY: a missing status keeps only the neutral glyph, a missing
  # priority drops its segment (0 is a VALID priority — the HIGHEST), and
  # absent criteria OMIT the m/n segment entirely (never "0/0"). Non-navigable
  # by design: tasks have no public /papers/ URL — the resolved ids ride data-*
  # attrs for tooling. Everything dynamic is escaped; the chip NEVER raises and
  # NEVER blanks (a blank title falls back to the alias/children/target label).
  defp task_chip(hit, n, target, width, pal) do
    status = if is_binary(hit[:status]) and hit[:status] != "", do: hit[:status]

    status_seg =
      case status do
        nil -> task_glyph(nil)
        s -> task_glyph(s) <> " " <> escape_html(s)
      end

    prio_seg =
      case hit[:priority] do
        p when is_integer(p) and p >= 0 -> "P#{p}"
        _ -> nil
      end

    criteria_seg =
      case hit[:criteria] do
        %{met: met, total: total} when is_integer(met) and is_integer(total) and total > 0 ->
          "#{met}/#{total}"

        _ ->
          nil
      end

    chip_text = [status_seg, prio_seg, criteria_seg] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    label =
      case hit[:title] do
        t when is_binary(t) and t != "" -> escape_html(t)
        _ -> wikilink_label(n, width, pal)
      end

    ~s(<span data-taskchip="#{target}" data-task-id="#{escape_html(to_string(hit[:id] || ""))}"#{task_status_attr(status)} style="white-space:nowrap">) <>
      ~s(<span style="border:1px solid #{pal.link_color};border-radius:10px;padding:0 6px;color:#{pal.link_color};font-size:0.85em">#{chip_text}</span> ) <>
      label <> "</span>"
  end

  defp task_status_attr(nil), do: ""
  defp task_status_attr(s), do: ~s( data-task-status="#{escape_html(s)}")

  # Status glyphs — kept in LOCKSTEP with Go pdrender's taskStatusGlyph (the
  # terminal chip). Unknown/missing status gets the neutral pointer.
  defp task_glyph("open"), do: "○"
  defp task_glyph("in_progress"), do: "◐"
  defp task_glyph("blocked"), do: "⊘"
  defp task_glyph("done"), do: "●"
  defp task_glyph("cancelled"), do: "✕"
  defp task_glyph(_), do: "▸"

  # Inline live value (lvw-t1/lvw-t2, wire §3/§6/§8). A RESOLVED (target,
  # field) pair — present in the palette's `:values` map (`%{{target, field}
  # => string}`, stamped by the caller via `Papers.resolve_values_in_blocks/3`,
  # the pre-resolve pass) — renders the CURRENT canonical value; anything else
  # (missing map, unresolved pair, malformed node) renders the pinned
  # `fallback` literal. Everything dynamic goes through escape_html (the
  # PdText escape path — never `_raw`), so a hostile canonical value renders
  # inert.
  #
  # `data-valueref-state` is the lvw-t2 marker, THREE states / two stale
  # treatments (wire §6c/§8 — drift is the ONE comparison, fallback vs
  # resolved, made right here where the pre-resolve pass injects its result;
  # there is NO standalone checker):
  #
  #   * `resolved` — pair resolved and the pinned `fallback` matches (or no
  #     fallback is pinned — with no baseline there is nothing to drift).
  #   * `drift`    — pair resolved but the pinned `fallback` literal no longer
  #     matches the canonical value (shows the RESOLVED value; the baseline is
  #     stale). Studio may additionally carry the accept-baseline control —
  #     see below.
  #   * `dangling` — pair did NOT resolve (target deleted / never-published /
  #     out of scope / field redacted): drift is UNCOMPUTABLE; shows the
  #     pinned `fallback`. Distinct from drift by contract (two treatments).
  #
  # The states ride a data attribute only — the public reader ships no CSS or
  # control for them, so it stays plain text; Studio styles/act on them.
  # NEVER raises, NEVER blanks by design: unresolved shows the D6-pinned
  # fallback; the node's children (the D6 dual-written fallback subtree for
  # OLD renderers) are IGNORED here — compose already dropped them.
  defp valueref(n, pal) do
    target = Map.get(n, "target", "")
    field = Map.get(n, "field", "")
    fallback = valueref_fallback(n)

    {state, text} =
      case Map.get(Map.get(pal, :values, %{}), {target, field}) do
        v when is_binary(v) and (v == fallback or fallback == "") -> {"resolved", v}
        v when is_binary(v) -> {"drift", v}
        _ -> {"dangling", fallback}
      end

    ~s(<span data-valueref="#{escape_html(target)}" data-field="#{escape_html(field)}" data-valueref-state="#{state}">#{escape_html(text)}</span>) <>
      valueref_accept_control(state, target, field, fallback, pal)
  end

  # ACCEPT-BASELINE affordance (lvw-t2, D4 ratified): on a DRIFTED valueref —
  # and ONLY when the palette opts in via `:valueref_accept` (Studio's own
  # per-request paper view sets it; the body_html cache, delta frames, and the
  # public reader never do, so the control cannot leak into shared caches or
  # anonymous HTML) — emit a button wired to the Studio LiveView's
  # "valueref-accept-baseline" event. It carries the node's identity (target/
  # field) plus the CURRENT pinned fallback, so the server can re-check drift
  # and rewrite exactly the matching pinned literals (an ifRev-guarded,
  # fallback-only patch — never edit-through to the canonical target; that is
  # lvw-t10). Dangling never gets the control: drift is uncomputable there.
  defp valueref_accept_control("drift", target, field, fallback, pal) do
    if Map.get(pal, :valueref_accept, false) do
      ~s(<button type="button" class="bp-valueref-accept" phx-click="valueref-accept-baseline" phx-value-target="#{escape_html(target)}" phx-value-field="#{escape_html(field)}" phx-value-fallback="#{escape_html(fallback)}" title="Accept new baseline: update the pinned literal to the current value">accept</button>)
    else
      ""
    end
  end

  defp valueref_accept_control(_state, _target, _field, _fallback, _pal), do: ""

  defp valueref_fallback(n) do
    case Map.get(n, "fallback") do
      f when is_binary(f) -> f
      f when is_number(f) -> to_string(f)
      _ -> ""
    end
  end

  # Note-embed transclusion (![[note]]). A RESOLVED target — present in the
  # palette's `:embeds` map (%{raw_target => prerendered_html_string}, stamped
  # by the caller via Papers.resolve_embeds_in_blocks) — injects that HTML inside
  # a transclusion <section>. The injected string is ALREADY renderer output
  # (safe HTML), so it is emitted VERBATIM — only the `data-embed` attr value is
  # escaped. An UNRESOLVED target (absent from the map, or blank) degrades to a
  # broken-embed fallback that links to the would-be paper, mirroring wikilink/3's
  # dotted-span treatment. escape_html escapes quotes too, so it is attr-safe.
  # PURE: walk only injects the pre-rendered string — no Repo, no recursive Render.
  defp embed(n, pal) do
    raw = Map.get(n, "target", "")
    target = escape_html(raw)

    case Map.get(Map.get(pal, :embeds, %{}), raw) do
      html when is_binary(html) ->
        # Transclusion frame — INLINE-styled (this renderer targets email / web /
        # Studio alike and can't rely on an external `.paper-embed` stylesheet). A
        # left accent rule sets the embedded note apart from the host prose; the
        # class stays as a styling/JS hook.
        ~s(<section class="paper-embed" data-embed="#{target}" style="margin:1em 0;padding:0.25em 0 0.25em 1em;border-left:3px solid #{pal.link_color}">#{html}</section>)

      _ ->
        # Unresolved embed: a NON-navigating placeholder (mirrors wikilink/3's
        # broken-link span). NO <a> — a raw human title is not a slug, so a link
        # would 404; show the broken reference, muted + framed, instead.
        ~s(<section class="paper-embed paper-embed--unresolved" data-embed="#{target}" style="margin:1em 0;padding:0.5em 0.75em;border-left:3px solid #{pal.code_bg};color:#{pal.muted};font-style:italic">↪ #{target}</section>)
    end
  end

  defp blockref(n, pal) do
    raw = Map.get(n, "target", "")
    raw_anchor = Map.get(n, "anchor", "")
    target = escape_html(raw)
    anchor = escape_html(raw_anchor)

    case Map.get(Map.get(pal, :wikilinks, %{}), raw) do
      %{id: id} ->
        href = escape_html("/papers/" <> id <> "#" <> raw_anchor)

        ~s(<a href="#{href}" data-blockref="#{target}" data-anchor="#{anchor}" style="color:#6b7280;font-size:0.9em;text-decoration:none">^#{anchor}</a>)

      _ ->
        ~s(<span data-blockref="#{target}" data-anchor="#{anchor}" style="color:#6b7280;font-size:0.9em">^#{anchor}</span>)
    end
  end

  defp tag_node(n, pal) do
    raw = Map.get(n, "name", "")
    name = escape_html(raw)
    # Navigable tag (Obsidian-parity): link to the web reader's /tags/<name>
    # page, mirroring how wikilink/3 emits /papers/<id>. COMPONENT-encode the
    # RAW name into the single `[tag]` path segment — `URI.char_unreserved?/1`
    # percent-encodes the URL-reserved chars (/ ? # &) that bare `URI.encode/1`
    # would leave intact, so a NESTED Obsidian tag (#project/active) stays one
    # segment (/tags/project%2Factive) the route's decodeURIComponent reverses,
    # instead of splitting into two segments and 404-ing. Percent-encoding also
    # doubles as attribute-safety; the escaped name fills the data-tag attr +
    # visible chip text.
    href = escape_html("/tags/" <> URI.encode(raw, &URI.char_unreserved?/1))

    ~s(<a href="#{href}" data-tag="#{name}" style="color:#{pal.link_color};background:#{pal.code_bg};padding:1px 6px;border-radius:3px;font-size:0.9em;text-decoration:none">##{name}</a>)
  end

  defp button(n, pal) do
    label = escape_html(Map.get(n, "label", ""))
    href = safe_url(Map.get(n, "href", ""))

    if Map.get(n, "priority") == "primary" do
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;background:#{pal.accent};color:#{@brand_text};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    else
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;border:2px solid #{pal.accent};color:#{pal.accent};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    end
  end

  defp hr(n, pal) do
    t = Map.get(n, "thickness") || 1

    ~s(<hr style="border:none;border-top:#{escape_attr(to_string(t))}px solid #{pal.rule};margin:16px 0">)
  end

  defp image(n) do
    dims =
      case Map.get(n, "width") do
        nil -> ""
        w -> ~s( width="#{escape_attr(to_string(w))}")
      end <>
        case Map.get(n, "height") do
          nil -> ""
          h -> ~s( height="#{escape_attr(to_string(h))}")
        end

    ~s(<img src="#{safe_url(Map.get(n, "src", ""))}" alt="#{escape_attr(Map.get(n, "alt", ""))}" style="max-width:100%;height:auto"#{dims}>)
  end

  # Article mode styles the header row distinctly: the first row becomes a
  # `<thead>`/`<th>` band — uppercase, muted, with a 2px bottom rule under the
  # header — and the warm rule colour (`pal.rule` = #e6e2d8) replaces gray on
  # the body cells. Email/default mode keeps the flat `<td>`-only table,
  # byte-identical to before.
  defp table(n, width, %{style: :article} = pal) do
    # The header row is OPT-IN via an explicit `head` field on the PdTable.
    # Earlier behaviour silently promoted `rows[0]` to a <thead>, which broke
    # any data table that didn't carry a header (every body row shifted up by
    # one, and 1-row tables lost their only row to the header band). Upstream
    # converters that don't distinguish `<th>` from `<td>` (e.g. the
    # paper_to_blocks.py table walker) now get a header-less table
    # rendered the way they meant it; producers that DO want a header band
    # set `head` explicitly.
    head = Map.get(n, "head", []) |> List.wrap()
    body = Map.get(n, "rows", []) |> List.wrap()

    thead =
      if head == [] do
        ""
      else
        cells =
          head
          |> Enum.map(fn cell ->
            inner = render_children(cell, width, pal)

            ~s(<th style="border-bottom:2px solid #{pal.rule};padding:8px 12px;text-align:left;) <>
              ~s(text-transform:uppercase;letter-spacing:0.04em;font-size:0.78rem;color:#{pal.muted};) <>
              ~s(font-family:#{pal.font_heading}">#{inner}</th>)
          end)
          |> Enum.join("")

        "<thead><tr>#{cells}</tr></thead>"
      end

    tbody =
      body
      |> Enum.map(fn row ->
        cells =
          row
          |> Enum.map(fn cell ->
            inner = render_children(cell, width, pal)

            ~s(<td style="border-bottom:1px solid #{pal.rule};padding:8px 12px;vertical-align:top">#{inner}</td>)
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%">) <>
      thead <> "<tbody>#{tbody}</tbody></table>"
  end

  defp table(n, width, pal) do
    rows =
      Map.get(n, "rows", [])
      |> Enum.map(fn row ->
        cells =
          row
          |> Enum.map(fn cell ->
            inner = render_children(cell, width, pal)

            ~s(<td style="border:1px solid #{pal.rule};padding:8px 12px;vertical-align:top">#{inner}</td>)
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%">#{rows}</table>)
  end

  # PdSheet — dense spreadsheet value grid; the same node shape the TUI's
  # pdrender already consumes (head/rows/col_widths, all-plain-string cells).
  # The HTML mirrors the `table` clause, plus an optional `<thead>` band when
  # `head` is present, per-column inline `width:Npx` hints from `col_widths`,
  # `colspan`/`rowspan` from `merges` (covered cells emit no `<td>`), and
  # per-cell inline styles from `styles` (bold/italic/background/text-align)
  # — so the grid renders without any external CSS. The TUI ignores
  # merges/styles and shows the merged value at its anchor cell.
  defp sheet(n, _width, %{style: :article} = pal) do
    head = Map.get(n, "head", []) |> List.wrap()
    body = Map.get(n, "rows", []) |> List.wrap()
    col_widths = Map.get(n, "col_widths")
    {anchors, covered} = sheet_merge_lookup(n)
    styles = Map.get(n, "styles")

    thead =
      if head == [] do
        ""
      else
        cells =
          head
          |> Enum.with_index()
          |> Enum.map(fn {cell, idx} ->
            w_style = col_width_style(col_widths, idx)

            ~s(<th style="#{w_style}border-bottom:2px solid #{pal.rule};padding:6px 10px;text-align:left;) <>
              ~s(text-transform:uppercase;letter-spacing:0.04em;font-size:0.78rem;color:#{pal.muted};) <>
              ~s(font-family:#{pal.font_heading}">#{escape_html(cell)}</th>)
          end)
          |> Enum.join("")

        "<thead><tr>#{cells}</tr></thead>"
      end

    tbody =
      body
      |> Enum.with_index()
      |> Enum.map(fn {row, r} ->
        cells =
          row
          |> Enum.with_index()
          |> Enum.flat_map(fn {cell, c} ->
            if MapSet.member?(covered, {r, c}) do
              []
            else
              w_style = col_width_style(col_widths, c)
              span = sheet_span_attr(anchors, r, c)
              al = sheet_default_align_attr(styles, r, c, cell)
              extra = sheet_cell_style(styles, r, c)
              err = sheet_err_style(cell)

              [
                ~s(<td#{span}#{al} style="#{w_style}border-bottom:1px solid #{pal.rule};padding:6px 10px;vertical-align:top;font-family:#{@font_mono};font-size:0.88rem#{extra}#{err}">#{sheet_cell_html(cell)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    table =
      ~s(<table role="presentation" style="border-collapse:collapse;width:100%">) <>
        thead <> "<tbody>#{tbody}</tbody></table>"

    table <> sheet_truncation_note(n, length(body), pal.muted)
  end

  defp sheet(n, _width, pal) do
    head = Map.get(n, "head", []) |> List.wrap()
    body = Map.get(n, "rows", []) |> List.wrap()
    col_widths = Map.get(n, "col_widths")
    {anchors, covered} = sheet_merge_lookup(n)
    styles = Map.get(n, "styles")

    thead_row =
      if head == [] do
        ""
      else
        cells =
          head
          |> Enum.with_index()
          |> Enum.map(fn {cell, idx} ->
            w_style = col_width_style(col_widths, idx)

            ~s(<th style="#{w_style}border-bottom:2px solid #{pal.rule};padding:6px 10px;text-align:left;font-weight:bold">#{escape_html(cell)}</th>)
          end)
          |> Enum.join("")

        "<thead><tr>#{cells}</tr></thead>"
      end

    rows =
      body
      |> Enum.with_index()
      |> Enum.map(fn {row, r} ->
        cells =
          row
          |> Enum.with_index()
          |> Enum.flat_map(fn {cell, c} ->
            if MapSet.member?(covered, {r, c}) do
              []
            else
              w_style = col_width_style(col_widths, c)
              span = sheet_span_attr(anchors, r, c)
              al = sheet_default_align_attr(styles, r, c, cell)
              extra = sheet_cell_style(styles, r, c)
              err = sheet_err_style(cell)

              [
                ~s(<td#{span}#{al} style="#{w_style}border:1px solid #{pal.rule};padding:6px 10px;vertical-align:top#{extra}#{err}">#{sheet_cell_html(cell)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    table =
      ~s(<table role="presentation" style="border-collapse:collapse;width:100%">#{thead_row}<tbody>#{rows}</tbody></table>)

    table <> sheet_truncation_note(n, length(body), pal.muted)
  end

  # When the snapshot was clipped at the position cap (`"truncated" => true`),
  # append a muted note so a paper never shows silent partial data. `shown` is
  # the number of body rows actually rendered.
  defp sheet_truncation_note(n, shown, muted) do
    if Map.get(n, "truncated") do
      ~s(<p style="margin:6px 0 0;font-size:0.8rem;color:#{muted}">) <>
        escape_html("Sheet truncated — showing the first #{shown} rows") <> "</p>"
    else
      ""
    end
  end

  # `merges` ([[row, col, rowspan, colspan], …], 0-based body grid) →
  # `{anchors, covered}`: anchor position → {rowspan, colspan}, plus the set
  # of positions a merged range covers (anchor excluded — those cells emit
  # no <td>). Malformed entries are ignored; with overlapping ranges the
  # first listed wins (a covered anchor is simply skipped at emission time).
  defp sheet_merge_lookup(n) do
    n
    |> Map.get("merges")
    |> List.wrap()
    |> Enum.reduce({%{}, MapSet.new()}, fn
      [r, c, rs, cs], {anchors, covered}
      when is_integer(r) and is_integer(c) and is_integer(rs) and is_integer(cs) and
             r >= 0 and c >= 0 and rs >= 1 and cs >= 1 and rs * cs <= @merge_area_cap ->
        covered =
          for(rr <- r..(r + rs - 1), cc <- c..(c + cs - 1), {rr, cc} != {r, c}, do: {rr, cc})
          |> Enum.into(covered)

        {Map.put(anchors, {r, c}, {rs, cs}), covered}

      _other, acc ->
        acc
    end)
  end

  defp sheet_span_attr(anchors, r, c) do
    case Map.fetch(anchors, {r, c}) do
      {:ok, {rs, cs}} ->
        if(cs > 1, do: ~s( colspan="#{cs}"), else: "") <>
          if(rs > 1, do: ~s( rowspan="#{rs}"), else: "")

      :error ->
        ""
    end
  end

  # The sanitized per-cell style fragment — `""` or `";prop:val;…"` (it
  # appends to a base style that carries no trailing semicolon, so the
  # no-style output stays byte-identical to before M5). Defensive even
  # though the snapshot side already sanitizes: only a strict #rrggbb hex
  # may reach `background` (it sits inside the inline style attribute),
  # only the three known alignment words reach `text-align`.
  defp sheet_cell_style(styles, r, c) when is_map(styles) do
    case Map.get(styles, "#{r},#{c}") do
      %{} = s ->
        [
          if(Map.get(s, "b") == true, do: "font-weight:bold;", else: ""),
          if(Map.get(s, "i") == true, do: "font-style:italic;", else: ""),
          sheet_bg_style(Map.get(s, "bg")),
          sheet_align_style(Map.get(s, "al"))
        ]
        |> Enum.join("")
        |> case do
          "" -> ""
          fragment -> ";" <> fragment
        end

      _ ->
        ""
    end
  end

  defp sheet_cell_style(_styles, _r, _c), do: ""

  # Error marking — a cell whose plain value is an engine error code
  # (`#DIV/0!`, `#NUM!`, …) renders red + bold. Emitted AFTER `sheet_cell_style`
  # in the inline attribute so its colour/weight win over any cell styling.
  defp sheet_err_style(cell) when is_binary(cell) do
    if cell in @error_values, do: ";color:#dc2626;font-weight:bold", else: ""
  end

  defp sheet_err_style(_cell), do: ""

  # A cell body: an http(s)-URL value (whole-string match on `@sheet_url_re`)
  # renders a clickable anchor through the scheme allowlist (`safe_url/1`) with
  # escaped link text; every other value stays plain escaped text. A `javascript:`
  # / `data:` payload never matches the regex (and `safe_url` would blank it
  # anyway), and "see http://x" stays text. Head `<th>` cells keep `escape_html`.
  defp sheet_cell_html(cell) when is_binary(cell) do
    if Regex.match?(@sheet_url_re, cell) do
      ~s(<a href="#{safe_url(cell)}" target="_blank" rel="noopener noreferrer nofollow" style="color:#2563eb;text-decoration:underline">#{escape_html(cell)}</a>)
    else
      escape_html(cell)
    end
  end

  defp sheet_cell_html(cell), do: escape_html(cell)

  defp sheet_bg_style(bg) when is_binary(bg) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, bg), do: "background:#{bg};", else: ""
  end

  defp sheet_bg_style(_), do: ""

  defp sheet_align_style(al) when al in ["left", "center", "right"], do: "text-align:#{al};"
  defp sheet_align_style(_), do: ""

  # The default-alignment CLASS attribute for a body <td> — `""` or
  # ` class="sheet-al-right"` / ` class="sheet-al-center"`. A class, NOT an
  # inline style, on purpose (the exact mechanism the Studio grid uses): the
  # sheets-parity suite pins the INLINE b/i/bg/al styles identical across
  # surfaces, so the derived default must never reach the style attribute.
  # The hosting layouts (bulldocs.html.heex for /papers, root.html.heex for
  # the Studio paper view) carry the two `td.sheet-al-*` rules; surfaces with
  # no stylesheet at all (email, the standalone html export) degrade to the
  # table's left — values-first, never wrong, and the class stays as a hook.
  #
  # Rule mirror of `Cells.default_align_class/1`, clause order preserved:
  # explicit s.al suppresses the class (and would win anyway — it's inline);
  # TRUE/FALSE center (bare booleans AND checkbox cells both snapshot to
  # those exact strings); number-shaped display strings right; text nothing.
  # Two stringly edges are inherent to the dense snapshot (display strings
  # only, no v/fmt): a TEXT cell whose value looks numeric ("42") right-aligns
  # here but not in Studio, and a number fmt on a non-numeric value keeps
  # Studio's right-align but not here. Neither touches the parity styles axis.
  defp sheet_default_align_attr(styles, r, c, cell) do
    if sheet_explicit_al?(styles, r, c) do
      ""
    else
      case sheet_default_align_class(cell) do
        nil -> ""
        class -> ~s( class="#{class}")
      end
    end
  end

  defp sheet_explicit_al?(styles, r, c) when is_map(styles) do
    case Map.get(styles, "#{r},#{c}") do
      %{"al" => al} when al in ["left", "center", "right"] -> true
      _ -> false
    end
  end

  defp sheet_explicit_al?(_styles, _r, _c), do: false

  defp sheet_default_align_class(cell) when cell in ["TRUE", "FALSE"], do: "sheet-al-center"

  defp sheet_default_align_class(cell) when is_binary(cell) do
    if Regex.match?(@sheet_numeric_display_re, cell) or
         Regex.match?(@sheet_temporal_display_re, cell) do
      "sheet-al-right"
    else
      nil
    end
  end

  defp sheet_default_align_class(_cell), do: nil

  # Emit an inline `width:Npx;` style fragment for the col at `idx` (0-based).
  # Returns `""` when no col_widths list is present or the entry is 0.
  defp col_width_style(nil, _idx), do: ""

  defp col_width_style(col_widths, idx) when is_list(col_widths) do
    case Enum.at(col_widths, idx) do
      w when is_integer(w) and w > 0 -> "width:#{w}px;"
      _ -> ""
    end
  end

  defp col_width_style(_, _), do: ""

  defp callout(n, width, pal) do
    tone = tone_palette(Map.get(n, "tone"))
    inner = render_children(Map.get(n, "children", []), width, pal)

    # `collapsible` is only ever present in ARTICLE mode (compose.ex gates it),
    # so email/non-collapsible callouts take the byte-identical legacy <div>.
    if Map.get(n, "collapsible") == true do
      collapsible_callout(n, tone, inner)
    else
      title_html =
        case Map.get(n, "title") do
          nil -> ""
          "" -> ""
          title -> "<strong>#{escape_html(title)}</strong> "
        end

      ~s(<div style="border-left:4px solid #{tone.fg};background:#{tone.bg};padding:16px;color:#{tone.fg}">#{title_html}#{inner}</div>)
    end
  end

  # Zero-JS native fold via <details>/<summary>. `open` reflects !collapsed; the
  # summary is the title, or a tone label so it is never empty.
  defp collapsible_callout(n, tone, inner) do
    open = if Map.get(n, "collapsed") == true, do: "", else: " open"
    summary = escape_html(callout_summary(n))

    ~s(<details#{open} style="border-left:4px solid #{tone.fg};background:#{tone.bg};padding:16px;color:#{tone.fg}">) <>
      ~s(<summary style="cursor:pointer;font-weight:bold">#{summary}</summary>) <>
      ~s(<div style="margin-top:8px">#{inner}</div></details>)
  end

  defp callout_summary(n) do
    case Map.get(n, "title") do
      nil -> tone_label(Map.get(n, "tone"))
      "" -> tone_label(Map.get(n, "tone"))
      title -> title
    end
  end

  defp tone_label("success"), do: "Success"
  defp tone_label("warning"), do: "Warning"
  defp tone_label("danger"), do: "Danger"
  defp tone_label("neutral"), do: "Neutral"
  defp tone_label(_), do: "Info"

  # Semantic `<ul>` / `<ol>` for article mode. Email mode never reaches these
  # renderers — its list compose clause still emits the flex-row PdBox scaffold
  # with literal "• " / "1. " prefix spans (byte-stable Outlook target).
  #
  # The spacing values align to the Edit pane's list rules so View ↔ Edit stays
  # byte-aligned (same precedent as heading_style/2 above):
  #   • `.bp-paper-surface ul, ol { margin: 0 0 24px; padding-left: 24px; }`
  #     (root.html.heex ~:2338) and `.bp-paper-editor-body` ul/ol (~:2880-2882)
  #   • `.bp-paper-surface li { margin: 4pt 0 0; }` (~:2339) and the editor-body
  #     li rule (~:2880-2882)
  #   • line-height 1.7 — the surface inherits 1.70 (~:2288)
  # font-family/color stay inline: the standalone /papers reader needs them.
  defp list(n, width, pal) do
    tag = if Map.get(n, "ordered"), do: "ol", else: "ul"
    inner = render_children(Map.get(n, "children", []), width, pal)

    ~s(<#{tag} style="margin:0 0 24px;padding-left:24px;font-family:#{pal.font_body};color:#{pal.text};line-height:1.7">) <>
      inner <> "</#{tag}>"
  end

  defp list_item(n, width, pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)
    ~s(<li style="margin:4pt 0 0">) <> inner <> "</li>"
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp render_children(children, width, pal) do
    children
    |> Enum.map(&walk(&1, width, pal))
    |> Enum.join("")
  end
end
