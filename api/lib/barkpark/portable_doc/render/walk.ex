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

  def walk(%{"kind" => "PdInlineCode"} = n, _width, pal) do
    ~s(<code style="background:#{pal.code_bg};padding:2px 6px;font-family:#{@font_mono};font-size:0.95em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  def walk(%{"kind" => "PdWikilink"} = n, width, pal), do: wikilink(n, width, pal)
  def walk(%{"kind" => "PdBlockref"} = n, _width, pal), do: blockref(n, pal)
  def walk(%{"kind" => "PdTag"} = n, _width, pal), do: tag_node(n, pal)

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

  def walk(%{"kind" => kind}, _width, _pal) do
    raise ArgumentError, "render_html: unhandled #{kind}"
  end

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
    |> maybe_push(s, "width", fn v -> "width:#{v}px" end)
    |> maybe_push(s, "height", fn v -> "height:#{v}px" end)
    |> maybe_push(s, "padding", fn v -> "padding:#{v}px" end)
    |> maybe_push(s, "margin", fn v -> "margin:#{v}px" end)
    |> maybe_border(s)
    |> maybe_push(s, "backgroundColor", fn v -> "background-color:#{v}" end)
    |> maybe_push(s, "verticalAlign", fn v -> "vertical-align:#{v}" end)
    |> Enum.reverse()
    |> Enum.join(";")
  end

  defp maybe_flex(out, s) do
    case Map.get(s, "flexDirection") do
      nil -> out
      dir -> ["flex-direction:#{dir}", "display:flex" | out]
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
      ["border:#{bw}px #{css_border_style(bs)} #{bc}" | out]
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

    ~s(<a href="#{safe_url(Map.get(n, "href", ""))}" style="color:#{pal.link_color};text-decoration:underline">#{inner}</a>)
  end

  # Internal-link kinds. A RESOLVED target (present in the palette's `:wikilinks`
  # map, stamped by the caller via Content.resolve_wikilink) renders a real
  # navigable <a href>; an UNRESOLVED target degrades to the styled,
  # non-navigating dotted span (the Obsidian broken-link look) — byte-identical
  # to the pre-resolution render whenever the map is empty. escape_html escapes
  # quotes too, so it is attr-safe.
  defp wikilink(n, width, pal) do
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    raw = Map.get(n, "target", "")
    target = escape_html(raw)

    case Map.get(Map.get(pal, :wikilinks, %{}), raw) do
      %{id: id} ->
        href = escape_html("/papers/" <> id)

        ~s(<a href="#{href}" data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:none">#{inner}</a>)

      _ ->
        ~s(<span data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:underline dotted">#{inner}</span>)
    end
  end

  defp blockref(n, _pal) do
    target = escape_html(Map.get(n, "target", ""))
    anchor = escape_html(Map.get(n, "anchor", ""))
    ~s(<span data-blockref="#{target}" data-anchor="#{anchor}" style="color:#6b7280;font-size:0.9em">^#{anchor}</span>)
  end

  defp tag_node(n, pal) do
    name = escape_html(Map.get(n, "name", ""))

    ~s(<span data-tag="#{name}" style="color:#{pal.link_color};background:#{pal.code_bg};padding:1px 6px;border-radius:3px;font-size:0.9em">##{name}</span>)
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
    ~s(<hr style="border:none;border-top:#{t}px solid #{pal.rule};margin:16px 0">)
  end

  defp image(n) do
    dims =
      case Map.get(n, "width") do
        nil -> ""
        w -> ~s( width="#{w}")
      end <>
        case Map.get(n, "height") do
          nil -> ""
          h -> ~s( height="#{h}")
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
              extra = sheet_cell_style(styles, r, c)

              [
                ~s(<td#{span} style="#{w_style}border-bottom:1px solid #{pal.rule};padding:6px 10px;vertical-align:top;font-family:#{@font_mono};font-size:0.88rem#{extra}">#{escape_html(cell)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%">) <>
      thead <> "<tbody>#{tbody}</tbody></table>"
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
              extra = sheet_cell_style(styles, r, c)

              [
                ~s(<td#{span} style="#{w_style}border:1px solid #{pal.rule};padding:6px 10px;vertical-align:top#{extra}">#{escape_html(cell)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%">#{thead_row}<tbody>#{rows}</tbody></table>)
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
             r >= 0 and c >= 0 and rs >= 1 and cs >= 1 ->
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

  defp sheet_bg_style(bg) when is_binary(bg) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, bg), do: "background:#{bg};", else: ""
  end

  defp sheet_bg_style(_), do: ""

  defp sheet_align_style(al) when al in ["left", "center", "right"], do: "text-align:#{al};"
  defp sheet_align_style(_), do: ""

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
  defp list(n, width, pal) do
    tag = if Map.get(n, "ordered"), do: "ol", else: "ul"
    inner = render_children(Map.get(n, "children", []), width, pal)

    ~s(<#{tag} style="margin:1rem 0;padding-left:1.6rem;font-family:#{pal.font_body};color:#{pal.text};line-height:1.6">) <>
      inner <> "</#{tag}>"
  end

  defp list_item(n, width, pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)
    ~s(<li style="margin:0.2rem 0">) <> inner <> "</li>"
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp render_children(children, width, pal) do
    children
    |> Enum.map(&walk(&1, width, pal))
    |> Enum.join("")
  end
end
