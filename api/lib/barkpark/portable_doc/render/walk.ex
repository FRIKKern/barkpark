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
  constant.

  ## Theme-vs-data contract (Stage 2 — identical by construction)

  In `:article` mode the prose core emits **bare semantic elements** — `<h1>`
  `<h2>` `<h3>`, `<p>`, `<ul>`/`<ol>`/`<li>`, `<a>`, `<code>`, and the container
  `<div>` — carrying NO structural `style=`. Their typography, spacing, ink, and
  chrome are owned by the ONE canonical `.bp-paper-surface` element stylesheet
  (`Barkpark.PortableDoc.Render.Stylesheet`, single-sourced from the `--bp-*` /
  `--paper-*` tokens). View and Edit therefore resolve the SAME selectors in the
  SAME cascade — parity is a property of the DOM, not hand-matched CSS.

  The crisp line between what stays inline and what moves to the stylesheet:

    * **DATA (stays inline — it is content, must survive a stylesheet-less sink
      like email or a standalone export):** author PdText marks (user-set color,
      weight, italic, underline/strike decoration), PdBox geometry, PdSheet
      `col_widths` + per-cell `b`/`i`/`bg`/`al` + engine-error red/bold mark,
      PdImage width/height, PdHr thickness (article emits `border-top-width`),
      PdContainer `maxWidth`.
    * **THEME (moves to `Render.Stylesheet` — it is presentation, resolved from
      tokens):** heading typography, paragraph/list margins + indent, list
      line-height, link at-rest decoration + border, inline-code chip
      (font/size/bg/padding/radius), container ink/bg/font-family, the text
      ROLES (`bp-role-{eyebrow,byline,ingress,pullquote}`), callout TONES
      (`bp-callout` + `bp-callout--<tone>`, light + dark tokens), and every
      component CHROME frame — table/sheet band + cell rules, sheet URL-anchor,
      wikilink/tag/task-chip/embed/blockref/button/hr — each an article-gated
      `bp-*` class whose rule lives in `.bp-paper-surface`.

  `:email` (the default palette) is **frozen** — every `:email` clause emits the
  exact bytes it always has (Outlook strips stylesheets; inline is the only
  correct emission there), locked by the byte-identical assertions in the tests.
  A permanent ratchet tripwire (Wave-1 rails slice) asserts article output
  carries no `style=` outside the DATA allowlist above.
  """

  import Barkpark.PortableDoc.Render.Util,
    only: [escape_html: 1, escape_attr: 1, safe_url: 1, tone_palette: 1]

  alias Barkpark.PortableDoc.Render.StatusVocab

  # Mono font is theme-INVARIANT (charter D28) — stays a compile-time constant.
  @font_mono Barkpark.PortableDoc.Render.Palettes.font_mono()

  # Max cells a single sheet merge may cover before this public render path
  # drops it. Papers never pass the sheet plugin's before_save merge
  # sanitizer, so an author-crafted embed can carry an oversized merge here.
  # Mirrors the canonical `Barkpark.Plugins.Sheets.merge_area_cap/0` value; a
  # local attr keeps portable_doc decoupled from the plugin namespace.
  @merge_area_cap 10_000

  # Engine error vocabulary, mirrored LOCALLY so CORE render carries NO
  # compile-time edge into the Sheets PLUGIN namespace — same reason (and same
  # shape) as `@merge_area_cap` right above: PortableDoc render must compile with
  # the sheet plugin absent (fresh-install invariant), and a compile-time
  # `Barkpark.Plugins.Sheets.Engine.error_values()` here would both break that
  # and force a walk recompile on every engine touch. The canonical owner stays
  # `Barkpark.Plugins.Sheets.Engine.error_values/0` (@canonical
  # engine-error-vocabulary); a drift-guard test (sheets_parity_test) asserts
  # THIS mirror EQUALS that list, so the two are a CHECKED invariant, not a
  # silent fork. A cell whose plain string is in this set renders red/bold in
  # BOTH palettes.
  @error_values ~w(#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM! #SPILL! #NAME?)

  # @doc false accessor — exists ONLY so the drift-guard test can assert this
  # local mirror equals `Barkpark.Plugins.Sheets.Engine.error_values/0`.
  @doc false
  def error_vocab, do: @error_values

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

  # Article inline code is a BARE `<code>` — the `.bp-paper-surface code`
  # element rule (font/size/bg/padding/radius, single-sourced from the `--bp-*`
  # code tokens) owns the rounded chip in both View and Edit by construction.
  # See the theme-vs-data contract in the moduledoc. Palette-gated so the
  # generic clause below keeps email output byte-identical (Outlook needs inline).
  def walk(%{"kind" => "PdInlineCode"} = n, _width, %{style: :article}) do
    "<code>" <> escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  def walk(%{"kind" => "PdInlineCode"} = n, _width, pal) do
    ~s(<code style="background:#{pal.code_bg};padding:1px 5px;border-radius:4px;font-family:#{@font_mono};font-size:0.88em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  def walk(%{"kind" => "PdWikilink"} = n, width, pal), do: wikilink(n, width, pal)
  def walk(%{"kind" => "PdEmbed"} = n, _width, pal), do: embed(n, pal)
  def walk(%{"kind" => "PdBlockref"} = n, _width, pal), do: blockref(n, pal)
  def walk(%{"kind" => "PdTag"} = n, _width, pal), do: tag_node(n, pal)
  def walk(%{"kind" => "PdChip"} = n, _width, pal), do: chip(n, pal)
  def walk(%{"kind" => "PdValueref"} = n, _width, pal), do: valueref(n, pal)

  def walk(%{"kind" => "PdButton"} = n, _width, pal), do: button(n, pal)
  def walk(%{"kind" => "PdHr"} = n, _width, pal), do: hr(n, pal)

  def walk(%{"kind" => "PdImage"} = n, _width, %{style: :article}),
    do: image(n, ~s( data-bp-lightboxable="true"))

  def walk(%{"kind" => "PdImage"} = n, _width, _pal), do: image(n)
  def walk(%{"kind" => "PdTable"} = n, width, pal), do: table(n, width, pal)
  def walk(%{"kind" => "PdSheet"} = n, width, pal), do: sheet(n, width, pal)
  def walk(%{"kind" => "PdCallout"} = n, width, pal), do: callout(n, width, pal)
  def walk(%{"kind" => "PdList"} = n, width, pal), do: list(n, width, pal)
  def walk(%{"kind" => "PdListItem"} = n, width, pal), do: list_item(n, width, pal)
  def walk(%{"kind" => "PdBlockquote"} = n, width, pal), do: blockquote(n, width, pal)

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

  # Article container carries only GEOMETRY: `max-width` is author DATA (the
  # PdContainer's own maxWidth), `margin`/`padding` are the box's layout. Ink,
  # background, and font-family move to the `.bp-paper-surface` root (its
  # `--paper-*` tokens own them in both View and Edit) — see the moduledoc
  # theme-vs-data contract. `:email` keeps the self-styled div byte-for-byte.
  defp container(n, width, %{style: :article} = pal) do
    # Trap: clamp container width with min(maxWidth, width) — see the :email
    # clause below for the nullish (`n.maxWidth ?? width`) rationale.
    w = min(Map.get(n, "maxWidth", width), width)
    inner = render_children(Map.get(n, "children", []), w, pal)

    ~s(<div style="max-width:#{w}px;margin:0 auto;padding:24px">) <> inner <> "</div>"
  end

  defp container(n, width, pal) do
    # Trap: clamp container width with min(maxWidth, width).
    # Match TS `n.maxWidth ?? width` (nullish, not falsy) so a literal `0`
    # maxWidth is honored rather than silently replaced by the budget.
    w = min(Map.get(n, "maxWidth", width), width)
    inner = render_children(Map.get(n, "children", []), w, pal)

    ~s(<div style="max-width:#{w}px;margin:0 auto;padding:24px;font-family:#{pal.font_body};color:#{pal.text};background:#{pal.paper}">) <>
      inner <> "</div>"
  end

  # Section-frame hook (charter D19): the ONLY classes a PdBox may emit. The
  # whitelist is MANDATORY, not defensive decoration — walk renders raw
  # external Pd JSON, so an open `"class"` pass-through would let any document
  # claim arbitrary paper-surface classes (class injection). Compose stamps
  # these as FIXED literals (compose_section_stack); anything else stays inert.
  @box_class_whitelist ~w(bp-section--framed bp-section--wide)

  defp box(n, width, pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)

    ~s(<div#{box_class_attr(n, pal)} style="#{box_style(Map.get(n, "style"))}">) <>
      inner <> "</div>"
  end

  # Emits the class attr ONLY when the palette is :article (email output stays
  # byte-identical — Outlook is inline-only) AND the value is in the fixed
  # whitelist above. Everything else — email palettes, unknown classes,
  # author-injected values — emits "" (the pre-hook bytes).
  defp box_class_attr(%{"class" => class}, %{style: :article})
       when class in @box_class_whitelist,
       do: ~s( class="#{class}")

  defp box_class_attr(_n, _pal), do: ""

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
      |> children_of()
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

    # Article-only typographic roles. These now carry a `bp-role-*` CLASS (the
    # role typography lives in `.bp-paper-surface`); author marks in `out` are
    # untouched and still ride inline. In email mode (or with no hint) the class
    # is nil → byte-identical span.
    {out, inner, role_class} = apply_text_role(out, inner, n, pal)

    out = Enum.reverse(out)

    # Trap: emit NO style= attr when the style list is empty; NO class= when no
    # role. Email always takes the class-less path → byte-identical span.
    style_attr = if out == [], do: "", else: ~s( style="#{Enum.join(out, ";")}")
    class_attr = if role_class, do: ~s( class="#{role_class}"), else: ""
    "<span#{class_attr}#{style_attr}>#{inner}</span>"
  end

  # Empty PdParagraph is an EDITOR scaffold, not reader content. Compose keeps
  # the node byte-faithful so a fresh document remains authorable; every reader
  # that reaches the walker emits zero markup for it. Section rhythm belongs to
  # the shared reader stylesheet rather than stored `<p></p>` nodes.
  defp paragraph(%{"children" => []}, _width, _pal), do: ""

  # Article-mode paragraph — same role-aware styling as PdText, but emits a
  # semantic `<p>` instead of `<span>`. The editor's
  # `.bp-paper-surface p { margin: 12pt 0 0; hyphens: auto }` rule
  # (root.html.heex ~:2068) only matches real `<p>` elements; the previous
  # `<span>`-wrapped paragraphs collapsed against each other in the desk View
  # pane because there were no `<p>` margins to space them. compose_block
  # paragraph/ingress/byline emit PdParagraph in article mode so the editor's
  # body typography (font-size 18px, line-height 1.70, margin rhythm)
  # actually applies. STALE-NOTE CORRECTED (2026-09-02): the old line here
  # claimed "email/default mode keeps PdText (`<span>`) for byte-stable export".
  # It has not been true since the gp-w3 email-view wave — compose_block/2 emits
  # PdParagraph for paragraph, eyebrow, byline, ingress AND pullquote in EVERY
  # style (compose.ex `_ = style` in each of those clauses), so a real `:email`
  # render is block-level throughout. The `<span>` role output visible in
  # `email_golden.html` is a FIXTURE artifact: ParityFixture hand-builds
  # `PdText` role nodes (test/support/portable_doc_parity_fixture.ex text_roles/0),
  # bypassing compose entirely.
  # Reader-Owned Spacing Doctrine (/papers/mechanical-spacing-doctrine, flipped
  # 2026-07-31): published readers emit only visible semantic groups — an empty
  # PdParagraph scaffold (Enter, Enter) stays editable in the Pd-tree (compose
  # keeps it, doctrine invariant 1) but renders NOTHING here (no element at all),
  # never an empty `<p>` (invariant 2). Suppression is exact and narrow
  # (invariant 4): only a children list that is nothing but whitespace strings
  # vanishes — any composed inline node (PdText/PdLink/PdInlineCode/…, i.e. any
  # marked or non-text run) keeps its `<p>` byte-faithful. Cadence between the
  # remaining blocks stays reader-owned CSS margins (invariant 3). The JS twin is
  # blocks/core.ts `paragraph`; legacy cached `<p></p>` HTML is belt-and-braces
  # suppressed by `.bp-paper-surface p:empty` in paper-surface.css.
  defp paragraph(n, width, pal) do
    children = Map.get(n, "children", [])

    if blank_paragraph_children?(children) do
      ""
    else
      paragraph_html(n, children, width, pal)
    end
  end

  defp blank_paragraph_children?(children) when is_list(children) do
    Enum.all?(children, fn
      k when is_binary(k) -> String.trim(k) == ""
      _ -> false
    end)
  end

  defp blank_paragraph_children?(_), do: false

  defp paragraph_html(n, children, width, pal) do
    inner =
      children
      |> children_of()
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
    {out, inner, role_class} = apply_text_role(out, inner, n, pal)
    out = body_type(n, pal) ++ Enum.reverse(out)

    style_attr = if out == [], do: "", else: ~s( style="#{Enum.join(out, ";")}")
    class_attr = if role_class, do: ~s( class="#{role_class}"), else: ""
    "<p#{class_attr}#{style_attr}>#{inner}</p>"
  end

  # Body-copy type for the ordinary paragraph under a STYLESHEET-LESS palette
  # (`:email`, and a bare standalone export). Mail clients strip stylesheets, so
  # every other block already carries its type inline — headings via
  # heading_style/2, lists via the list clause, roles via apply_text_role/4 —
  # and the plain `<p>`, the commonest block in any paper, was the one leg that
  # emitted NO style attribute at all. It then inherited the client default
  # (~16px/normal, and in Outlook a system sans, because the wrapper's
  # font-family does not descend into `<p>`), so body copy read SMALLER and
  # looser than the 18px/1.55 ingress that introduces it.
  #
  # Values are sourced from the palette (`pal.font_body`, `pal.text`) — never a
  # re-typed hex — so a theme override moves these bytes with the rest of the
  # skin. Emitted FIRST so an author mark (weight/italic/deco/`color`) parsed
  # later still wins the cascade: a coloured paragraph keeps its author colour.
  #
  # Two deliberate exemptions:
  #   * `:article` — its `<p>` is bare BY CONTRACT; `.bp-paper-surface p` owns
  #     the typography in both View and Edit (see the moduledoc theme-vs-data
  #     contract). Stamping here would fork that single source.
  #   * a role-hinted paragraph (eyebrow/byline/ingress/pullquote) — it already
  #     carries a complete, measure-tuned stamp from apply_text_role/4; adding a
  #     base underneath it would only be overridden.
  defp body_type(_n, %{style: :article}), do: []

  defp body_type(n, pal) do
    if Map.get(n, "_role") do
      []
    else
      # An author `color` mark already paints this paragraph; emitting the
      # palette ink underneath it would only be overridden, so it is dropped —
      # one `color` declaration per `<p>`, never a dead duplicate.
      base = [
        "margin:0 0 16px",
        "font-family:#{pal.font_body}",
        "font-size:17px",
        "line-height:1.55"
      ]

      if Map.get(n, "color"), do: base, else: base ++ ["color:#{pal.text}"]
    end
  end

  # Real semantic heading (the compose clause emits PdHeading exclusively under
  # `:article`). Article mode emits a BARE `<h1>`/`<h2>`/`<h3>` by clamped level:
  # the `.bp-paper-surface h1/h2/h3` element rules (font/size/line-height/weight/
  # margin, single-sourced from the `--bp-*` heading tokens) own its typography
  # in both View and Edit by construction — see the moduledoc theme-vs-data
  # contract. Children mix raw strings (escaped) and child nodes (recursed),
  # same contract as PdText.
  defp heading(n, width, %{style: :article} = pal) do
    level = heading_level(Map.get(n, "level"))
    "<h#{level}>#{heading_inner(n, width, pal)}</h#{level}>"
  end

  # Non-article fallback: a PdHeading reaching the walker under a stylesheet-less
  # palette (email / a raw hand-built tree) keeps the level-sized inline rule so
  # it is never unstyled off-surface. `:email` compose never emits PdHeading
  # (headings render as bold PdText spans), so this stays byte-frozen for email.
  defp heading(n, width, pal) do
    level = heading_level(Map.get(n, "level"))
    style = heading_style(level, pal) |> Enum.join(";")
    ~s(<h#{level} style="#{style}">#{heading_inner(n, width, pal)}</h#{level}>)
  end

  defp heading_inner(n, width, pal) do
    Map.get(n, "children", [])
    |> children_of()
    |> Enum.map(fn
      k when is_binary(k) -> escape_html(k)
      k -> walk(k, width, pal)
    end)
    |> Enum.join("")
  end

  # Clamp a heading level to 1..3; default to 2 when absent/out of range.
  defp heading_level(l) when l in [1, 2, 3], do: l
  defp heading_level("1"), do: 1
  defp heading_level("2"), do: 2
  defp heading_level("3"), do: 3
  defp heading_level(_), do: 2

  # ── article typographic roles ──────────────────────────────────────────────
  # Applied only when the compose clause stamped a hint AND the palette is the
  # article palette. Stage 2: the role typography moved to the canonical
  # `.bp-paper-surface .bp-role-*` rules (values lifted verbatim, `pal.*` → the
  # same `var(--paper-*)` tokens), so View and Edit resolve one source. Here we
  # only pick the CLASS; `out` (author marks — weight/italic/deco/color) is
  # returned untouched and still rides inline. The pullquote's `display:block`
  # and left rule live in the class now; its `font-style:italic` is an author
  # mark already sitting in `out`. Returns `{out, inner, class | nil}`.

  defp apply_text_role(out, inner, n, %{style: :article}) do
    case Map.get(n, "_role") do
      "eyebrow" -> {out, inner, "bp-role-eyebrow"}
      "byline" -> {out, inner, "bp-role-byline"}
      "ingress" -> {out, inner, "bp-role-ingress"}
      "pullquote" -> {out, inner, "bp-role-pullquote"}
      _ -> {out, inner, nil}
    end
  end

  # Stylesheet-less palettes (email / standalone export): the role typography
  # rides INLINE (mail clients strip stylesheets — Outlook is the contract).
  # Same roles the article classes express, tuned to the email measure.
  defp apply_text_role(out, inner, n, pal) do
    case Map.get(n, "_role") do
      "eyebrow" ->
        {out ++
           [
             "font-size:12px",
             "letter-spacing:0.14em",
             "text-transform:uppercase",
             "color:#{pal.muted}",
             "font-weight:600",
             "margin:0 0 6px"
           ], inner, nil}

      "byline" ->
        {out ++
           [
             "font-size:13px",
             "color:#{pal.muted}",
             "margin:0 0 20px",
             "padding-bottom:10px",
             "border-bottom:1px solid #{pal.rule}"
           ], inner, nil}

      "ingress" ->
        {out ++ ["font-size:18px", "line-height:1.55", "margin:0 0 10px"], inner, nil}

      "pullquote" ->
        {out ++
           [
             "font-size:19px",
             "color:#{pal.text}",
             "border-left:3px solid #{pal.accent}",
             "padding:2px 0 2px 16px",
             "margin:22px 0"
           ], inner, nil}

      _ ->
        {out, inner, nil}
    end
  end

  # Heading declarations by clamped level — the NON-ARTICLE fallback only
  # (article headings are bare `<h#>` styled by `.bp-paper-surface`; see the
  # heading/3 article clause and the moduledoc theme-vs-data contract). Kept so
  # a stylesheet-less palette still emits a level-sized, self-styled heading.
  defp heading_style(1, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "letter-spacing:-0.02em",
      "line-height:1.15",
      "margin:0 0 12px",
      "font-weight:600",
      "font-size:32px"
    ]
  end

  defp heading_style(2, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.25",
      "margin:30px 0 10px",
      "font-weight:600",
      "font-size:24px"
    ]
  end

  defp heading_style(_3, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.3",
      "margin:24px 0 8px",
      "font-weight:600",
      "font-size:20px"
    ]
  end

  defp link(n, width, pal) do
    # Trap: PdLink.children mixes raw strings (escaped) and child nodes (recursed).
    inner =
      Map.get(n, "children", [])
      |> children_of()
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width, pal)
      end)
      |> Enum.join("")

    # Article links drop their inline at-rest treatment — the `.bp-paper-surface
    # a` element rule (`text-decoration:none; border-bottom:1px solid
    # var(--paper-accent-soft)`) owns it in both View and Edit by construction
    # (moduledoc theme-vs-data contract). The accent link colour stays inline
    # (the same `--paper-accent` token the CSS rule resolves, so no drift).
    # Email/default keeps the real underline — the correct convention off-surface.
    deco =
      case pal do
        %{style: :article} -> ""
        _ -> ";text-decoration:underline"
      end

    ~s(<a href="#{safe_url(Map.get(n, "href", ""))}" style="color:#{pal.link_color}#{deco}">#{inner}</a>)
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

            wikilink_anchor(href, target, inner, pal)
        end

      _ ->
        case Map.get(links, raw) do
          %{kind: "task"} = hit ->
            task_chip(hit, n, target, width, pal)

          %{id: id} ->
            href = escape_html("/papers/" <> id)

            wikilink_anchor(href, target, inner, pal)

          _ ->
            wikilink_unresolved(target, inner, pal)
        end
    end
  end

  # Wikilink emission, palette-gated (Stage 2). `:article` carries the
  # `bp-wikilink` class (the `.bp-paper-surface` rule owns colour + decoration,
  # so View ≡ Edit); `:email` keeps the inline accent + decoration verbatim
  # (Outlook has no stylesheet). Values lifted verbatim: article colour is the
  # same `var(--paper-accent)` the CSS rule resolves.
  defp wikilink_anchor(href, target, inner, %{style: :article}) do
    ~s(<a href="#{href}" data-wikilink="#{target}" class="bp-wikilink">#{inner}</a>)
  end

  defp wikilink_anchor(href, target, inner, pal) do
    ~s(<a href="#{href}" data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:none">#{inner}</a>)
  end

  defp wikilink_unresolved(target, inner, %{style: :article}) do
    ~s(<span data-wikilink="#{target}" class="bp-wikilink bp-wikilink--unresolved">#{inner}</span>)
  end

  defp wikilink_unresolved(target, inner, pal) do
    ~s(<span data-wikilink="#{target}" style="color:#{pal.link_color};text-decoration:underline dotted">#{inner}</span>)
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
          |> children_of()
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
    {status, chip_text, label} = task_chip_parts(hit, n, width, pal)
    task_chip_html(target, hit, status, chip_text, label, pal)
  end

  # The status / badge-text / label triple — palette-invariant (the chip content
  # reads the same in View and email); only the FRAME differs by palette.
  defp task_chip_parts(hit, n, width, pal) do
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

    {status, chip_text, label}
  end

  # Chip FRAME, palette-gated (Stage 2): `:article` carries `bp-task-chip`
  # (nowrap) + `bp-task-chip__badge` (the pill border/padding/accent), styled by
  # `.bp-paper-surface`; `:email` keeps the inline pill verbatim.
  defp task_chip_html(target, hit, status, chip_text, label, %{style: :article}) do
    ~s(<span data-taskchip="#{target}" data-task-id="#{escape_html(to_string(hit[:id] || ""))}"#{task_status_attr(status)} class="bp-task-chip">) <>
      ~s(<span class="bp-task-chip__badge">#{chip_text}</span> ) <>
      label <> "</span>"
  end

  defp task_chip_html(target, hit, status, chip_text, label, pal) do
    ~s(<span data-taskchip="#{target}" data-task-id="#{escape_html(to_string(hit[:id] || ""))}"#{task_status_attr(status)} style="white-space:nowrap">) <>
      ~s(<span style="border:1px solid #{pal.link_color};border-radius:10px;padding:0 6px;color:#{pal.link_color};font-size:0.85em">#{chip_text}</span> ) <>
      label <> "</span>"
  end

  defp task_status_attr(nil), do: ""
  defp task_status_attr(s), do: ~s( data-task-status="#{escape_html(s)}")

  # Status glyph — DELEGATES to the StatusVocab manifest (the white ladder,
  # design/status-manifest.json) so this View + email shared chip cannot drift
  # from the one source of truth. A known status resolves status → role → glyph;
  # the `progress` spinner role degrades to the ⠿ still-frame per charter D5 —
  # the SAME still-frame the sibling Elixir emitter fleet_email.ex chip uses
  # (fleet_email.ex:580), and DELIBERATELY not Go pdrender's terminal ⠋ frame:
  # the cross-language delta is per-surface consistency, not drift (the coverage
  # test in walk_test.exs pins this). An unknown / missing status (not a manifest
  # key) keeps the neutral ▸ pointer sentinel — neither a ladder glyph nor the
  # spinner.
  defp task_glyph(status) do
    case StatusVocab.statuses() do
      %{^status => role} ->
        if StatusVocab.spinner?(role), do: "⠿", else: StatusVocab.glyph_for_role(role)

      _ ->
        "▸"
    end
  end

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
  # Stage 2: `:article` carries the `bp-embed` frame class (the `.bp-paper-surface`
  # rule owns margin/padding/accent bar) while keeping `paper-embed` as the
  # data/JS hook; `:email` keeps the inline frame verbatim (no stylesheet off-surface).
  defp embed(n, %{style: :article} = pal) do
    raw = Map.get(n, "target", "")
    target = escape_html(raw)

    case Map.get(Map.get(pal, :embeds, %{}), raw) do
      html when is_binary(html) ->
        ~s(<section class="paper-embed bp-embed" data-embed="#{target}">#{html}</section>)

      _ ->
        ~s(<section class="paper-embed paper-embed--unresolved bp-embed bp-embed--unresolved" data-embed="#{target}">↪ #{target}</section>)
    end
  end

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
        blockref_link(href, target, anchor, pal)

      _ ->
        blockref_span(target, anchor, pal)
    end
  end

  # Stage 2: `:article` carries `bp-blockref` (the muted micro-link, styled by
  # `.bp-paper-surface` — the flat `#6b7280` gray becomes the theme-aware
  # `var(--paper-ink-soft)`); `:email` keeps the inline gray verbatim.
  defp blockref_link(href, target, anchor, %{style: :article}) do
    ~s(<a href="#{href}" data-blockref="#{target}" data-anchor="#{anchor}" class="bp-blockref">^#{anchor}</a>)
  end

  defp blockref_link(href, target, anchor, _pal) do
    ~s(<a href="#{href}" data-blockref="#{target}" data-anchor="#{anchor}" style="color:#6b7280;font-size:0.9em;text-decoration:none">^#{anchor}</a>)
  end

  defp blockref_span(target, anchor, %{style: :article}) do
    ~s(<span data-blockref="#{target}" data-anchor="#{anchor}" class="bp-blockref">^#{anchor}</span>)
  end

  defp blockref_span(target, anchor, _pal) do
    ~s(<span data-blockref="#{target}" data-anchor="#{anchor}" style="color:#6b7280;font-size:0.9em">^#{anchor}</span>)
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

    tag_node_html(href, name, pal)
  end

  # Verdict chip (PdChip — inline `chip` node). `:article` carries the
  # `.bp-chip` family the surface styles from the `--bp-tone-*` pairs; the
  # email/default leg inlines the SAME tone pair through `Util.tone_palette/1`
  # so a chip reads identically in a digest. An unknown tone degrades to
  # neutral (never info — a verdict that failed to parse must not look like
  # an informational one). The note is a block under the chip in the article
  # and a soft trailing span inline in email.
  @chip_tones ~w(success warning danger info neutral)

  defp chip(n, pal) do
    tone = if Map.get(n, "tone") in @chip_tones, do: Map.get(n, "tone"), else: "neutral"
    strong? = Map.get(n, "strong") == true
    text = escape_html(Map.get(n, "text") || "")
    note = escape_html(Map.get(n, "note") || "")
    chip_html(tone, strong?, text, note, pal)
  end

  defp chip_html(tone, strong?, text, note, %{style: :article}) do
    strong_cls = if strong?, do: " bp-chip--strong", else: ""
    note_html = if note == "", do: "", else: ~s(<span class="bp-chip__note">#{note}</span>)

    ~s(<span class="bp-chip bp-chip--#{tone}#{strong_cls}"><i class="bp-chip__dot"></i>#{text}</span>) <>
      note_html
  end

  defp chip_html(tone, strong?, text, note, _pal) do
    %{bg: bg, fg: fg} = Barkpark.PortableDoc.Render.Util.tone_palette(tone)
    {bg, fg} = if strong?, do: {fg, "#ffffff"}, else: {bg, fg}

    note_html =
      if note == "",
        do: "",
        else: ~s( <span style="color:#6b7280;font-size:0.85em">#{note}</span>)

    ~s(<span style="display:inline-block;background:#{bg};color:#{fg};padding:1px 8px;border-radius:999px;font-size:0.85em;font-weight:600">#{text}</span>) <>
      note_html
  end

  # Stage 2: `:article` carries `bp-tag` (the pill chip, styled by
  # `.bp-paper-surface`); `:email` keeps the inline chip verbatim.
  defp tag_node_html(href, name, %{style: :article}) do
    ~s(<a href="#{href}" data-tag="#{name}" class="bp-tag">##{name}</a>)
  end

  defp tag_node_html(href, name, pal) do
    ~s(<a href="#{href}" data-tag="#{name}" style="color:#{pal.link_color};background:#{pal.code_bg};padding:1px 6px;border-radius:3px;font-size:0.9em;text-decoration:none">##{name}</a>)
  end

  # Stage 2: `:article` carries `bp-button` (secondary) / `bp-button--primary`
  # (the `.bp-paper-surface` rules own the accent fill/border, single-sourced
  # from `var(--paper-accent)`); `:email` keeps the inline pill verbatim.
  defp button(n, %{style: :article} = _pal) do
    label = escape_html(Map.get(n, "label", ""))
    href = safe_url(Map.get(n, "href", ""))

    if Map.get(n, "priority") == "primary" do
      ~s(<a href="#{href}" class="bp-button bp-button--primary">#{label}</a>)
    else
      ~s(<a href="#{href}" class="bp-button">#{label}</a>)
    end
  end

  defp button(n, pal) do
    label = escape_html(Map.get(n, "label", ""))
    href = safe_url(Map.get(n, "href", ""))

    if Map.get(n, "priority") == "primary" do
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;background:#{pal.accent};color:#{pal.brand_text};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    else
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;border:2px solid #{pal.accent};color:#{pal.accent};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    end
  end

  # Stage 2: `:article` moves the rule reset/colour/margin to `.bp-hr`; the
  # author thickness stays inline as `border-top-width` (DATA — it must survive
  # a stylesheet-less sink). `:email` keeps the full inline rule verbatim.
  defp hr(n, %{style: :article} = _pal) do
    t = Map.get(n, "thickness") || 1

    ~s(<hr class="bp-hr" style="border-top-width:#{escape_attr(to_string(t))}px">)
  end

  defp hr(n, pal) do
    t = Map.get(n, "thickness") || 1

    ~s(<hr style="border:none;border-top:#{escape_attr(to_string(t))}px solid #{pal.rule};margin:30px 0 26px">)
  end

  defp image(n, article_attrs \\ "") do
    dims =
      case Map.get(n, "width") do
        nil -> ""
        w -> ~s( width="#{escape_attr(to_string(w))}")
      end <>
        case Map.get(n, "height") do
          nil -> ""
          h -> ~s( height="#{escape_attr(to_string(h))}")
        end

    ~s(<img src="#{safe_url(Map.get(n, "src", ""))}" alt="#{escape_attr(Map.get(n, "alt", ""))}"#{article_attrs} style="max-width:100%;height:auto"#{dims}>)
  end

  # Article mode styles the header row distinctly: the first row becomes a
  # `<thead>`/`<th>` band — uppercase, muted, with a 2px bottom rule under the
  # header — and the warm rule colour replaces gray on the body cells. Stage 2:
  # the band + cell + collapse chrome is CLASS-driven (`bp-table`,
  # `bp-table__th`, `bp-table__td` under `.bp-paper-surface`) so View ≡ Edit;
  # tables carry no author DATA, so nothing stays inline. Email/default mode
  # keeps the flat inline `<td>`-only table, byte-identical to before.
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
            ~s(<th class="bp-table__th">#{inner}</th>)
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
            ~s(<td class="bp-table__td">#{inner}</td>)
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" class="bp-table">) <>
      thead <> "<tbody>#{tbody}</tbody></table>"
  end

  defp table(n, width, pal) do
    # Email table: horizontal rules only (a full 1px grid reads as a 2003
    # default); an opt-in header band mirrors the article thead. All inline —
    # mail clients strip stylesheets.
    head = Map.get(n, "head", []) |> List.wrap()

    thead =
      if head == [] do
        ""
      else
        cells =
          head
          |> Enum.map(fn cell ->
            inner = render_children(cell, width, pal)

            ~s(<th align="left" style="border-bottom:2px solid #{pal.text};padding:8px 12px;vertical-align:bottom;font-size:13px;letter-spacing:0.02em;color:#{pal.muted};text-transform:uppercase;font-weight:600">#{inner}</th>)
          end)
          |> Enum.join("")

        "<thead><tr>#{cells}</tr></thead>"
      end

    rows =
      Map.get(n, "rows", [])
      |> Enum.map(fn row ->
        cells =
          row
          |> Enum.map(fn cell ->
            inner = render_children(cell, width, pal)

            ~s(<td style="border-bottom:1px solid #{pal.rule};padding:10px 12px;vertical-align:top">#{inner}</td>)
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%;margin:18px 0">#{thead}<tbody>#{rows}</tbody></table>)
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
            # CHROME (band typography/rule) is class-driven; only the author
            # `col_widths` width stays inline (DATA — sheets_parity reads it here).
            w_style = col_width_style(col_widths, idx)
            ~s(<th class="bp-sheet__th"#{sheet_inline_style(w_style)}>#{escape_html(cell)}</th>)
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
              # CHROME (border/padding/mono-font/size) → `bp-sheet__td`; author
              # DATA stays inline — col width, per-cell b/i/bg/al, and the engine
              # error red/bold (all pinned cross-surface by sheets_parity). The
              # derived default-align CLASS rides in the SAME class attr as the
              # chrome class (one attribute; explicit `al` still suppresses it).
              w_style = col_width_style(col_widths, c)
              span = sheet_span_attr(anchors, r, c)
              extra = sheet_cell_style(styles, r, c)
              err = sheet_err_style(cell)

              align_class =
                if sheet_explicit_al?(styles, r, c),
                  do: nil,
                  else: sheet_default_align_class(cell)

              td_class = ["bp-sheet__td", align_class] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

              [
                ~s(<td#{span} class="#{td_class}"#{sheet_inline_style(w_style <> extra <> err)}>#{sheet_cell_html(cell, pal)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    table =
      ~s(<table role="presentation" class="bp-table">) <>
        thead <> "<tbody>#{tbody}</tbody></table>"

    table <> sheet_truncation_note(n, length(body), pal)
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
                ~s(<td#{span}#{al} style="#{w_style}border:1px solid #{pal.rule};padding:6px 10px;vertical-align:top#{extra}#{err}">#{sheet_cell_html(cell, pal)}</td>)
              ]
            end
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    table =
      ~s(<table role="presentation" style="border-collapse:collapse;width:100%">#{thead_row}<tbody>#{rows}</tbody></table>)

    table <> sheet_truncation_note(n, length(body), pal)
  end

  # When the snapshot was clipped at the position cap (`"truncated" => true`),
  # append a muted note so a paper never shows silent partial data. `shown` is
  # the number of body rows actually rendered. Stage 2: `:article` carries the
  # `bp-sheet-note` class (styled by `.bp-paper-surface`); `:email` keeps the
  # inline muted `<p>` verbatim.
  defp sheet_truncation_note(n, shown, %{style: :article}) do
    if Map.get(n, "truncated") do
      ~s(<p class="bp-sheet-note">) <>
        escape_html("Sheet truncated — showing the first #{shown} rows") <> "</p>"
    else
      ""
    end
  end

  defp sheet_truncation_note(n, shown, pal) do
    if Map.get(n, "truncated") do
      ~s(<p style="margin:6px 0 0;font-size:0.8rem;color:#{pal.muted}">) <>
        escape_html("Sheet truncated — showing the first #{shown} rows") <> "</p>"
    else
      ""
    end
  end

  # Emit a ` style="…"` attr from a raw DATA fragment (col-width + per-cell
  # b/i/bg/al + error). The fragment bytes are preserved VERBATIM (the per-cell
  # style/error fragments are pinned literally by sheets_parity and the html
  # export tests); we only trim the cosmetic leading `;` that the chrome base
  # (now a class) used to sit in front of. `""` when there is no DATA.
  defp sheet_inline_style(raw) do
    # Collapse the empty declarations the mixed fragment conventions produce (a
    # `;;` seam where col-width meets a cell style, or a cell style meets the
    # error mark) and trim the cosmetic leading `;`. Real declarations — and
    # their trailing `;` — are untouched, so the per-cell DATA bytes pinned by
    # sheets_parity and the export tests survive verbatim.
    case raw |> String.replace(";;", ";") |> String.trim_leading(";") do
      "" -> ""
      style -> ~s( style="#{style}")
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
  # Stage 2: `:article` carries `bp-sheet-link` (the `.bp-paper-surface` rule
  # colours it `var(--paper-accent)` — the old hardcoded `#2563eb` was wrong in
  # dark mode); `:email` keeps the inline blue anchor verbatim.
  defp sheet_cell_html(cell, %{style: :article}) when is_binary(cell) do
    if Regex.match?(@sheet_url_re, cell) do
      ~s(<a href="#{safe_url(cell)}" class="bp-sheet-link" target="_blank" rel="noopener noreferrer nofollow">#{escape_html(cell)}</a>)
    else
      escape_html(cell)
    end
  end

  defp sheet_cell_html(cell, _pal) when is_binary(cell) do
    if Regex.match?(@sheet_url_re, cell) do
      ~s(<a href="#{safe_url(cell)}" target="_blank" rel="noopener noreferrer nofollow" style="color:#2563eb;text-decoration:underline">#{escape_html(cell)}</a>)
    else
      escape_html(cell)
    end
  end

  defp sheet_cell_html(cell, _pal), do: escape_html(cell)

  defp sheet_bg_style(bg) when is_binary(bg) do
    # Delegates to the ONE `#rrggbb` owner (capability:sheets-bg-sanitizer) —
    # `\z`-anchored, so a stored "#rrggbb\n" is rejected here and can never
    # smuggle a newline into this inline `style` attribute.
    if Barkpark.Plugins.Sheets.CondFormat.valid_bg?(bg), do: "background:#{bg};", else: ""
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

  # Stage 2 article callout: the tone card is CLASS-driven — `bp-callout` +
  # `bp-callout--<tone>` resolve the `--bp-tone-*` light/dark tokens under
  # `.bp-paper-surface` (View ≡ Edit, and dark mode is a pure token swap). The
  # tone modifier falls back to `info` for an unknown tone, exactly as
  # `Util.tone_palette/1` does. `:email` takes the byte-identical inline clause below.
  defp callout(n, width, %{style: :article} = pal) do
    tone_mod = callout_tone_class(Map.get(n, "tone"))
    inner = render_children(Map.get(n, "children", []), width, pal)

    if Map.get(n, "collapsible") == true do
      collapsible_callout_article(n, tone_mod, inner)
    else
      title_html = callout_title_html(n)

      ~s(<div class="bp-callout bp-callout--#{tone_mod}">#{title_html}#{inner}</div>)
    end
  end

  defp callout(n, width, pal) do
    tone = tone_palette(Map.get(n, "tone"))
    inner = render_children(Map.get(n, "children", []), width, pal)

    # `collapsible` is only ever present in ARTICLE mode (compose.ex gates it),
    # so email/non-collapsible callouts take the byte-identical legacy <div>.
    if Map.get(n, "collapsible") == true do
      collapsible_callout(n, tone, inner)
    else
      title =
        case Map.get(n, "title") do
          t when t in [nil, ""] ->
            ""

          t ->
            ~s(<div style="color:#{tone.fg};font-weight:600;margin:0 0 6px">#{escape_html(t)}</div>)
        end

      ~s(<div style="border-left:3px solid #{tone.fg};background:#{tone.bg};padding:14px 18px;border-radius:0 8px 8px 0;color:#{pal.text};margin:20px 0">#{title}#{inner}</div>)
    end
  end

  defp callout_title_html(n) do
    case Map.get(n, "title") do
      nil -> ""
      "" -> ""
      title -> "<strong>#{escape_html(title)}</strong> "
    end
  end

  # Tone → modifier class, mirroring `Util.tone_palette/1`'s clause set (unknown
  # → info). The five knowns each get a `--bp-tone-<tone>-{bg,fg}` token pair.
  defp callout_tone_class("success"), do: "success"
  defp callout_tone_class("warning"), do: "warning"
  defp callout_tone_class("danger"), do: "danger"
  defp callout_tone_class("neutral"), do: "neutral"
  defp callout_tone_class("info"), do: "info"
  defp callout_tone_class(_), do: "info"

  # Zero-JS native fold via <details>/<summary>. `open` reflects !collapsed; the
  # summary is the title, or a tone label so it is never empty.
  defp collapsible_callout(n, tone, inner) do
    open = if Map.get(n, "collapsed") == true, do: "", else: " open"
    summary = escape_html(callout_summary(n))

    ~s(<details#{open} style="border-left:4px solid #{tone.fg};background:#{tone.bg};padding:16px;color:#{tone.fg}">) <>
      ~s(<summary style="cursor:pointer;font-weight:bold">#{summary}</summary>) <>
      ~s(<div style="margin-top:8px">#{inner}</div></details>)
  end

  # Article collapsible — same fold, CLASS-driven tone card + summary/body chrome.
  defp collapsible_callout_article(n, tone_mod, inner) do
    open = if Map.get(n, "collapsed") == true, do: "", else: " open"
    summary = escape_html(callout_summary(n))

    ~s(<details#{open} class="bp-callout bp-callout--#{tone_mod}">) <>
      ~s(<summary class="bp-callout__summary">#{summary}</summary>) <>
      ~s(<div class="bp-callout__body">#{inner}</div></details>)
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

  # BARE semantic `<ul>` / `<ol>` / `<li>` for article mode. The
  # `.bp-paper-surface ul, ol` rule (margin + `--bp-list-indent`), the VIEW-only
  # list bottom-margin, the `.bp-paper-surface li` rule (`--bp-li-gap`), and the
  # surface root (serif font, ink, `--bp-body-lh` line-height, inherited) own
  # all structure in both View and Edit by construction — see the moduledoc
  # theme-vs-data contract.
  defp list(n, width, %{style: :article} = pal) do
    tag = if Map.get(n, "ordered"), do: "ol", else: "ul"
    inner = render_children(Map.get(n, "children", []), width, pal)
    "<#{tag}>" <> inner <> "</#{tag}>"
  end

  # Email/default keeps the same semantic structure but owns its styling inline:
  # clients may strip stylesheets, so list indentation, typography, and item
  # spacing must travel on the `<ul>` / `<ol>` / `<li>` elements themselves.
  defp list(n, width, pal) do
    tag = if Map.get(n, "ordered"), do: "ol", else: "ul"
    inner = render_children(Map.get(n, "children", []), width, pal)

    ~s(<#{tag} style="margin:0 0 24px;padding-left:24px;font-family:#{pal.font_body};color:#{pal.text};line-height:1.7">) <>
      inner <> "</#{tag}>"
  end

  defp list_item(n, width, %{style: :article} = pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)
    "<li>" <> inner <> "</li>"
  end

  defp list_item(n, width, pal) do
    inner = render_children(Map.get(n, "children", []), width, pal)
    ~s(<li style="margin:4pt 0 0">) <> inner <> "</li>"
  end

  # PdBlockquote — a semantic quotation (compose_block(blockquote)). Article emits
  # a bare `<blockquote class="bp-blockquote">` wrapping a `<p>` body: the
  # `.bp-paper-surface .bp-blockquote` rule owns the left-rule + italic + muted
  # styling (theme-keyed, the same theme-vs-data contract as list/heading), and
  # the `<cite class="bp-blockquote__cite">` carries the optional attribution.
  # The inner is built the PARAGRAPH way (bare escaped text + `<span>` only for
  # marks) so it stays SHAPE-equal to the JS `blockquote` emitter the parity
  # harness compares against. Email/default self-styles inline (Outlook has no
  # stylesheet) — a left-border + italic + muted `<blockquote>`, cite on its own
  # muted line prefixed with an em-dash.
  defp blockquote(n, width, %{style: :article} = pal) do
    inner = paragraph_inner(Map.get(n, "children", []), width, pal)
    cite = blockquote_cite_html(n, pal)
    ~s(<blockquote class="bp-blockquote"><p>) <> inner <> "</p>" <> cite <> "</blockquote>"
  end

  defp blockquote(n, width, pal) do
    inner = paragraph_inner(Map.get(n, "children", []), width, pal)
    cite = blockquote_cite_html(n, pal)

    ~s(<blockquote style="margin:0 0 16px;padding:2px 0 2px 16px;border-left:3px solid #{pal.rule};color:#{pal.muted};font-style:italic;font-family:#{pal.font_body}">) <>
      inner <> cite <> "</blockquote>"
  end

  defp blockquote_cite_html(n, %{style: :article}) do
    case Map.get(n, "cite") do
      c when is_binary(c) and c != "" ->
        ~s(<cite class="bp-blockquote__cite">) <> escape_html(c) <> "</cite>"

      _ ->
        ""
    end
  end

  defp blockquote_cite_html(n, pal) do
    case Map.get(n, "cite") do
      c when is_binary(c) and c != "" ->
        ~s(<cite style="display:block;margin-top:6px;font-style:normal;font-size:14px;color:#{pal.muted}">— ) <>
          escape_html(c) <> "</cite>"

      _ ->
        ""
    end
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  # Fail-safe coercion for a node's `children`. Papers are schemaless — a raw
  # API/SDK/CLI mutate can persist a PRESENT `children` key whose JSON value is
  # `null` (→ `nil` here) or a bare scalar, and `Map.get(n, "children", [])`
  # only substitutes the default on an ABSENT key. Any non-list would then hit
  # `Enum.map/2` and RAISE, 500-ing every reader of the raw-tree entry
  # (render_html/2 → render_body/3, reachable by the TUI, plugins, and tests
  # ahead of compose coercion). Coercing any non-list to `[]` degrades to empty
  # instead — it CANNOT alter a list-path render (a list passes through
  # unchanged), so a passing render never regresses.
  defp children_of(c) when is_list(c), do: c
  defp children_of(_), do: []

  # Non-list children degrade to "" here (mirrors the walk/3 non-node catch-all),
  # covering every render_children caller transitively.
  defp render_children(children, _width, _pal) when not is_list(children), do: ""

  defp render_children(children, width, pal) do
    children
    |> Enum.map(&walk(&1, width, pal))
    |> Enum.join("")
  end

  # Inline inner the PARAGRAPH way (mirrors paragraph/3): a bare-string child is
  # escaped verbatim, a Pd node (a mark span, link, code) is walked. Shared by
  # PdBlockquote so its inner is byte/shape-equal to a paragraph's — the parity
  # harness compares the article <blockquote> against the JS emitter.
  defp paragraph_inner(children, _width, _pal) when not is_list(children), do: ""

  defp paragraph_inner(children, width, pal) do
    children
    |> Enum.map(fn
      k when is_binary(k) -> escape_html(k)
      k -> walk(k, width, pal)
    end)
    |> Enum.join("")
  end
end
