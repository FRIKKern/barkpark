defmodule Barkpark.PortableDoc.Render.Compose do
  @moduledoc """
  portable-doc block → Pd-tree composition for the PortableDoc render engine —
  one clause per block type. Its cross-runtime twin is the block-composition
  step of the Go `internal/pdrender` renderer (held in parity by the shared
  golden fixtures). Trusts the AST has already been validated (the validator is
  the only gate); it does not re-validate URLs or tone palette membership.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). This is the COMPOSE recursive tree (`compose_block` →
  `compose_inline` / figure HTML); it never calls walk except via the generic
  `figure_html` bridge, which composes a child then renders it through
  `Render.Walk.render_body/3`. Output is byte-identical to the pre-split engine.
  """

  alias Barkpark.PortableDoc.Render.{Figures, Forms, Inline, Util, Walk}

  import Inline, only: [compose_inline_children: 1, to_pd_node_from_inline_child: 1]

  # Default theme id (charter D28). compose_block/1,2 resolve their one baked
  # colour (the field-color swatch border) through this; compose_block/3 carries
  # a caller-supplied theme instead.
  @default_theme :evergreen

  # ── compose_block: portable-doc block → Pd-tree ────────────────────────────

  # `compose_block/1` keeps the email (default) palette so existing call sites
  # and tests are byte-unchanged. The style-aware `compose_block/2` below carries
  # the render style so heading / eyebrow / byline / ingress can diverge.
  @doc false
  def compose_block(b), do: compose_block(b, :email)

  # ── theme-threaded dispatch (charter D28) ──────────────────────────────────
  #
  # `compose_block/3` is the theme-aware entry `Render.render_block/2` calls with
  # `opts[:theme]`. Only the COLOUR-baking block types read `theme` — the
  # field-color swatch border (Palettes.rule/1) and the email-variant data-viz
  # emitters (DataViz.*_email_html/2). Every other block (and all `:article`
  # renders, whose colour lives in paper-surface.css, theme-keyed by ts-w4b)
  # forwards to the theme-invariant compose_block/2 clause byte-unchanged. The
  # evergreen default makes compose_block(b, style, :evergreen) byte-identical to
  # compose_block(b, style).
  #
  # SCOPE: the container clauses (section / columns / terminal) recurse through
  # `render_blocks/2`, which threads `style` only — a data-viz block nested INSIDE
  # a section renders its email variant at evergreen. The walk palette (every
  # prose/link/button/table/callout colour) IS fully theme-threaded at all depths;
  # nested EMAIL data-viz theming is a filed follow-on (article data-viz is
  # CSS-themed regardless).
  #
  # The FLEET email variants (terminal / columns / status-legend — Render.PanelsEmail,
  # and the task / cards families in Render.FleetEmail / Render.CardsEmail) are
  # evergreen-nested by the SAME design (charter D8): a terminal / column composes
  # its children through `render_children/2` (style-only), so a task-list nested in
  # a terminal gets its email variant at evergreen while the panel's OWN chrome is
  # theme-threaded. This is a ratified accepted tradeoff, NOT a filed follow-on —
  # no bp task exists for nested panel theming (the email envelope renders evergreen;
  # "dark" in a mail client is the client's transform of these bytes, not a re-render).
  @doc false
  def compose_block(%{"type" => "field-color"} = b, style, theme) when style != :article,
    do: compose_field_color(b, theme)

  def compose_block(%{"type" => "stat"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.DataViz.stat_email_html(b, theme)
    }

  def compose_block(%{"type" => t} = b, style, theme)
      when t in ["stats", "stat-grid"] and style != :article,
      do: %{
        "kind" => "_raw",
        "html" => Barkpark.PortableDoc.Render.DataViz.stats_email_html(b, theme)
      }

  def compose_block(%{"type" => "heatmap"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.DataViz.heatmap_email_html(b, theme)
    }

  def compose_block(%{"type" => "chart"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.DataViz.chart_email_html(b, theme)
    }

  def compose_block(%{"type" => "gauge-list"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.DataViz.gauge_list_email_html(b, theme)
    }

  # Task-family fleet email variants (gp-w4a). Same three-clause split as the
  # data-viz slate: the theme-aware /3 entry threads `theme` into the inline-
  # styled emitters; the classed article emitters (Components.*_html) stay
  # byte-locked below on the /2 :article clauses.
  def compose_block(%{"type" => t} = b, style, theme)
      when t in ["tasks", "task-list"] and style != :article,
      do: %{
        "kind" => "_raw",
        "html" => Barkpark.PortableDoc.Render.FleetEmail.tasks_email_html(b, theme)
      }

  def compose_block(%{"type" => "task-detail"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.FleetEmail.task_detail_email_html(b, theme)
    }

  def compose_block(%{"type" => "task-board"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.FleetEmail.task_board_email_html(b, theme)
    }

  def compose_block(%{"type" => "roadmap"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.FleetEmail.roadmap_email_html(b, theme)
    }

  # Cards / notes / pipeline fleet (charter w4b) — the classed Components.*_html
  # emit `bp-*` markup that arrives as unstyled text in a stylesheet-less client;
  # every non-:article style takes the inline-styled CardsEmail variants instead.
  def compose_block(%{"type" => "cards"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.cards_email_html(b, theme)
    }

  def compose_block(%{"type" => "card"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.card_email_html(b, theme)
    }

  def compose_block(%{"type" => "notes"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.notes_email_html(b, theme)
    }

  def compose_block(%{"type" => "note"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.note_email_html(b, theme)
    }

  def compose_block(%{"type" => "pipeline"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.pipeline_email_html(b, theme)
    }

  def compose_block(%{"type" => "stage"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.CardsEmail.stage_email_html(b, theme)
    }

  # Fleet PANEL email variants (slice w4c). A TOP-LEVEL terminal / columns /
  # status-legend routes here (render_block/2 → compose_block/3) so its chrome
  # is theme-threaded; the CONTAINER children are still composed at evergreen via
  # `render_children/2` (charter D1/D8 — see the SCOPE note above).
  def compose_block(%{"type" => "terminal"} = b, style, theme) when style != :article do
    body = b |> container_children() |> render_children(style)

    %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.PanelsEmail.terminal_email_html(b, body, theme)
    }
  end

  def compose_block(%{"type" => "columns"} = b, style, theme) when style != :article do
    %{"kind" => "_raw", "html" => columns_email_html(b, style, theme)}
  end

  def compose_block(%{"type" => "status-legend"} = b, style, theme) when style != :article,
    do: %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.PanelsEmail.status_legend_email_html(b, theme)
    }

  def compose_block(b, style, _theme), do: compose_block(b, style)

  @doc false
  def compose_block(%{"type" => "heading"} = b, style) do
    # `text` is coerced through the tolerant `stringish/1` — a raw mutate can
    # persist a map/list where the heading string was expected, which used to
    # FunctionClauseError in the walker (a non-binary heading child has no walk
    # clause). Binaries/numbers stringify byte-identically; a map/list → "".
    children =
      case Map.get(b, "content") do
        content when is_list(content) and content != [] -> compose_inline_children(content)
        _ -> [stringish(Map.get(b, "text", ""))]
      end

    level = heading_level(Map.get(b, "level"))

    # EVERY style emits a real semantic heading node (`PdHeading` → `<h1>` /
    # `<h2>` / `<h3>`): screen readers, the outline tree, and CSS `hN`
    # selectors see a genuine heading. The walker styles it per palette —
    # article gets the bare element (the stylesheet owns typography), email
    # gets the level-sized INLINE rule (never unstyled off-surface). Email
    # headings were bold `<span>`s until the email-view wave (gp-w3): a mailed
    # paper deserves the same typographic skeleton the reader shows.
    _ = style
    %{"kind" => "PdHeading", "level" => level, "children" => children}
  end

  def compose_block(%{"type" => "eyebrow"} = b, style) do
    # Uppercase, letter-spaced, accent kicker (article) / muted line (email).
    # The walk reads `_role` to pick the styling per palette. Article mode emits
    # a real `<p>` (like byline/ingress) so the canvas node-view's `<p
    # class="bp-role-eyebrow">` inherits the SAME block rhythm the reader does —
    # otherwise the edit `<p>` picks up the generic `.bp-paper-editor-body p`
    # 12pt margin the reader's inline `<span>` never had (View↔Edit drift).
    # EVERY style emits a real `<p>` since the email-polish wave: the old
    # email `<span>` form fused the masthead into one line (eyebrow + byline +
    # ingress ran together with zero block separation in mail clients).
    _ = style

    %{
      "kind" => "PdParagraph",
      "_role" => "eyebrow",
      "children" => [stringish(Map.get(b, "text", ""))]
    }
  end

  def compose_block(%{"type" => "byline"} = b, style) do
    # `items` (list) joined by " · ", else a plain `text`. Muted sans line with
    # a bottom rule in article mode. Article mode emits a real `<p>` so the
    # byline's bottom-rule + bottom-margin land as block-level rhythm (was a
    # span before — visually correct because of inline-style overrides, but
    # not semantically a block).
    text =
      case Map.get(b, "items") do
        items when is_list(items) -> items |> Enum.map(&stringish/1) |> Enum.join(" · ")
        _ -> stringish(Map.get(b, "text", ""))
      end

    _ = style
    %{"kind" => "PdParagraph", "_role" => "byline", "children" => [text]}
  end

  def compose_block(%{"type" => "ingress"} = b, style) do
    # Lead paragraph — heavier weight + larger size in article mode.
    # EVERY style emits a real `<p>` (see the eyebrow clause — the email
    # `<span>` form fused the masthead into one line).
    _ = style

    %{
      "kind" => "PdParagraph",
      "_role" => "ingress",
      "children" => compose_inline_children(paragraph_inline(b))
    }
  end

  def compose_block(%{"type" => "paragraph"} = b, style) do
    # EVERY style emits a real `<p>` (PdParagraph): in article the stylesheet
    # owns the margins; in email the client's default paragraph spacing does —
    # both beat the bare `<span>`s email used to get, which collapsed every
    # paragraph into one unbroken run (gp-w3 email-view wave).
    _ = style
    %{"kind" => "PdParagraph", "children" => compose_inline_children(paragraph_inline(b))}
  end

  # ── Authoring-drift type aliases (the choke point) ─────────────────────────
  # 77 live prod blocks were persisted under TipTap-internal / snake / kebab
  # spellings this engine never dispatched → "Unsupported block" placeholders on
  # the public reader. Normalize the drifted spelling to its canonical type ONCE
  # here — compose_block/2 is the single funnel every render lands in (the
  # style/theme entry compose_block/3 forwards every non-email-variant block here
  # byte-unchanged), so View + Email + every direct caller render real blocks on
  # deploy with ZERO stored-data migration. VARIABLE-guard form (matching on a
  # bound `t`, never a quoted string head) is deliberate: it keeps these aliases
  # OUT of the tiers-completeness / parity-census extractors (both grep quoted
  # string type heads), because an alias has no tier or golden of its own — it
  # borrows its target's. The list-variant `items` carry the same shape the
  # `list` clause already reads; `quote` becomes `blockquote` (born below).
  @unordered_list_aliases ~w(bulletList bullet_list bulleted-list bulleted_list)
  def compose_block(%{"type" => t} = b, style) when t in @unordered_list_aliases,
    do: compose_block(Map.put(b, "type", "list"), style)

  def compose_block(%{"type" => t} = b, style) when t == "numbered_list",
    do: compose_block(b |> Map.put("type", "list") |> Map.put("ordered", true), style)

  def compose_block(%{"type" => t} = b, style) when t == "ordered-list",
    do: compose_block(b |> Map.put("type", "list") |> Map.put("ordered", true), style)

  # h-tag spellings → heading at the level the TYPE names (charter D57): 18 live
  # blocks composed to `unknown_block_node/1` on the View and Email surfaces.
  # The level is taken from the TYPE, overwriting any stored `level` — SIX of
  # the 18 drifted headings (1 h2 + all 5 h3s) carry no `level` key, so
  # borrowing the heading clause without forcing the level would render an `h3`
  # as an `<h2>`. Zero live blocks contradict their type. Same
  # VARIABLE-guard form as the list aliases above, and for the same reason: it
  # keeps these spellings OUT of the tiers-completeness / parity-census
  # extractors (both grep quoted string type heads and `t in [...]` literals),
  # because an alias has no tier or golden of its own — it borrows its target's.
  @heading_aliases ~w(h1 h2 h3)
  def compose_block(%{"type" => t} = b, style) when t in @heading_aliases do
    level = String.to_integer(String.trim_leading(t, "h"))
    compose_block(b |> Map.put("type", "heading") |> Map.put("level", level), style)
  end

  def compose_block(%{"type" => t} = b, style) when t == "quote",
    do: compose_block(Map.put(b, "type", "blockquote"), style)

  # Pullquote — italic serif, larger, muted, with a 3px terracotta left-border
  # (mirrors doc.css `.pullquote`) in article mode. The clause is style-INVARIANT:
  # it emits the same PdParagraph with `_role: "pullquote"` in every style, and
  # walk.ex paints the full role treatment (terracotta left-border + sizing) at
  # BOTH `:article` (via the `.bp-role-pullquote` class) and email/default (via
  # inline styles from apply_text_role/4). It does NOT degrade to a bare italic
  # span — the earlier "email drops the border" note was stale.
  def compose_block(%{"type" => "pullquote"} = b, _style) do
    # A real `<p>` in every style — inline spans can't carry the pullquote's
    # vertical margins (email-prose-polish).
    %{
      "kind" => "PdParagraph",
      "_role" => "pullquote",
      "italic" => true,
      "children" => compose_inline_children(paragraph_inline(b))
    }
  end

  # Lists stay semantic in every style. Article mode leaves the resulting
  # PdList/PdListItem frame bare for the paper stylesheet; email/default mode
  # applies its Outlook-safe spacing inline in Walk.
  def compose_block(%{"type" => "list"} = b, _style) do
    ordered = Map.get(b, "ordered") == true

    items =
      Map.get(b, "items", [])
      |> List.wrap()
      |> Enum.map(fn item ->
        %{
          "kind" => "PdListItem",
          "children" => [
            %{
              "kind" => "PdText",
              "children" => compose_inline_children(normalize_list_item(item))
            }
          ]
        }
      end)

    %{"kind" => "PdList", "ordered" => ordered, "children" => items}
  end

  def compose_block(%{"type" => "callout"} = b, style) do
    # Body inline comes from the `body` slot (STEP 3 slot model): the slot's lone
    # paragraph when materialized, else the legacy `content` array — the SAME inline
    # array either way (Slots.callout_body_inline/1), so this composes a byte-
    # identical single PdText. The callout FLATTENS its single-paragraph body slot to
    # INLINE; it never composes the paragraph as a block <p> (that would add a wrapper
    # + 12pt margin and break parity).
    body = %{
      "kind" => "PdText",
      "children" => compose_inline_children(Barkpark.PortableDoc.Slots.callout_body_inline(b))
    }

    tone = Map.get(b, "tone") || "info"

    base =
      %{"kind" => "PdCallout", "tone" => tone, "children" => [body]}
      |> maybe_put("title", Map.get(b, "title"))

    # Collapse is a SCREEN-only affordance: thread collapsible/collapsed ONLY in
    # article mode (and only when `true`) so the email renderer — which shares
    # walk.ex callout/3 — always emits the expanded <div>. Email clients strip
    # <details> and would HIDE the body (the opposite of degrade-to-expanded).
    # Skipping non-true also keeps existing callouts byte-identical at the Pd
    # level, even after a re-save that writes an explicit collapsible:false.
    if style == :article do
      base
      |> maybe_put_true("collapsible", Map.get(b, "collapsible"))
      |> maybe_put_true("collapsed", Map.get(b, "collapsed"))
    else
      base
    end
  end

  def compose_block(%{"type" => "action"} = b, _style) do
    %{
      "kind" => "PdButton",
      "href" => Map.get(b, "href", ""),
      "label" => Map.get(b, "label", ""),
      "priority" => Map.get(b, "priority")
    }
  end

  # STEP-2 LAYOUT ENGINE: a `section` MAY carry an optional `layout` object
  # ({mode, tracks?, gap?, breakpoints?}) + its children MAY carry span/order.
  # `grid_layout/1` is the ONE predicate that gates the grid path across every
  # surface: it returns the layout iff mode=="grid", else nil. The nil branch is
  # `compose_section_stack/2` — the pre-layout body VERBATIM — so the legacy
  # corpus AND every explicit-stack (or malformed-layout) section render
  # byte-identically (the callout maybe_put_true precedent: absence and
  # explicit-stack are indistinguishable at the bytes).
  #
  # SURFACE LEGS of the grid path (style-branched INSIDE this one clause — never a
  # parallel render function):
  #   * :article — the full CSS grid (`section_grid_html/3`): the shared
  #     `.bp-section__grid` class + structural `--bp-tracks`/`--bp-grid-gap` custom
  #     props, painted by paper-surface.css (the :article document DOES embed the
  #     stylesheet — render.ex:143-150).
  #   * :email (every non-:article style) — a DESIGNED inline-safe degrade: the
  #     plain-stack Pd-tree seam (`compose_section_stack/2`) over order-sorted
  #     children. render.ex's :email document embeds NO stylesheet ("Outlook is
  #     the contract", inline-only — render.ex:152-162), so the grid class + inert
  #     `--bp-tracks` custom props would arrive as an unstyled SILENT stack. This
  #     leg stacks the children through the same inline-styled seam the plain stack
  #     uses — NO bp-section__grid/__cell classes, NO custom props — honoring
  #     per-cell `order` (a stable sort, mirroring blocks.go gridBody's CSS-order
  #     reorder; absent/malformed order ≡ 0, source position preserved).
  # The Go TUI (pdrender) renders a REAL adaptive grid (PR #1410, 2026-07-08:
  # tracks/span/order honored, degrading to the stack ONLY below the per-cell width
  # floor) — it does NOT unconditionally collapse grid→stack. Breakpoints beyond
  # the built-in ≤720px 1-col collapse are DATA-carried, honored by that TUI solve.
  def compose_block(%{"type" => "section"} = b, style) do
    case grid_layout(b) do
      nil ->
        compose_section_stack(b, style)

      _layout when style != :article ->
        compose_section_stack(order_children(b), style)

      layout ->
        %{"kind" => "_raw", "html" => section_grid_html(b, layout, style)}
    end
  end

  # Article mode: the doc.css `hr.section` look — a centered "§" glyph
  # straddling a hairline rule (the glyph sits on the warm parchment, masking
  # the rule behind it). Email/default mode: a plain `PdHr`, unchanged.
  def compose_block(%{"type" => "divider"}, :article) do
    %{"kind" => "_raw", "html" => Figures.section_divider_html()}
  end

  def compose_block(%{"type" => "divider"}, _style), do: %{"kind" => "PdHr"}

  # ── diagram / figure blocks (P1 slice 2) ───────────────────────────────────
  # `diagram` emits the canonical paper-article Mermaid figure. Unlike every other
  # block, this clause emits HTML DIRECTLY (a `_raw` Pd-node the walker passes
  # through verbatim) rather than composing to a styled PdText tree — the
  # `<pre class="mermaid">` literal must reach the DOM byte-exact so the engine's
  # `pre.mermaid` selector matches AND the static body_html extractor preserves
  # it. The mermaid source is entity-encoded (& < >) so it round-trips through
  # the extractor and Mermaid decodes it at runtime.
  #
  # In article mode: a bordered, parchment, inset figure card (mirrors doc.css
  # `figure`); the figcaption is muted/italic with a bold "Figure N." run-in.
  # In email/default mode: degrade gracefully — Mermaid never runs in email, so
  # we render the caption then the source as a plain code block.
  def compose_block(%{"type" => "diagram"} = b, style) do
    source = stringish(Map.get(b, "source", ""))
    caption = stringish(Map.get(b, "caption", ""))
    %{"kind" => "_raw", "html" => Figures.diagram_html(source, caption, style)}
  end

  # ── asciicast / terminal-recording blocks ──────────────────────────────────
  # `asciicast` mirrors `diagram` exactly: it emits HTML DIRECTLY (a `_raw`
  # Pd-node) rather than composing to a PdText tree, because the player mount
  # point (`<div class="bp-asciicast" data-cast-src="…">`) must reach the DOM
  # byte-exact so the PaperMermaid hook's `div.bp-asciicast` selector matches at
  # runtime. The cast URL travels in a `data-` attribute through `safe_url` (so
  # only allowlisted schemes survive, attribute-escaped).
  #
  # Article mode: an inline, playable asciinema-player mount inside a figure.
  # Email/default mode: NO player runtime — degrade to a plain link, mirroring
  # how `diagram`'s default clause never triggers the Mermaid engine.
  # `poster` (optional) names the resting frame the player shows before play —
  # an npt timestamp (`"npt:1:23"`) or `"end"`. Unset → the client twins keep
  # their `npt:0:1` default and the emitted mount stays byte-identical.
  def compose_block(%{"type" => "asciicast"} = b, :article) do
    src = stringish(Map.get(b, "src", ""))
    caption = stringish(Map.get(b, "caption", ""))
    poster = b |> Map.get("poster", "") |> stringish() |> String.trim()
    %{"kind" => "_raw", "html" => Figures.asciicast_html(src, caption, poster, :article)}
  end

  def compose_block(%{"type" => "asciicast"} = b, style) do
    src = stringish(Map.get(b, "src", ""))
    caption = stringish(Map.get(b, "caption", ""))
    poster = b |> Map.get("poster", "") |> stringish() |> String.trim()
    %{"kind" => "_raw", "html" => Figures.asciicast_html(src, caption, poster, style)}
  end

  # A curated set of related Papers. Authored refs remain useful in pure/email
  # rendering; the public reader injects fresh published metadata under the
  # transient `_paper_links` key before composition.
  def compose_block(%{"type" => "paper-links"} = b, style) do
    %{"kind" => "_raw", "html" => paper_links_html(b, style)}
  end

  # generic `figure` — wraps a child block + caption. Cheap and clean: compose
  # the child through the normal path, then wrap it in the same figure chrome
  # as `diagram` (caption only, no mermaid). Article mode gets the card; email
  # mode degrades to child + plain caption line.
  def compose_block(%{"type" => "figure"} = b, style) do
    caption = stringish(Map.get(b, "caption", ""))
    child = Map.get(b, "child")

    %{
      "kind" => "_raw",
      "html" => figure_html(child, caption, style)
    }
  end

  # Article mode emits ONE styled `<pre>` code block — monospace, parchment
  # `#f1ede2` background, a 3px terracotta left-border, padding, horizontal
  # scroll — via the `_raw` escape hatch (the value is escaped first). Email /
  # default mode keeps the original per-line inline `<code>` chip stack,
  # byte-identical to before.
  def compose_block(%{"type" => "code"} = b, :article) do
    value = stringish(Map.get(b, "value", ""))
    %{"kind" => "_raw", "html" => Figures.code_block_html(value)}
  end

  def compose_block(%{"type" => "code"} = b, _style) do
    children =
      Map.get(b, "value", "")
      |> String.split("\n")
      |> Enum.map(fn line ->
        %{"kind" => "PdText", "children" => [%{"kind" => "PdInlineCode", "value" => line}]}
      end)

    %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => children}
  end

  # An image block with NO asset (empty / whitespace-only / missing `src`) is editor
  # SCAFFOLDING, not content: post-#1161 every new paper seeds a locked
  # `role: "featured"` image at block 1 (`Content.Papers.Template`) with no src, so a
  # naive `PdImage` src="" renders a broken empty `<img>` and a fresh paper opens
  # looking damaged. Doctrine rule 3 (the canvas placeholder is editor chrome; the
  # public reader shows NOTHING for it): an asset-less image composes to the empty
  # `_raw` node, which the walker passes through as "" — the block is skipped on the
  # public /papers render. An image WITH a real `src` is byte-UNCHANGED (D3 additive:
  # `src`/`alt`/`width`/`height` compose exactly as before).
  def compose_block(%{"type" => "image"} = b, _style) do
    case String.trim(stringish(Map.get(b, "src", ""))) do
      "" ->
        %{"kind" => "_raw", "html" => ""}

      _src ->
        %{"kind" => "PdImage", "src" => Map.get(b, "src", ""), "alt" => Map.get(b, "alt", "")}
        |> maybe_put("width", Map.get(b, "width"))
        |> maybe_put("height", Map.get(b, "height"))
    end
  end

  # ── sheet embed block ──────────────────────────────────────────────────────
  # `"type" => "sheet"` embeds a sheet document by `"ref"`; its `"snapshot"`
  # key holds the cached dense value grid (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`,
  # refreshed by the write-through path in `Barkpark.Content` on every sheet
  # mutation). Composing straight from the snapshot means no DB call — the
  # block renders even with the Sheets plugin off (fresh-install invariant).
  # A block with no snapshot yet (freshly authored, never written through)
  # composes to an empty grid so the walker never crashes.
  def compose_block(%{"type" => "sheet"} = b, _style) do
    snap = Map.get(b, "snapshot") || %{}

    rows =
      case Map.get(snap, "rows") do
        rows when is_list(rows) ->
          Enum.map(rows, fn row -> row |> List.wrap() |> Enum.map(&stringish/1) end)

        _ ->
          []
      end

    pd = %{"kind" => "PdSheet", "rows" => rows}

    pd =
      case Map.get(snap, "head") do
        head when is_list(head) -> Map.put(pd, "head", Enum.map(head, &stringish/1))
        _ -> pd
      end

    pd =
      case Map.get(snap, "col_widths") do
        widths when is_list(widths) ->
          Map.put(pd, "col_widths", Enum.map(widths, &if(is_integer(&1), do: &1, else: 0)))

        _ ->
          pd
      end

    # Merges + styles ride the snapshot into the PdSheet node (M5). The HTML
    # walker honors both; the TUI's pdrender ignores the keys and shows the
    # merged value at its anchor cell, unstyled — values-first fidelity.
    pd =
      case Map.get(snap, "merges") do
        merges when is_list(merges) ->
          valid =
            Enum.filter(merges, fn
              [r, c, rs, cs] ->
                is_integer(r) and is_integer(c) and is_integer(rs) and is_integer(cs) and
                  r >= 0 and c >= 0 and rs >= 1 and cs >= 1

              _ ->
                false
            end)

          if valid == [], do: pd, else: Map.put(pd, "merges", valid)

        _ ->
          pd
      end

    pd =
      case Map.get(snap, "styles") do
        styles when is_map(styles) and map_size(styles) > 0 -> Map.put(pd, "styles", styles)
        _ -> pd
      end

    # A clipped snapshot carries `"truncated"`; ride it into the node so the
    # walker can append its "partial data" note (silent truncation in a paper is
    # decision-hazardous).
    if Map.get(snap, "truncated") == true, do: Map.put(pd, "truncated", true), else: pd
  end

  # ── note-embed transclusion block (![[note]]) ─────────────────────────────
  # `"type" => "embed"` transcludes another note by `"target"` (a human title /
  # slug, resolved like a wikilink target). Composes to a `PdEmbed` node — the
  # walker injects the pre-rendered target HTML from `pal.embeds[target]` (a
  # caller-supplied %{target => rendered_html_string} map; see Papers'
  # resolve_embeds_in_blocks). A missing / blank target still composes — the
  # walker degrades it to the unresolved fallback, never crashing. The renderer
  # stays pure: no DB read here, only the raw `target` carried forward.
  def compose_block(%{"type" => "embed"} = b, _style) do
    %{"kind" => "PdEmbed", "target" => stringish(Map.get(b, "target", ""))}
  end

  def compose_block(%{"type" => "table"} = b, _style) do
    compose_cell = fn cell ->
      cell
      |> table_cell_content()
      |> compose_inline_children()
      |> Enum.map(&to_pd_node_from_inline_child/1)
    end

    compose_row = fn row -> row |> table_row_cells() |> Enum.map(compose_cell) end

    {column_head, record_keys} = table_column_head(b)
    raw_rows = Map.get(b, "rows", []) |> List.wrap()

    declared_head =
      case Map.get(b, "head") do
        nil -> Map.get(b, "header")
        [] -> Map.get(b, "header")
        head -> head
      end

    {declared_head, raw_rows} =
      case {declared_head, raw_rows} do
        {true, [first | rest]} -> {table_row_cells(first), rest}
        pair -> pair
      end

    {legacy_head, body_rows} =
      case raw_rows do
        [%{"header" => true} = row | rest] ->
          {table_row_cells(row), rest}

        [%{"cells" => cells} = row | rest] when is_list(cells) ->
          if cells != [] and Enum.all?(cells, &(is_map(&1) and Map.get(&1, "header") == true)) do
            {table_row_cells(row), rest}
          else
            {nil, raw_rows}
          end

        rows ->
          {nil, rows}
      end

    body_rows =
      if record_keys == [] do
        body_rows
      else
        Enum.map(body_rows, fn row -> Enum.map(record_keys, &Map.get(row, &1, "")) end)
      end

    rows =
      body_rows
      |> Enum.map(compose_row)

    pd = %{"kind" => "PdTable", "rows" => rows}

    head =
      if is_list(declared_head) and declared_head != [],
        do: declared_head,
        else: legacy_head || column_head

    case head do
      nil -> pd
      [] -> pd
      head_row -> Map.put(pd, "head", compose_row.(head_row))
    end
  end

  # ── field-* LEAF blocks (P2.1) ─────────────────────────────────────────────
  # Structured field blocks carry their own `value` (the editable datum) plus a
  # human `label`. View-mode renders a labelled row: a bold label followed by the
  # rendered value. Each clause composes to a PdBox(column) so the fragment is
  # self-contained and walks through the existing renderer with no new PdNode
  # kinds. All values flow through PdText, so they inherit `escape_html` at walk
  # time — no field-* clause emits raw HTML.

  def compose_block(%{"type" => "field-string"} = b, style),
    do: field_row(b, field_value_text(b), style)

  def compose_block(%{"type" => "field-slug"} = b, style),
    do: field_row(b, field_value_text(b), style)

  def compose_block(%{"type" => "field-text"} = b, style),
    do: field_row(b, field_value_text(b), style)

  def compose_block(%{"type" => "field-boolean"} = b, style) do
    field_row(b, if(Map.get(b, "value") == true, do: "Yes", else: "No"), style)
  end

  def compose_block(%{"type" => "field-select"} = b, style) do
    value = Map.get(b, "value")

    label =
      Map.get(b, "options", [])
      |> Enum.find(fn opt -> Map.get(opt, "value") == value end)
      |> case do
        nil -> field_value_text(b)
        opt -> stringish(Map.get(opt, "label", Map.get(opt, "value", "")))
      end

    field_row(b, label, style)
  end

  def compose_block(%{"type" => "field-datetime"} = b, style) do
    field_row(b, format_datetime(Map.get(b, "value", "")), style)
  end

  # field-number (B085): the MISSING numeric field atom. `min`/`max`/`step`
  # are Edit-mode control bounds (E4a, the STUDIO-EDIT surcharge, out of
  # View's scope) — never read here. View renders the formatted `value` (an
  # integer drops its decimal point, `Float.to_string/1` gives the shortest
  # round-trip decimal for a fraction) plus an optional trailing `unit`; an
  # absent/uncoercible value is the field-reference "—" precedent.
  def compose_block(%{"type" => "field-number"} = b, style) do
    field_row(b, field_number_text(b), style)
  end

  def compose_block(%{"type" => "field-color"} = b, :article) do
    hex = field_value_text(b)

    value =
      if hex == "" do
        ~s|<span class="bp-field__none">—</span>|
      else
        ~s|<i class="bp-field__swatch" style="background:#{safe_hex(hex)}"></i>| <>
          ~s|<span class="bp-field__mono">#{Util.escape_html(hex)}</span>|
      end

    field_row_article(b, value)
  end

  def compose_block(%{"type" => "field-color"} = b, _style),
    do: compose_field_color(b, @default_theme)

  # ── field-reference / field-image PICKER blocks (P2.2) ─────────────────────
  # Two field blocks whose Edit-mode control is an existing picker Web Component
  # (bp-reference-picker / bp-media-picker) rather than a native control. The
  # `value` is a plain string in both cases (a referenced doc id for reference;
  # an image URL for image), matching the v1 classic-field persistence model.
  #
  # field-reference View: a labelled row showing the referenced doc's TITLE
  # when it can be resolved, else the raw id, else an em-dash for empty values.
  # The title is resolved by the caller's `:ref_resolver` (see render_block/2)
  # and stashed on the transient `"_ref_title"` key; when no resolver is wired
  # (pure unit tests, no dataset in scope) the key is absent and View falls
  # back to the stored id — a no-fetch rendering of the raw datum.
  def compose_block(%{"type" => "field-reference"} = b, :article) do
    value = field_value_text(b)
    resolved = b |> Map.get("_ref_title", "") |> to_string()

    display =
      cond do
        value == "" -> "—"
        resolved != "" -> resolved
        true -> value
      end

    field_row_article(b, ~s|<span>#{Util.escape_html(display)}</span>|)
  end

  def compose_block(%{"type" => "field-reference"} = b, _style) do
    value = field_value_text(b)
    resolved = b |> Map.get("_ref_title", "") |> to_string()

    display =
      cond do
        value == "" -> "—"
        resolved != "" -> resolved
        true -> value
      end

    field_row(b, display)
  end

  # field-image View: a labelled row with an <img> preview when a URL is set,
  # else a "No image" placeholder. The src is funnelled through PdImage so it
  # inherits the renderer's `safe_url` scheme allowlist; the label stays bold
  # PdText. Empty value → a plain placeholder PdText line.
  def compose_block(%{"type" => "field-image"} = b, :article) do
    src = media_field_url(Map.get(b, "value", ""))

    value =
      if src == "" do
        ~s|<span class="bp-field__none">No image</span>|
      else
        alt = b |> Map.get("label", "") |> stringish()

        ~s|<img class="bp-field__img" src="#{Util.escape_attr(Util.safe_url(src))}" alt="#{Util.escape_attr(alt)}">|
      end

    field_row_article(b, value)
  end

  def compose_block(%{"type" => "field-image"} = b, _style) do
    src = media_field_url(Map.get(b, "value", ""))

    value_node =
      if src == "" do
        %{"kind" => "PdText", "children" => ["No image"]}
      else
        %{"kind" => "PdImage", "src" => src, "alt" => stringish(Map.get(b, "label", ""))}
      end

    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b), value_node]
    }
  end

  # ── v2 COMPOSITE field blocks (P2.3) ──────────────────────────────────────
  # composite / arrayOf / codelist / localizedText carry their field CONFIG
  # inline alongside a structured `value`. The Edit-mode control is the nested
  # `PaperFieldBlock` LiveComponent (server-bound forms); View mode renders a
  # labelled, read-only summary of the stored datum. As with the leaf field-*
  # blocks every value flows through PdText, inheriting escape_html at walk
  # time — no composite clause emits raw HTML.

  # composite → labelled box, one sub-row per subfield (name: stringified value).
  def compose_block(%{"type" => "composite"} = b, :article) do
    value = Map.get(b, "value", %{})
    subfields = Map.get(b, "fields", [])

    rows =
      Enum.map_join(subfields, "", fn sub ->
        name = Map.get(sub, "name", "")
        sub_label = Map.get(sub, "title") || name
        sub_value = composite_scalar(get_in_value(value, name))

        ~s|<div class="bp-field__sub"><b>#{Util.escape_html(stringish(sub_label))}</b><span>#{Util.escape_html(sub_value)}</span></div>|
      end)

    field_row_article(b, rows)
  end

  def compose_block(%{"type" => "composite"} = b, _style) do
    value = Map.get(b, "value", %{})
    subfields = Map.get(b, "fields", [])

    rows =
      Enum.map(subfields, fn sub ->
        name = Map.get(sub, "name", "")
        sub_label = Map.get(sub, "title") || name
        sub_value = composite_scalar(get_in_value(value, name))

        %{
          "kind" => "PdBox",
          "style" => %{"flexDirection" => "row"},
          "children" => [
            %{"kind" => "PdText", "weight" => "bold", "children" => ["#{sub_label}: "]},
            %{"kind" => "PdText", "children" => [sub_value]}
          ]
        }
      end)

    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b) | rows]
    }
  end

  # arrayOf → labelled box, one PdText row per element (stringified).
  def compose_block(%{"type" => "arrayOf"} = b, :article) do
    elements = b |> Map.get("value", []) |> List.wrap()

    value =
      if elements == [] do
        ~s|<span class="bp-field__none">—</span>|
      else
        ~s|<ol class="bp-field__list">| <>
          Enum.map_join(elements, "", fn el ->
            ~s|<li>#{Util.escape_html(composite_scalar(el))}</li>|
          end) <> "</ol>"
      end

    field_row_article(b, value)
  end

  def compose_block(%{"type" => "arrayOf"} = b, _style) do
    elements = Map.get(b, "value", [])

    rows =
      elements
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {el, idx} ->
        %{
          "kind" => "PdBox",
          "style" => %{"flexDirection" => "row"},
          "children" => [
            %{"kind" => "PdText", "children" => ["#{idx + 1}. "]},
            %{"kind" => "PdText", "children" => [composite_scalar(el)]}
          ]
        }
      end)

    rows = if rows == [], do: [%{"kind" => "PdText", "children" => ["—"]}], else: rows

    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b) | rows]
    }
  end

  # codelist → labelled row. The stored value is the selected CODE; View shows
  # the human LABEL when `resolve_code_label/2` stashed one on `"_code_label"`
  # (the caller wired a `:codelist_resolver`), else falls back to the raw code,
  # else an em-dash for an empty/unresolved value. Mirrors the field-reference
  # id→title resolution exactly.
  def compose_block(%{"type" => "codelist"} = b, style) do
    code = field_value_text(b)
    label = b |> Map.get("_code_label", "") |> to_string()

    display =
      cond do
        code == "" -> "—"
        label != "" -> label
        true -> code
      end

    field_row(b, display, style)
  end

  # localizedText → labelled box, one row per language (lang: text).
  def compose_block(%{"type" => "localizedText"} = b, :article) do
    value = Map.get(b, "value", %{})
    languages = Map.get(b, "languages", [])

    rows =
      Enum.map_join(languages, "", fn lang ->
        text = composite_scalar(get_in_value(value, lang))

        ~s|<div class="bp-field__sub"><b>#{Util.escape_html(stringish(lang))}</b><span>#{Util.escape_html(text)}</span></div>|
      end)

    field_row_article(b, rows)
  end

  def compose_block(%{"type" => "localizedText"} = b, _style) do
    value = Map.get(b, "value", %{})
    languages = Map.get(b, "languages", [])

    rows =
      Enum.map(languages, fn lang ->
        text = composite_scalar(get_in_value(value, lang))

        %{
          "kind" => "PdBox",
          "style" => %{"flexDirection" => "row"},
          "children" => [
            %{"kind" => "PdText", "weight" => "bold", "children" => ["#{lang}: "]},
            %{"kind" => "PdText", "children" => [text]}
          ]
        }
      end)

    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b) | rows]
    }
  end

  # ── form block (P4): native grill / questionnaire ─────────────────────────
  # Renders a grill / questionnaire as native portable-doc markup.
  # `"type" => "questionnaire"` is a pure ALIAS of `"type" => "form"` — both
  # land here, differentiated only by the container class (`kind` discriminator,
  # default "grill"). Like the diagram / code clauses this emits HTML DIRECTLY
  # via the `_raw` escape hatch: <fieldset>/<legend>/<input>/<textarea> are not
  # in the PdNode kind set, so they reach the DOM verbatim. The markup is
  # RENDER-ONLY — no <script>, no action/method, no submit wiring (the
  # interactive layer is a later phase). Every user-supplied string flows
  # through escape_html (& < > " ').
  def compose_block(%{"type" => "questionnaire"} = b, style) do
    b |> Map.put("type", "form") |> Map.put_new("kind", "questionnaire") |> compose_block(style)
  end

  def compose_block(%{"type" => "form"} = b, style) do
    %{"kind" => "_raw", "html" => Forms.form_html(b, style)}
  end

  # Task list — the upgraded `bp tasks` list as a paper block. Snapshot-driven
  # (block carries a resolved `snapshot` list, same contract as the sheet embed);
  # the pure emitter lives in Render.Components. `"tasks"` is the canonical type;
  # `"task-list"` is an accepted alias.
  # :article rides the classed Components emitters (paper-surface.css owns the
  # look — byte-locked by canvas_reader_parity_gate). Every other style takes the
  # inline-styled FleetEmail variants (gp-w4a): the `.bp-*` classes + CSS Braille
  # spinner render as unstyled text runs in a stylesheet-less mail client. The
  # /2 `_style` clause defaults to evergreen (the /3 clause above carries theme);
  # a task-list nested inside a `terminal` recurses through render_blocks/2 and
  # thereby gets its EMAIL variant at evergreen (charter D1).
  def compose_block(%{"type" => t} = b, :article) when t in ["tasks", "task-list"] do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.tasks_html(b)}
  end

  def compose_block(%{"type" => t} = b, _style) when t in ["tasks", "task-list"] do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.FleetEmail.tasks_email_html(b)}
  end

  # Task detail — the "open a task and SEE it" card: conditional sections (meta,
  # timeline, criteria+evidence, deps-in-words, children & papers rails). Pure,
  # snapshot-carried (`task` map on the block).
  def compose_block(%{"type" => "task-detail"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.task_detail_html(b)}
  end

  def compose_block(%{"type" => "task-detail"} = b, _style) do
    %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.FleetEmail.task_detail_email_html(b)
    }
  end

  # Task board (kanban by lifecycle) and roadmap (author-dated phase/task bars).
  def compose_block(%{"type" => "task-board"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.task_board_html(b)}
  end

  def compose_block(%{"type" => "task-board"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.FleetEmail.task_board_email_html(b)}
  end

  def compose_block(%{"type" => "roadmap"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.roadmap_html(b)}
  end

  def compose_block(%{"type" => "roadmap"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.FleetEmail.roadmap_email_html(b)}
  end

  # ── Chat tool / todo / thinking rows (charter D25 — dual-surface Law 1) ──────
  #
  # Three first-class chat block types render through the SAME compose_block path
  # the assistant reply body uses (D8), so Studio and the Go TUI (`internal/chat`)
  # decode ONE typed block map. Style-invariant (mono, evergreen tokens — no email
  # variant): a chat row reads the same on any surface. The Components emitters
  # REUSE the pure derivations (`TextDiff.diff_lines/2`, `ChatToolRenderer.
  # {classify,parse_todos,todo_glyph}`) — no diff/parse engine is reinvented.
  def compose_block(%{"type" => "chat-tool-diff"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_tool_diff_html(b)}
  end

  def compose_block(%{"type" => "chat-todo"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_todo_html(b)}
  end

  def compose_block(%{"type" => "chat-thinking"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_thinking_html(b)}
  end

  # The three INTERACTIVE chat cards (charter D35): approval / question / plan as
  # dual-surface block types. The block carries only the read-time VISUAL — the
  # answer path stays on the message ENVELOPE (role+request_id+approval_status),
  # so this `_raw` emitter never draws an answer control.
  def compose_block(%{"type" => "chat-approval"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_approval_html(b)}
  end

  def compose_block(%{"type" => "chat-question"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_question_html(b)}
  end

  def compose_block(%{"type" => "chat-plan"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.chat_plan_html(b)}
  end

  def compose_block(%{"type" => "notes"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.notes_html(b)}
  end

  def compose_block(%{"type" => "notes"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.notes_email_html(b)}
  end

  def compose_block(%{"type" => "cards"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.cards_html(b)}
  end

  def compose_block(%{"type" => "cards"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.cards_email_html(b)}
  end

  # STEP-4 CARD WIDGET — a NEW slots-native block: ONE card (media/title/body/action
  # slots) that a grid `section` holds N of. Its compose clause defines the card's
  # FLATTENING layout contract (the callout precedent): `card_html/1` projects the
  # slots into the legacy per-card chrome (bp-card/__t/__d + tone), byte-aligning to
  # ONE legacy `cards` item — so a section-of-cards renders == a legacy cards grid at
  # item granularity. ADDITIVE: the legacy `cards` clause above is UNTOUCHED.
  def compose_block(%{"type" => "card"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.card_html(b)}
  end

  def compose_block(%{"type" => "card"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.card_email_html(b)}
  end

  # The notes-grid split — a NEW singular `note` :widget: ONE annotated item
  # (label/lead/body slots) that renders byte-identically to ONE legacy `notes`
  # grid item, WITHOUT the `bp-notes` grid wrapper (a lone note is one row; the
  # grid/section owns the wrapper). `note_item_html/1` is the SAME per-item
  # expression `notes_html/1` maps over, so a note byte-aligns to a `notes` row by
  # construction. ADDITIVE: the legacy `notes` clause above is UNTOUCHED.
  def compose_block(%{"type" => "note"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.note_item_html(b)}
  end

  def compose_block(%{"type" => "note"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.note_email_html(b)}
  end

  def compose_block(%{"type" => "pipeline"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.pipeline_html(b)}
  end

  def compose_block(%{"type" => "pipeline"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.pipeline_email_html(b)}
  end

  # STAGE WIDGET — a NEW block: the editable per-node twin of ONE legacy `pipeline`
  # node (kind/title/detail text slots + files/source chrome). `stage_html/1` emits the
  # IDENTICAL pnode cell one pipeline node emits, so a `section` of stages renders ==
  # a legacy pipeline flow at cell granularity. ADDITIVE: the legacy `pipeline` clause
  # above + `pipeline_html/1` are UNTOUCHED (byte-for-byte).
  def compose_block(%{"type" => "stage"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.stage_html(b)}
  end

  def compose_block(%{"type" => "stage"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.CardsEmail.stage_email_html(b)}
  end

  # Terminal chrome — traffic-light title bar (+ optional `live` dot) wrapping
  # any child blocks, with an optional keybind `footer`. Reusable frame; put a
  # task-list inside it and you get the `bp tasks` board look in a paper.
  #
  # :article rides the classed `bp-term` markup (paper-surface.css owns the light
  # look). Every other style takes the inline-styled email variant (PanelsEmail) —
  # the classed chrome is invisible in a stylesheet-less mail client, arriving as
  # unstyled child text. The children are composed at THIS call site (render_blocks
  # threads style only — evergreen-nested, charter D1/D8).
  def compose_block(%{"type" => "terminal"} = b, :article) do
    title = b |> Map.get("title", "") |> stringish() |> Util.escape_html()
    footer = b |> Map.get("footer", "") |> stringish()
    body = b |> container_children() |> render_blocks(:article)

    live =
      if Map.get(b, "live") in [true, "true", "live"],
        do: ~s|<span class="bp-term__live">live</span>|,
        else: ""

    foot =
      if footer == "",
        do: "",
        else: ~s|<div class="bp-term__foot">#{Util.escape_html(footer)}</div>|

    html =
      ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">#{title}</span>#{live}</div><div class="bp-term__body">#{body}</div>#{foot}</div>|

    %{"kind" => "_raw", "html" => html}
  end

  def compose_block(%{"type" => "terminal"} = b, style) do
    body = b |> container_children() |> render_children(style)

    %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.PanelsEmail.terminal_email_html(b, body)
    }
  end

  # Columns — a responsive multi-column layout. `columns` is a list of columns,
  # each a list of blocks; stacks to one column on narrow viewports.
  #
  # :article rides the CSS-grid `bp-cols` markup; email takes the fixed table
  # variant (one td per column, equal widths, no reflow — charter D5). Column
  # children compose at this call site (evergreen-nested).
  def compose_block(%{"type" => "columns"} = b, :article) do
    cols = Map.get(b, "columns") || []
    n = max(length(List.wrap(cols)), 1)

    inner =
      cols
      |> List.wrap()
      |> Enum.map(fn col ->
        ~s|<div class="bp-cols__c">#{render_blocks(List.wrap(col), :article)}</div>|
      end)
      |> Enum.join("")

    %{"kind" => "_raw", "html" => ~s|<div class="bp-cols" style="--bp-cols:#{n}">#{inner}</div>|}
  end

  def compose_block(%{"type" => "columns"} = b, style) do
    %{"kind" => "_raw", "html" => columns_email_html(b, style, @default_theme)}
  end

  def compose_block(%{"type" => "status-legend"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.status_legend_html(b)}
  end

  def compose_block(%{"type" => "status-legend"} = b, _style) do
    %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.PanelsEmail.status_legend_email_html(b)
    }
  end

  # ── data-viz slate (stat / stats / heatmap / chart) ─────────────────────────
  # Browser twins of the TUI creative slate (pdrender stat.go/heatmap.go/
  # chart.go). Pure snapshot emitters in Render.DataViz; `stat-grid` is the
  # accepted alias of `stats` (mirrors the pdrender registry).
  # :article rides the classed/SVG emitters (paper-surface.css owns the look);
  # every other style takes the inline-styled email-safe variants — a classed
  # SVG in a stylesheet-less client paints as black filled blobs.
  def compose_block(%{"type" => "stat"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.stat_html(b)}
  end

  def compose_block(%{"type" => "stat"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.stat_email_html(b)}
  end

  def compose_block(%{"type" => t} = b, :article) when t in ["stats", "stat-grid"] do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.stats_html(b)}
  end

  def compose_block(%{"type" => t} = b, _style) when t in ["stats", "stat-grid"] do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.stats_email_html(b)}
  end

  def compose_block(%{"type" => "heatmap"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.heatmap_html(b)}
  end

  def compose_block(%{"type" => "heatmap"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.heatmap_email_html(b)}
  end

  def compose_block(%{"type" => "chart"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.chart_html(b)}
  end

  def compose_block(%{"type" => "chart"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.chart_email_html(b)}
  end

  # duel / lineage (jdf-bl-historiene-renderer-reconciliation): the jarl figure
  # family — a two-arm comparison table and dated nodes on a line. Both carry
  # THE KILDE LAW: every datum's source ref (commit:|paper:|task:|https://)
  # surfaces as the «kilde» stamp, in :article and email alike.
  def compose_block(%{"type" => "duel"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.duel_html(b)}
  end

  def compose_block(%{"type" => "duel"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.duel_email_html(b)}
  end

  def compose_block(%{"type" => "lineage"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.lineage_html(b)}
  end

  def compose_block(%{"type" => "lineage"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.lineage_email_html(b)}
  end

  # scaffy:add-block-type Tabs MARK:ex-compose-tabs
  # tabs (B052): tabbed panels of child blocks, switched in the browser — I1
  # dual hydration (client.ts + the PaperMermaid-sibling hook in
  # bulldocs.html.heex do the framework-free DOM-scan click wiring; this
  # clause only paints the shell). Each tab's `blocks` recurse through the
  # SAME `render_blocks/2` bridge terminal/columns use. NO-JS DEGRADE = every
  # panel stacked and visible — the server HTML never hides a panel;
  # hydration is what adds `hidden` to every non-active one post-mount.
  # Article: tab strip (role=tablist) + every panel. Email/default: no dead
  # tab strip — stacked panels under a plain label heading (same degrade
  # shape as `code-tabs`). Empty `tabs` composes to "" (the `video`
  # src-less precedent).
  def compose_block(%{"type" => "tabs"} = b, :article) do
    tabs = tab_entries(b)

    if tabs == [] do
      %{"kind" => "_raw", "html" => ""}
    else
      strip =
        tabs
        |> Enum.with_index()
        |> Enum.map_join(fn {t, i} ->
          active_class = if i == 0, do: " bp-tabs__tab--active", else: ""

          ~s(<button type="button" class="bp-tabs__tab#{active_class}" role="tab" ) <>
            ~s(aria-selected="#{i == 0}" data-tab-index="#{i}">#{Util.escape_html(t.label)}</button>)
        end)

      panels =
        tabs
        |> Enum.with_index()
        |> Enum.map_join(fn {t, i} ->
          ~s(<div class="bp-tabs__panel" data-tab-index="#{i}">) <>
            render_blocks(t.blocks, :article) <> ~s(</div>)
        end)

      %{
        "kind" => "_raw",
        "html" =>
          ~s(<div class="bp-tabs"><div class="bp-tabs__strip" role="tablist">#{strip}</div>) <>
            ~s(<div class="bp-tabs__panels">#{panels}</div></div>)
      }
    end
  end

  def compose_block(%{"type" => "tabs"} = b, style) do
    tabs = tab_entries(b)

    if tabs == [] do
      %{"kind" => "_raw", "html" => ""}
    else
      sections =
        Enum.map_join(tabs, fn t ->
          ~s(<div class="bp-tabs__section"><p class="bp-tabs__label">#{Util.escape_html(t.label)}</p>) <>
            render_blocks(t.blocks, style) <> ~s(</div>)
        end)

      %{"kind" => "_raw", "html" => ~s(<div class="bp-tabs">#{sections}</div>)}
    end
  end

  # scaffy:add-block-type CodeTabs MARK:ex-compose-code-tabs
  # code-tabs (B077): one snippet per language, tab-switched in the browser —
  # I1 dual hydration (client.ts + the PaperMermaid-sibling hook in
  # bulldocs.html.heex do the framework-free DOM-scan click wiring; this
  # clause only paints the shell). NO-JS DEGRADE = every panel stacked and
  # visible — the server HTML never hides a panel; hydration is what adds
  # `hidden` to every non-active one post-mount, so a JS-less client (or a
  # client mid-hydration) reads every snippet, never a blank tab. `syncKey`
  # (optional) rides a `data-sync-key` attribute the hook keys a localStorage
  # choice on, so picking "Go" once switches every code-tabs block sharing
  # the key (the "choose npm once" pitch) — inert here, read only client-side.
  # Article: tab strip (role=tablist) + every panel via the SAME
  # Figures.code_block_html/1 the standalone `code` block uses (inline-styled,
  # so it needs no stylesheet — reused verbatim for the email leg too).
  # Email/default: no dead tab strip (nothing would ever switch it) — stacked
  # panels under a plain label heading, matching the `tabs` block's degrade.
  # Empty `tabs` composes to "" (the `video` src-less precedent).
  def compose_block(%{"type" => "code-tabs"} = b, :article) do
    tabs = code_tab_entries(b)

    if tabs == [] do
      %{"kind" => "_raw", "html" => ""}
    else
      sync_attr =
        case b |> Map.get("syncKey", "") |> stringish() do
          "" -> ""
          key -> ~s( data-sync-key="#{Util.escape_attr(key)}")
        end

      strip =
        tabs
        |> Enum.with_index()
        |> Enum.map_join(fn {t, i} ->
          active_class = if i == 0, do: " bp-code-tabs__tab--active", else: ""

          ~s(<button type="button" class="bp-code-tabs__tab#{active_class}" role="tab" ) <>
            ~s(aria-selected="#{i == 0}" data-lang="#{Util.escape_attr(t.language)}">) <>
            ~s(#{Util.escape_html(t.label)}</button>)
        end)

      panels =
        Enum.map_join(tabs, fn t ->
          ~s(<div class="bp-code-tabs__panel" data-lang="#{Util.escape_attr(t.language)}">) <>
            Figures.code_block_html(t.value) <> ~s(</div>)
        end)

      %{
        "kind" => "_raw",
        "html" =>
          ~s(<div class="bp-code-tabs"#{sync_attr}>) <>
            ~s(<div class="bp-code-tabs__strip" role="tablist">#{strip}</div>) <>
            ~s(<div class="bp-code-tabs__panels">#{panels}</div></div>)
      }
    end
  end

  def compose_block(%{"type" => "code-tabs"} = b, _style) do
    tabs = code_tab_entries(b)

    if tabs == [] do
      %{"kind" => "_raw", "html" => ""}
    else
      panels =
        Enum.map_join(tabs, fn t ->
          ~s(<div class="bp-code-tabs__panel">) <>
            ~s(<p class="bp-code-tabs__label">#{Util.escape_html(t.label)}</p>) <>
            Figures.code_block_html(t.value) <> ~s(</div>)
        end)

      %{"kind" => "_raw", "html" => ~s(<div class="bp-code-tabs">#{panels}</div>)}
    end
  end

  # scaffy:add-block-type ApiEndpoint MARK:ex-compose-api-endpoint
  # api-endpoint (B075): endpoint doc card — a method badge + path line, then
  # a params table (name/in/type/required). STATIC across every style (dev &
  # code cost tier, D4): the same `_raw` HTML serves View, article, and email
  # alike — no client JS, no email degrade badge needed. An endpoint with no
  # method and no path composes to "" (the `video` src-less precedent);
  # method/path/param fields all flow through Util.escape_html so an author
  # string can never break out of the wrapper.
  def compose_block(%{"type" => "api-endpoint"} = b, _style) do
    %{"kind" => "_raw", "html" => api_endpoint_html(b)}
  end

  # scaffy:add-block-type Video MARK:ex-compose-video
  # video (B062): plain <video> file block — native browser element, zero
  # client JS. An asset-less video (no `src`) composes to "" (the `image`
  # precedent — editor scaffolding, skipped on the public /papers render).
  # Article gets the real <video controls> render; every other style (email)
  # gets the poster/link degrade badge (the `asciicast` precedent).
  def compose_block(%{"type" => "video"} = b, style) do
    case String.trim(stringish(Map.get(b, "src", ""))) do
      "" ->
        %{"kind" => "_raw", "html" => ""}

      src ->
        poster = b |> Map.get("poster", "") |> stringish() |> String.trim()

        captions =
          case Map.get(b, "captions") do
            l when is_list(l) -> Enum.filter(l, &is_map/1)
            _ -> []
          end

        loop = Map.get(b, "loop") == true

        %{
          "kind" => "_raw",
          "html" => Figures.video_html(src, poster, captions, loop, style)
        }
    end
  end

  # scaffy:add-block-type CriteriaProgress MARK:ex-compose-criteria-progress
  # criteria-progress (B034): acceptance-criteria met/total rolled up per row
  # (or aggregated). Article gets the real proportional-bar render
  # (DataViz.criteria_progress_html); every other style (email) gets the
  # text-summary degrade badge (the `bar-chart`/`chart` precedent — D4).
  def compose_block(%{"type" => "criteria-progress"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.criteria_progress_html(b)}
  end

  def compose_block(%{"type" => "criteria-progress"} = b, _style) do
    %{
      "kind" => "_raw",
      "html" => Barkpark.PortableDoc.Render.DataViz.criteria_progress_email_html(b)
    }
  end

  # scaffy:add-block-type Equation MARK:ex-compose-equation
  # equation (B025): server-side TeX -> MathML, zero client JS. Article gets
  # the real MathML render (Math.equation_html); every other style (email)
  # gets the raw-TeX-source degrade badge (Math.equation_email_html).
  def compose_block(%{"type" => "equation"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Math.equation_html(b)}
  end

  def compose_block(%{"type" => "equation"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Math.equation_email_html(b)}
  end

  # scaffy:add-block-type BarChart MARK:ex-compose-bar-chart
  # bar-chart (B003): horizontal bars for categorical counts. Article gets the
  # real bar render (DataViz.bar_chart_html); every other style (email) gets
  # the text-summary degrade badge (the `chart` precedent — D4).
  def compose_block(%{"type" => "bar-chart"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.bar_chart_html(b)}
  end

  def compose_block(%{"type" => "bar-chart"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.bar_chart_email_html(b)}
  end

  # scaffy:add-block-type Expandable MARK:ex-compose-expandable
  # Starter compose for `expandable`: the block's `text` attr escaped into
  # its bp-expandable wrapper through the `_raw` pre-rendered-HTML hatch
  # (walk.ex passes `_raw` through verbatim — the same hatch ~68 sibling
  # clauses use). Every style gets the same div for now; replace with a real
  # Pd-node composition (see the `callout` clause for the PdCallout exemplar)
  # as the block grows semantics. `text` goes through the tolerant stringish/1
  # and Util.escape_html/1 so a raw API/SDK/CLI mutate can never break out of
  # the wrapper (papers are schemaless — same defense as the catch-all below).
  # A generic collapsible container — the same native-<details> pattern
  # `callout` ships (walk.ex collapsible_callout/3), minus the callout chrome
  # (I0: zero-JS, D9/D7). `open` is honored only in :article (the screen
  # disclosure affordance); every other style (email) ALWAYS renders expanded
  # — email clients don't reliably support interactive <details>, so a reader
  # must see the body regardless (the callout precedent, REAL render D4).
  # Empty (no summary, no children) renders nothing.
  def compose_block(%{"type" => "expandable"} = b, style) do
    summary = stringish(Map.get(b, "summary", ""))
    children = container_children(b)

    html =
      if summary == "" and children == [] do
        ""
      else
        inner = children |> Enum.map(&block_to_html(&1, style)) |> Enum.join()

        open_attr =
          cond do
            style != :article -> " open"
            Map.get(b, "open") == true -> " open"
            true -> ""
          end

        ~s(<details#{open_attr} class="bp-expandable">) <>
          ~s(<summary>#{Util.escape_html(summary)}</summary>) <>
          ~s(<div class="bp-expandable__body">#{inner}</div></details>)
      end

    %{"kind" => "_raw", "html" => html}
  end

  # scaffy:add-block-type Footnote MARK:ex-compose-footnote
  # Starter compose for `footnote`: the block's `text` attr escaped into
  # its bp-footnote wrapper through the `_raw` pre-rendered-HTML hatch
  # (walk.ex passes `_raw` through verbatim — the same hatch ~68 sibling
  # clauses use). Every style gets the same div for now; replace with a real
  # Pd-node composition (see the `callout` clause for the PdCallout exemplar)
  # as the block grows semantics. `text` goes through the tolerant stringish/1
  # and Util.escape_html/1 so a raw API/SDK/CLI mutate can never break out of
  # the wrapper (papers are schemaless — same defense as the catch-all below).
  # A numbered reference apparatus: `notes` is a list of `{id, text}`. Each
  # shown note carries an `id="fn-<id>"` anchor (the backlink target a caller
  # can point an inline marker at); a semantic `<ol>` numbers natively, like
  # `steps`. A note with no text is dropped; empty/missing `notes` renders
  # nothing. Every style gets the same real markup (REAL email render, D4).
  def compose_block(%{"type" => "footnote"} = b, _style) do
    notes = Map.get(b, "notes")

    html =
      if is_list(notes) and notes != [] do
        rows = notes |> Enum.map(&footnote_row_html/1) |> Enum.join()
        if rows == "", do: "", else: ~s(<ol class="bp-footnote">) <> rows <> ~s(</ol>)
      else
        ""
      end

    %{"kind" => "_raw", "html" => html}
  end

  # scaffy:add-block-type Steps MARK:ex-compose-steps
  # Starter compose for `steps`: the block's `text` attr escaped into
  # its bp-steps wrapper through the `_raw` pre-rendered-HTML hatch
  # (walk.ex passes `_raw` through verbatim — the same hatch ~68 sibling
  # clauses use). Every style gets the same div for now; replace with a real
  # Pd-node composition (see the `callout` clause for the PdCallout exemplar)
  # as the block grows semantics. `text` goes through the tolerant stringish/1
  # and Util.escape_html/1 so a raw API/SDK/CLI mutate can never break out of
  # the wrapper (papers are schemaless — same defense as the catch-all below).
  # A numbered procedure: `steps` is a list of `{title, blocks}` — each step's
  # title plus its nested child blocks (recursed the same way `figure`/`card`
  # recurse a single child, via `block_to_html/2`). A semantic `<ol>` carries
  # the numbering natively (no hand-authored "1."/"2." text to keep in sync
  # across surfaces); a step with neither a title nor any blocks contributes
  # nothing. Every style (:article, :email) gets the same real markup — REAL
  # email render, D4.
  def compose_block(%{"type" => "steps"} = b, style) do
    steps = Map.get(b, "steps")

    html =
      if is_list(steps) and steps != [] do
        rows = steps |> Enum.map(&steps_row_html(&1, style)) |> Enum.join()
        if rows == "", do: "", else: ~s(<ol class="bp-steps">) <> rows <> ~s(</ol>)
      else
        ""
      end

    %{"kind" => "_raw", "html" => html}
  end

  # scaffy:add-block-type Toc MARK:ex-compose-toc
  # Starter compose for `toc`: the block's `text` attr escaped into
  # its bp-toc wrapper through the `_raw` pre-rendered-HTML hatch
  # (walk.ex passes `_raw` through verbatim — the same hatch ~68 sibling
  # clauses use). Every style gets the same div for now; replace with a real
  # Pd-node composition (see the `callout` clause for the PdCallout exemplar)
  # as the block grows semantics. `text` goes through the tolerant stringish/1
  # and Util.escape_html/1 so a raw API/SDK/CLI mutate can never break out of
  # the wrapper (papers are schemaless — same defense as the catch-all below).
  # A static, author-supplied outline: `items` is a flat list of
  # {text, level, anchor} — never derived by walking sibling blocks.
  # compose_block/2 dispatches ONE block at a time with no document-wide
  # context, so real heading-derived auto-population is a separate, later
  # change needing a document-level compose pass (not this clause). `depth`
  # caps how many RELATIVE levels show, counted from the shallowest level
  # present (default 2); `numbered` prefixes each item with a hierarchical
  # counter (1, 1.1, 1.2, 2, …). `sticky` is a View-only viewport affordance
  # (position:sticky in article CSS) — dropped for email, where every other
  # attribute renders identically (a REAL list of anchor links, D4).
  def compose_block(%{"type" => "toc"} = b, style) do
    items = toc_items(Map.get(b, "items"))
    depth = toc_depth(Map.get(b, "depth"))

    html =
      if items == [] do
        ""
      else
        numbered = Map.get(b, "numbered") == true
        min_level = items |> Enum.map(& &1.level) |> Enum.min()
        counters = List.duplicate(0, depth + 1)

        {rows, _} =
          Enum.reduce(items, {[], counters}, fn item, {acc, counters} ->
            rel = item.level - min_level + 1

            if rel > depth do
              {acc, counters}
            else
              counters = toc_bump_counters(counters, rel)
              {[toc_row_html(item, rel, numbered, counters) | acc], counters}
            end
          end)

        sticky = style == :article and Map.get(b, "sticky") == true
        nav_class = if sticky, do: "bp-toc bp-toc--sticky", else: "bp-toc"

        ~s(<nav class="#{nav_class}"><ol class="bp-toc__list">) <>
          Enum.join(Enum.reverse(rows)) <> ~s(</ol></nav>)
      end

    %{"kind" => "_raw", "html" => html}
  end

  # scaffy:add-block-type Blockquote MARK:ex-compose-blockquote
  # Blockquote — a semantic, attributed quotation. Distinct from `pullquote`
  # (a styled editorial LEAD-quote paragraph): a blockquote is a plain quoted
  # passage with optional attribution. Born to absorb the 8 live `quote` blocks
  # (aliased above) that agents authored via raw mutate — there was nothing
  # canonical to render them as, so they leaked "Unsupported block" placeholders.
  # Reads its inline body the SAME way paragraph/pullquote do (paragraph_inline/1
  # — a `content` inline array, else a bare `text` string), plus an optional
  # `cite`/`attribution` string. Emits a PdBlockquote node so walk.ex owns the
  # semantic `<blockquote>` (article) / inline-styled `<blockquote>` (email)
  # split and all inline escaping — no `_raw` hand-built HTML. Empty body still
  # yields a real (empty) `<blockquote>`, never a placeholder.
  def compose_block(%{"type" => "blockquote"} = b, _style) do
    %{
      "kind" => "PdBlockquote",
      "children" => compose_inline_children(paragraph_inline(b)),
      "cite" => blockquote_cite(b)
    }
  end

  # scaffy:add-block-type Filetree MARK:ex-compose-filetree
  # `filetree` (W7 grow, charter D78): verbatim tree lines with annotation
  # spans + the optional legend row — Components.filetree_html/1 through the
  # `_raw` pre-rendered-HTML hatch. Style-invariant single clause like
  # chat-tool-diff (inline-token mono rendering reads identically in email).
  def compose_block(%{"type" => "filetree"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.filetree_html(b)}
  end

  # scaffy:add-block-type Diff MARK:ex-compose-diff
  # `diff` (W7 grow, charter D75/D77): the verbatim unified-diff text parsed at
  # render time into the SHARED chat diff-row vocabulary (D76) —
  # Components.diff_html/1 through the `_raw` pre-rendered-HTML hatch.
  # Style-invariant single clause like chat-tool-diff (inline-token mono
  # rendering reads identically in email).
  def compose_block(%{"type" => "diff"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.Components.diff_html(b)}
  end

  def compose_block(%{"type" => "gauge-list"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.gauge_list_html(b)}
  end

  def compose_block(%{"type" => "gauge-list"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.gauge_list_email_html(b)}
  end

  # scaffy:add-block-type Route MARK:ex-compose-route
  # `route` (sport track, 2026-08-17): encoded polyline in `polyline` → a
  # self-contained SVG track shape + meta row (DataViz.route_html/2 — no map
  # tiles, no JS, so reader and email render the identical figure; the article
  # variant reads the accent token, email carries literal hex). TUI twin:
  # internal/pdrender/route.go rasterises the same polyline through the braille
  # canvas.
  def compose_block(%{"type" => "route"} = b, :article) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.route_html(b, :article)}
  end

  def compose_block(%{"type" => "route"} = b, _style) do
    %{"kind" => "_raw", "html" => Barkpark.PortableDoc.Render.DataViz.route_html(b, :email)}
  end

  # Unknown / unregistered block type — degrade gracefully instead of crashing
  # every render surface (Studio paper view crash-loop, Bulldocs ingest 500,
  # every body_html rebuild 500, public /papers reader). Papers are schemaless,
  # so any raw API/SDK/CLI mutate can persist a block type this engine has no
  # clause for; the Go twin routes the same case to a visible fallback
  # (pdrender.go fallbackRenderer). The type is stringished then escape_html'd
  # so a hostile `"<script>"` type can't break out of the placeholder <div>.
  def compose_block(%{"type" => type}, _style) do
    unknown_block_node("Unsupported block: " <> Util.escape_html(stringish(type)))
  end

  # Final catch-all — a typeless map (`%{"text" => …}` with no `"type"`) or a
  # non-map entry (a bare string / number written straight into the blocks
  # array). Today both FunctionClauseError and take down the whole render; a
  # poisoned sibling must not sink its healthy neighbours, so it degrades to the
  # same visible node with an "invalid block" label.
  def compose_block(_other, _style) do
    unknown_block_node("invalid block")
  end

  # A `_raw` degrade node the walker passes through verbatim (walk.ex `_raw`
  # clause). `label` is already escaped/literal at every call site.
  defp unknown_block_node(label) do
    %{"kind" => "_raw", "html" => ~s(<div class="bp-unknown-block">) <> label <> "</div>"}
  end

  # api-endpoint (B075) helpers — method badge + path + params table.
  defp api_endpoint_html(b) do
    method = b |> Map.get("method", "") |> stringish() |> String.upcase()
    path = b |> Map.get("path", "") |> stringish()

    if method == "" and path == "" do
      ""
    else
      head =
        ~s(<div class="bp-api-endpoint__head">) <>
          ~s(<span class="#{api_endpoint_method_class(method)}">#{Util.escape_html(method)}</span>) <>
          ~s(<code class="bp-api-endpoint__path">#{Util.escape_html(path)}</code>) <>
          ~s(</div>)

      ~s(<div class="bp-api-endpoint">) <> head <> api_endpoint_params_html(b) <> ~s(</div>)
    end
  end

  # Fail-closed class for the method badge. `method` is user-controlled, so the
  # modifier token is a lowercase [a-z0-9-] slug (never plain-escaped — that
  # would leak &quot;-laden junk into the class attribute). The hyphen is kept
  # so real IANA methods (VERSION-CONTROL, BASELINE-CONTROL) survive as
  # version-control / baseline-control. Every stripped char just vanishes, so a
  # `"><img …>` breakout collapses to an inert token and cannot escape the
  # attribute. An empty slug (blank/all-stripped method) omits the modifier —
  # base class only. Byte-identical to the old `--<downcase>` form for every
  # legit HTTP method (POST → bp-api-endpoint__method--post).
  defp api_endpoint_method_class(method) do
    slug = method |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "")

    case slug do
      "" -> "bp-api-endpoint__method"
      s -> "bp-api-endpoint__method bp-api-endpoint__method--" <> s
    end
  end

  defp api_endpoint_params_html(b) do
    params = Map.get(b, "params", []) |> List.wrap()

    if params == [] do
      ""
    else
      rows = params |> Enum.map(&api_endpoint_param_row_html/1) |> Enum.join()

      ~s(<table class="bp-api-endpoint__params">) <>
        ~s(<thead><tr><th>Name</th><th>In</th><th>Type</th><th>Required</th></tr></thead>) <>
        ~s(<tbody>#{rows}</tbody></table>)
    end
  end

  defp api_endpoint_param_row_html(param) when is_map(param) do
    name = param |> Map.get("name", "") |> stringish()
    in_ = param |> Map.get("in", "") |> stringish()
    type = param |> Map.get("type", "") |> stringish()
    required = api_endpoint_required?(Map.get(param, "required"))

    ~s(<tr><td>#{Util.escape_html(name)}</td><td>#{Util.escape_html(in_)}</td>) <>
      ~s(<td>#{Util.escape_html(type)}</td><td>#{if required, do: "Yes", else: "No"}</td></tr>)
  end

  defp api_endpoint_param_row_html(_), do: ""

  defp api_endpoint_required?(true), do: true

  defp api_endpoint_required?(v) when is_binary(v),
    do: String.downcase(String.trim(v)) == "true"

  defp api_endpoint_required?(_), do: false

  # Clamp a heading level to 1..3; default to 2 when absent/out of range.
  defp heading_level(l) when l in [1, 2, 3], do: l
  defp heading_level("1"), do: 1
  defp heading_level("2"), do: 2
  defp heading_level("3"), do: 3
  defp heading_level(_), do: 2

  # Inline source for text-bearing prose blocks (paragraph / ingress / pullquote):
  # prefer the `content` inline-node array, fall back to a bare `text` string
  # (heading-style authoring — the shape the repo's own tests and the Hollow
  # publish predicate already treat as content, but which used to render as an
  # EMPTY <p> because these clauses read `content` only). compose_inline_children/1
  # accepts either a list OR a bare string, so this is STRICTLY ADDITIVE at the
  # Pd-tree level:
  #   * a non-empty `content` array composes byte-identically to before;
  #   * an empty/absent `content` with NON-BLANK `text` now yields that text
  #     (the previously-empty case that gains output — the whole bugfix);
  #   * an empty/absent `content` with no usable `text` returns [] exactly as
  #     `compose_inline_children([])` did, so the fresh-paper empty `tpl-body`
  #     paragraph and every other empty scaffold stay byte-identical.
  # The `text` branch requires a non-blank BINARY so a non-string `text` (map /
  # list a raw mutate may persist) falls through to [] rather than being coerced.
  defp paragraph_inline(b) do
    case Map.get(b, "content") do
      list when is_list(list) and list != [] ->
        list

      _ ->
        case Map.get(b, "text") do
          text when is_binary(text) and text != "" -> text
          _ -> []
        end
    end
  end

  # Fail-soft leaf coercion for AUTHOR-CONTROLLED block fields (text / caption /
  # src / value / label / byline & sheet cells …). Binaries pass through and
  # numbers/atoms (incl. booleans) stringify exactly as `to_string/1` did, so
  # every working document is byte-identical; a JSON object or array — which
  # `to_string/1` would 500 on (Protocol.UndefinedError) or mis-render as a
  # charlist — degrades to "" rather than crashing the public reader. Mirrors
  # the non-binary fail-soft already sealed in `Render.Util.escape_html/1`.
  defp stringish(v) when is_binary(v), do: v
  defp stringish(nil), do: ""
  defp stringish(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp stringish(_), do: ""

  # ── footnote helpers ─────────────────────────────────────────────────────
  defp footnote_row_html(%{} = note) do
    text = stringish(Map.get(note, "text", ""))

    if text == "" do
      ""
    else
      id = stringish(Map.get(note, "id", ""))
      id_attr = if id == "", do: "", else: ~s( id="fn-#{Util.escape_html(id)}")
      ~s(<li#{id_attr} class="bp-footnote__note">) <> Util.escape_html(text) <> ~s(</li>)
    end
  end

  defp footnote_row_html(_), do: ""

  # ── steps helpers ────────────────────────────────────────────────────────
  defp steps_row_html(%{} = step, style) do
    title = stringish(Map.get(step, "title", ""))
    blocks = container_children(step)

    if title == "" and blocks == [] do
      ""
    else
      body = blocks |> Enum.map(&block_to_html(&1, style)) |> Enum.join()

      title_html =
        if title == "",
          do: "",
          else: ~s(<div class="bp-steps__title">) <> Util.escape_html(title) <> ~s(</div>)

      ~s(<li class="bp-steps__step">) <>
        title_html <> ~s(<div class="bp-steps__body">) <> body <> ~s(</div></li>)
    end
  end

  defp steps_row_html(_, _style), do: ""

  # ── toc helpers ──────────────────────────────────────────────────────────
  # `toc_items/1` normalizes the authored outline: text-less entries are
  # dropped (an item with no label renders nothing worth linking to).
  defp toc_items(items) when is_list(items) do
    items
    |> Enum.map(fn
      %{} = it ->
        text = stringish(Map.get(it, "text", ""))

        if text == "" do
          nil
        else
          %{
            text: text,
            level: toc_level(Map.get(it, "level")),
            anchor: stringish(Map.get(it, "anchor", ""))
          }
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp toc_items(_), do: []

  defp toc_level(level) when is_integer(level) and level > 0, do: level

  defp toc_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp toc_level(_), do: 1

  defp toc_depth(depth) when is_integer(depth) and depth > 0, do: depth
  defp toc_depth(_), do: 2

  # Bumps the counter at `rel` (1-indexed) and resets every deeper counter —
  # the hierarchical-numbering invariant ("1.2" never survives past its "2").
  defp toc_bump_counters(counters, rel) do
    counters
    |> List.update_at(rel, &(&1 + 1))
    |> Enum.with_index()
    |> Enum.map(fn {c, idx} -> if idx > rel, do: 0, else: c end)
  end

  defp toc_row_html(item, rel, numbered, counters) do
    label =
      if numbered do
        num = counters |> Enum.slice(1..rel) |> Enum.join(".")
        num <> ". " <> Util.escape_html(item.text)
      else
        Util.escape_html(item.text)
      end

    inner =
      if item.anchor != "" do
        ~s(<a href="##{Util.escape_html(item.anchor)}">) <> label <> ~s(</a>)
      else
        label
      end

    ~s(<li class="bp-toc__item" data-level="#{rel}">) <> inner <> ~s(</li>)
  end

  # Optional attribution for a blockquote — `cite` preferred, `attribution` the
  # accepted alias. A non-blank BINARY only: a non-string cite (a raw mutate may
  # persist a map/number) or a blank string falls through to nil so walk.ex omits
  # the `<cite>` entirely rather than painting an empty attribution.
  defp blockquote_cite(b) do
    case Map.get(b, "cite") || Map.get(b, "attribution") do
      s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
      _ -> nil
    end
  end

  # Normalize ONE list item. Canonical items are inline-node arrays (or a bare
  # scalar) and pass through untouched. But the drifted list variants aliased
  # onto `list` (bullet_list especially) persisted their items as JSON-ENCODED
  # STRINGS — `~s([{"type":"text","value":"…"}])` — via raw mutate; left as-is
  # those render the literal JSON as text. If a string item parses as a JSON
  # array of inline-node maps, decode it to that array; otherwise keep the string
  # verbatim (a plain-text item stays plain text). Backward-compatible: non-binary
  # items and non-JSON strings are returned unchanged, so canonical lists (and
  # the golden fixture) are byte-identical.
  defp normalize_list_item(item) when is_binary(item) do
    case Jason.decode(item) do
      {:ok, [%{} | _] = nodes} -> nodes
      _ -> item
    end
  end

  defp normalize_list_item(%{} = item), do: paragraph_inline(item)
  defp normalize_list_item(item), do: item

  defp table_row_cells(%{"cells" => cells}) when is_list(cells), do: cells
  defp table_row_cells(row), do: List.wrap(row)

  defp table_cell_content(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "paragraph", "content" => inline} when is_list(inline) -> inline
      item -> [item]
    end)
  end

  defp table_cell_content(%{"text" => text}) when is_binary(text), do: text

  defp table_cell_content(cell), do: cell

  defp table_column_head(%{"columns" => columns}) when is_list(columns) and columns != [] do
    cond do
      Enum.all?(columns, fn
        %{"text" => text} -> is_binary(text)
        _ -> false
      end) ->
        {Enum.map(columns, &Map.get(&1, "text")), []}

      Enum.all?(columns, &(is_binary(&1) or is_number(&1) or is_boolean(&1) or is_nil(&1))) ->
        {Enum.map(columns, &stringish/1), []}

      true ->
        keys =
          if Enum.all?(columns, &is_map/1),
            do: Enum.map(columns, &Map.get(&1, "key")),
            else: []

        if Enum.all?(keys, &(is_binary(&1) and &1 != "")) do
          head = Enum.map(columns, &(Map.get(&1, "label") || Map.get(&1, "key")))
          {head, keys}
        else
          {nil, []}
        end
    end
  end

  defp table_column_head(_), do: {nil, []}

  # A labelled value row: bold label on its own line, then the value as PdText.
  defp field_row(b, value_text) when is_binary(value_text) do
    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b), %{"kind" => "PdText", "children" => [value_text]}]
    }
  end

  # Style-aware field row: the :article render is the TUI-parity DEFINITION
  # ROW — a dim mono label column beside the value (bp-field grid, gui-premium
  # w2); every other style keeps the PdBox label-over-value stack (email has
  # no stylesheet, so classes would render unstyled there).
  defp field_row(b, value_text, :article) when is_binary(value_text) do
    display = if String.trim(value_text) == "", do: "—", else: value_text
    field_row_article(b, ~s|<span>#{Util.escape_html(display)}</span>|)
  end

  defp field_row(b, value_text, _style), do: field_row(b, value_text)

  # value_html is PRE-ESCAPED by every caller (author strings flow through
  # escape_html / escape_attr / safe_hex / safe_url before they reach here).
  defp field_row_article(b, value_html) do
    label = b |> Map.get("label", "") |> stringish()

    %{
      "kind" => "_raw",
      "html" =>
        ~s|<div class="bp-field"><span class="bp-field__l">#{Util.escape_html(label)}</span><div class="bp-field__v">#{value_html}</div></div>|
    }
  end

  defp field_label_node(b) do
    %{"kind" => "PdText", "weight" => "bold", "children" => [stringish(Map.get(b, "label", ""))]}
  end

  defp field_value_text(b), do: stringish(Map.get(b, "value", ""))

  # field-number (B085) value text: the formatted number + optional unit
  # suffix, or "—" for an absent/uncoercible value (the field-reference
  # empty-value precedent).
  defp field_number_text(b) do
    case field_number_value(Map.get(b, "value")) do
      nil -> "—"
      n -> format_field_number(n) <> field_number_unit_suffix(b)
    end
  end

  defp field_number_value(n) when is_number(n), do: n

  defp field_number_value(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp field_number_value(_), do: nil

  defp format_field_number(n) when is_integer(n), do: Integer.to_string(n)

  defp format_field_number(n) when is_float(n) do
    if n == Float.round(n, 0) do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end

  defp field_number_unit_suffix(b) do
    case b |> Map.get("unit", "") |> stringish() |> String.trim() do
      "" -> ""
      unit -> " " <> unit
    end
  end

  # field-color swatch (non-article). The swatch BORDER is the one baked colour
  # compose emits (was the compile-time @rule); it now resolves per theme
  # (charter D28). Evergreen keeps the byte-exact email rule.
  defp compose_field_color(b, theme) do
    hex = field_value_text(b)
    # A swatch (PdBox with a backgroundColor + border) beside the hex string.
    # The swatch background only takes the value when it's a strict #rrggbb /
    # #rgb hex — never an arbitrary string — so it can't break out of the inline
    # style attribute (the hex text itself is still escaped at PdText walk time).
    swatch = %{
      "kind" => "PdBox",
      "style" => %{
        "width" => 16,
        "height" => 16,
        "backgroundColor" => safe_hex(hex),
        "borderWidth" => 1,
        "borderColor" => Barkpark.PortableDoc.Render.Palettes.rule(theme),
        "borderStyle" => "single"
      },
      "children" => []
    }

    value_row = %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "row"},
      "children" => [swatch, %{"kind" => "PdText", "children" => [hex]}]
    }

    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b), value_row]
    }
  end

  # Image fields may store a bare URL (v1) or JSON `{"url","assetId"}` (v2).
  defp media_field_url(v) when is_binary(v) do
    trimmed = String.trim(v)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, %{"url" => url}} when is_binary(url) and url != "" -> url
        _ -> trimmed
      end
    else
      trimmed
    end
  end

  defp media_field_url(v), do: stringish(v || "")

  # Flatten a composite/array/localized sub-value to a single display string.
  # Maps and lists are rendered as compact, escaped summaries (the full
  # structured edit lives in the PaperFieldBlock LiveComponent); scalars pass
  # through to_string. nil → an em-dash so empty slots read as empty.
  defp composite_scalar(nil), do: "—"
  defp composite_scalar(v) when is_binary(v), do: v
  defp composite_scalar(v) when is_number(v), do: to_string(v)
  defp composite_scalar(true), do: "Yes"
  defp composite_scalar(false), do: "No"

  defp composite_scalar(v) when is_list(v) do
    v |> Enum.map_join(", ", &composite_scalar/1)
  end

  defp composite_scalar(v) when is_map(v) do
    v
    |> Enum.map_join(", ", fn {k, val} -> "#{k}: #{composite_scalar(val)}" end)
  end

  defp composite_scalar(v), do: to_string(v)

  # Read a value out of a possibly-stringy/atomy map by string key.
  defp get_in_value(map, key) when is_map(map) do
    Map.get(map, to_string(key), Map.get(map, key))
  end

  defp get_in_value(_, _), do: nil

  @hex_re ~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/
  # Only a strict hex literal may reach the inline style attribute; otherwise
  # fall back to a transparent swatch so a hostile `value` can't inject CSS.
  defp safe_hex(v) when is_binary(v) do
    if Regex.match?(@hex_re, v), do: v, else: "transparent"
  end

  defp safe_hex(_), do: "transparent"

  # datetime-local strings ("2026-05-24T10:00") render with the 'T' replaced by
  # a space for readability; anything else passes through escaped as-is.
  defp format_datetime(v) when is_binary(v), do: String.replace(v, "T", " ")
  defp format_datetime(v), do: stringish(v)

  # Put `key => value` only when value is not nil (the conditional-spread idiom,
  # e.g. `...(title !== undefined ? {title} : {})`).
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Like maybe_put but writes ONLY when the value is exactly `true` — so a
  # boolean attr's absence and an explicit `false` render identically (an
  # un-folded callout stays byte-identical even after a re-save).
  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _value), do: map

  # tabs (B052) entries: {label, blocks} objects off the `tabs` array,
  # non-object entries dropped. `blocks` stays a raw list — render_blocks/2
  # (called at each compose_block/2 leg, article/email) does the recursion.
  defp tab_entries(b) do
    b
    |> Map.get("tabs", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn t ->
      %{
        label: t |> Map.get("label", "") |> stringish(),
        blocks: t |> Map.get("blocks", []) |> List.wrap()
      }
    end)
  end

  # code-tabs (B077) tab entries: {label, language, value} objects off the
  # `tabs` array, non-object entries dropped. `value` is the documented field
  # name; `code` is tolerated too (the standalone `code` block's own
  # value||code duality — a raw mutate authored either shape).
  defp code_tab_entries(b) do
    b
    |> Map.get("tabs", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn t ->
      %{
        label: t |> Map.get("label", "") |> stringish(),
        language: t |> Map.get("language", "") |> stringish(),
        value: stringish(Map.get(t, "value") || Map.get(t, "code", ""))
      }
    end)
  end

  # ── generic figure HTML emission (compose + walk bridge) ───────────────────
  # Generic figure: a composed child block + caption. nil child → caption only.
  # This is the ONE compose helper that recurses through walk — it composes the
  # child block then renders it to a body fragment via `Render.Walk.render_body`
  # (the `doctype: false` body twin of `render_html`).
  # Render a list of child blocks to a concatenated HTML fragment — the same
  # compose→walk bridge `figure_html/3` uses, for container blocks (terminal /
  # columns) that hold arbitrary other blocks.
  defp render_blocks(blocks, style) when is_list(blocks) do
    blocks |> Enum.map(&block_to_html(&1, style)) |> Enum.join("")
  end

  defp render_blocks(_, _), do: ""

  @doc """
  Public compose→walk bridge for a slot's child blocks — the SAME
  `render_blocks/2` helper terminal/columns/section use, exposed so the
  slots-native widget emitters in `Render.Components` (model-B `card_html/2`)
  can recurse ARBITRARY element children through the one composer instead of
  hand-building per-slot chrome. Each child is `compose_block`'d then walked to
  a body fragment; an `image` child fast-paths to a `PdImage` `<img>`, an
  `action` child to a `PdButton` link — no card-specific media/action code.
  """
  def render_children(blocks, style \\ :email)
  def render_children(blocks, style) when is_list(blocks), do: render_blocks(blocks, style)
  def render_children(_, _), do: ""

  # columns email variant — composes each column's children at the call site
  # (evergreen-nested, style-only) then hands the list of ready column fragments
  # to PanelsEmail. `theme` themes nothing today (columns have no chrome colour),
  # carried for signature symmetry with terminal / status-legend.
  defp columns_email_html(b, style, theme) do
    cols_html =
      b
      |> Map.get("columns")
      |> List.wrap()
      |> Enum.map(fn col -> render_children(List.wrap(col), style) end)

    Barkpark.PortableDoc.Render.PanelsEmail.columns_email_html(cols_html, theme)
  end

  # ── section layout engine (step 2) ─────────────────────────────────────────
  #
  # The pre-layout section body — the ONLY path the legacy corpus and every
  # explicit-stack section ever reaches (grid_layout gates on mode=="grid" only).
  # Extracted VERBATIM from the old `section` clause: leading PdHr, optional
  # bold-title PdText, inner children via compose_block, trailing PdHr, wrapped in
  # a flex-column PdBox. BYTE-IDENTICAL to the pre-layout engine.
  defp compose_section_stack(b, style) do
    leading = [%{"kind" => "PdHr"}]

    title =
      case Map.get(b, "title") do
        nil -> []
        t -> [%{"kind" => "PdText", "weight" => "bold", "children" => [t]}]
      end

    inner = Enum.map(Map.get(b, "blocks", []), &compose_block(&1, style))

    children = leading ++ title ++ inner ++ [%{"kind" => "PdHr"}]
    box = %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => children}

    # Section-frame hook (charter D19): variant=="framed" stamps a top-level
    # "class" on the PdBox — a FIXED literal, never interpolated author data.
    # Emission is the walker's call (box_class_attr): :article only + whitelist,
    # so the email leg stays byte-identical and an unknown variant fail-softs
    # to the exact unclassed bytes above.
    case Map.get(b, "variant") do
      "framed" -> Map.put(box, "class", "bp-section--framed")
      _ -> box
    end
  end

  # EMAIL-DEGRADE helper — stable-sort a grid section's `blocks` by their CSS
  # `order` so the inline-safe stack (compose_section_stack) honors placement the
  # SAME way the :article reader's `order:` on the cell does. Mirrors blocks.go
  # `gridBody`'s `sort.SliceStable(items, cellOrder)`: absent/malformed order ≡ 0
  # (order_int → nil → 0) and Enum.sort_by is stable, so equal-order children keep
  # their source position. Returns `b` with only `blocks` reordered — span/order
  # keys ride along on each child but are inert in the stack (the child's own
  # compose ignores them; only `section_grid_html`'s cell wrapper reads them), so
  # NO custom props leak into the email bytes.
  defp order_children(b) do
    ordered =
      b
      |> Map.get("blocks", [])
      |> List.wrap()
      |> Enum.sort_by(&cell_order/1)

    Map.put(b, "blocks", ordered)
  end

  defp cell_order(child) when is_map(child), do: order_int(Map.get(child, "order")) || 0
  defp cell_order(_), do: 0

  # `grid_layout/1` — the ONE predicate gating the grid path everywhere. Returns
  # the layout object iff its `mode` is exactly "grid"; ANY other shape (absent,
  # null, a non-map layout, or a non-"grid" mode such as an explicit
  # {"mode":"stack"}) → nil → the stack path. Pattern-matching keeps it fail-soft:
  # a malformed non-map `layout` value can never raise here.
  defp grid_layout(%{"layout" => %{"mode" => "grid"} = layout}), do: layout
  defp grid_layout(_), do: nil

  # The grid section render: a `_raw` HTML node the walker passes through
  # verbatim. Shape mirrors the stack reader's chrome (leading rule, optional
  # bold title, trailing rule) but lays the children into a CSS grid painted by
  # the SHARED `.bp-section__grid` class (paper-surface.css) — the reader adds no
  # inline pixels, only the structural `--bp-tracks` count + a `--bp-grid-gap`
  # token VAR (never px — D2). Each child renders through its own emitter via the
  # `render_blocks/2` compose→walk bridge (the same bridge columns/terminal use).
  #
  # STEP-6: span/order are now RENDERED here as a present-only per-child style on
  # the `.bp-section__cell` wrapper (`grid-column:span N;order:K`). A child with
  # NEITHER key emits a bare `<div class="bp-section__cell">`, byte-identical to the
  # pre-step-6 grid HTML (so a grid section with no cells still renders byte-for-byte
  # unchanged — the frozen no-cells tripwire locks it). span/order are INT-validated
  # (cell_layout_attr → span_int/order_int) so a malformed value falls safe (no style
  # injection, D2: no px, only structural ints).
  #
  # SURFACE NOTE: this `_raw` grid HTML is the :article leg ONLY — it needs the
  # paper-surface.css `.bp-section__grid` rules to lay out, which the :article
  # document embeds. The :email leg degrades to an inline-safe ORDERED stack (the
  # section clause above), since Outlook strips the stylesheet this markup needs.
  # The Go TUI (pdrender) renders a REAL adaptive grid (PR #1410: tracks/span/order
  # honored, degrading to the stack only below the per-cell width floor) — it does
  # NOT unconditionally collapse grid→stack. Web (portable-doc.tsx) still ignores
  # section layout entirely — a filed follow-on (cd-11), not this step.
  defp section_grid_html(b, layout, style) do
    tracks = grid_tracks(Map.get(layout, "tracks"))
    gap = gap_token_var(Map.get(layout, "gap"))

    title_html =
      case Map.get(b, "title") do
        nil ->
          ""

        t ->
          ~s(<div class="bp-section__title" style="font-weight:bold">) <>
            Util.escape_html(stringish(t)) <> "</div>"
      end

    cells =
      Map.get(b, "blocks", [])
      |> List.wrap()
      |> Enum.map(fn child ->
        ~s(<div class="bp-section__cell"#{cell_layout_attr(child)}>) <>
          render_blocks([child], style) <> "</div>"
      end)
      |> Enum.join("")

    hr = ~s(<hr class="bp-hr">)

    ~s(<div#{section_frame_class_attr(b, style)} style="display:flex;flex-direction:column">) <>
      hr <>
      title_html <>
      ~s(<div class="bp-section__grid" style="--bp-tracks:#{tracks};--bp-grid-gap:#{gap}">) <>
      cells <>
      "</div>" <>
      hr <>
      "</div>"
  end

  # GRID leg of the section-frame hook (charter D19): the same FIXED-literal
  # class inline on the grid wrapper — this `_raw` HTML never passes the
  # walker's box/3, so the class is stamped here. `section_grid_html` is only
  # reached in :article mode today (the email leg degrades to the ordered
  # stack above), but the explicit :article gate keeps the email suppression
  # a stated invariant rather than a positional accident. Unknown variants
  # fall to "" — byte-identical to the pre-hook wrapper.
  defp section_frame_class_attr(%{"variant" => "framed"}, :article),
    do: ~s( class="bp-section--framed")

  defp section_frame_class_attr(_b, _style), do: ""

  # tracks → a positive integer column count (structural, NOT a pixel). Default 2
  # (matches the CSS `repeat(var(--bp-tracks,2),…)` fallback). Accepts an int or a
  # stringy int; anything else falls to 2.
  defp grid_tracks(n) when is_integer(n) and n > 0, do: n

  defp grid_tracks(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> 2
    end
  end

  defp grid_tracks(_), do: 2

  # STEP-6 per-child placement. Emits a PRESENT-ONLY ` style="…"` attr for a grid
  # cell: `grid-column:span N` (span, positive int) and/or `order:K` (order, any
  # int). A child carrying NEITHER → "" (the wrapper stays byte-identical to the
  # pre-step-6 grid HTML). Parts are built order-then-span so the joined style is
  # deterministically `grid-column:span N;order:K`. INT-VALIDATED (span_int/order_int)
  # so a malformed value (a stringy `"2;background:url(x)"`, 0/neg span, non-int) is
  # DROPPED — no style injection, D2: only structural ints, never a px literal.
  defp cell_layout_attr(child) when is_map(child) do
    parts =
      []
      |> put_order(Map.get(child, "order"))
      |> put_span(Map.get(child, "span"))

    case parts do
      [] -> ""
      ps -> ~s( style="#{Enum.join(ps, ";")}")
    end
  end

  defp cell_layout_attr(_), do: ""

  # span → `grid-column:span N` (positive int only; mirrors grid_tracks's guard but
  # DROPS instead of defaulting). Prepends so span lands FIRST in the joined style.
  defp put_span(parts, span) do
    case span_int(span) do
      nil -> parts
      n -> ["grid-column:span #{n}" | parts]
    end
  end

  # order → `order:K` (ANY int — 0 and negatives are legal CSS `order`).
  defp put_order(parts, order) do
    case order_int(order) do
      nil -> parts
      k -> ["order:#{k}" | parts]
    end
  end

  # A positive int, or a stringy positive int (the WHOLE string must parse — a
  # trailing `;background:url(x)` fails Integer.parse's "" remainder guard), else nil.
  defp span_int(n) when is_integer(n) and n > 0, do: n

  defp span_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp span_int(_), do: nil

  # Any int (0/negative legal), or a stringy int (whole-string), else nil.
  defp order_int(n) when is_integer(n), do: n

  defp order_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp order_int(_), do: nil

  # gap TOKEN name → a CSS custom-property reference (never a px literal — D2).
  # The token vocabulary (none|sm|md|lg) is defined ONCE here + mirrored as the
  # CSS `--bp-space-*` var defaults (paper-surface.css) so reader and canvas
  # resolve gaps identically. Default (absent / unknown) → md.
  defp gap_token_var("none"), do: "var(--bp-space-none,0)"
  defp gap_token_var("sm"), do: "var(--bp-space-sm,0.8rem)"
  defp gap_token_var("md"), do: "var(--bp-space-md,1.6rem)"
  defp gap_token_var("lg"), do: "var(--bp-space-lg,2.4rem)"
  defp gap_token_var(_), do: "var(--bp-space-md,1.6rem)"

  defp block_to_html(child, style) when is_map(child) do
    composed = compose_block(child, style)
    pal = Barkpark.PortableDoc.Render.Palettes.palette_for(style)
    Walk.render_body(composed, Map.fetch!(pal, :width), pal)
  end

  defp block_to_html(_, _), do: ""

  defp paper_links_html(block, style) do
    resolved = Map.get(block, "_paper_links", %{})
    reasons = Map.get(block, "reasons", %{})

    cards =
      block
      |> Map.get("refs", [])
      |> List.wrap()
      |> Enum.map(&paper_link_ref(&1, resolved, reasons))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(&paper_link_card(&1, style))

    if cards == "" do
      ""
    else
      title = nonblank(Map.get(block, "title")) || "Explore the work"
      description = nonblank(Map.get(block, "description"))

      intro =
        if description,
          do:
            ~s|<p style="margin:0.45rem 0 0;color:var(--paper-ink-soft, #55635e);line-height:1.6">#{Util.escape_html(description)}</p>|,
          else: ""

      ~s|<section data-paper-links aria-label="#{Util.escape_attr(title)}" style="margin:2.8rem 0 0;padding-top:1.35rem;border-top:1px solid var(--paper-rule, #dde7e2)">| <>
        ~s|<header style="margin:0 0 1.15rem"><h2 style="margin:0;font-size:1.15rem;line-height:1.25;color:var(--paper-ink, #17332d)">#{Util.escape_html(title)}</h2>#{intro}</header>| <>
        ~s(<div style="display:grid;gap:0.85rem">#{cards}</div></section>)
    end
  end

  defp paper_link_ref(slug, resolved, reasons) when is_binary(slug) do
    paper_link_ref(%{"slug" => slug}, resolved, reasons)
  end

  defp paper_link_ref(ref, resolved, reasons) when is_map(ref) do
    slug = nonblank(Map.get(ref, "slug") || Map.get(ref, :slug))

    if slug do
      live = Map.get(resolved, slug, %{})

      %{
        slug: slug,
        title: live_value(live, :title) || nonblank(Map.get(ref, "title")) || slug,
        description: live_value(live, :description) || nonblank(Map.get(ref, "description")),
        reason:
          nonblank(Map.get(ref, "reason")) ||
            nonblank(Map.get(reasons, slug)),
        event_type: live_value(live, :event_type),
        rev: live_value(live, :rev),
        updated_at: live_value(live, :updated_at)
      }
    end
  end

  defp paper_link_ref(_, _, _), do: nil

  defp paper_link_card(ref, style) do
    href = Util.escape_attr("/papers/" <> ref.slug)
    description = paper_link_description(ref.description)
    reason = paper_link_reason(ref.reason, ref.description)
    metadata = paper_link_metadata(ref)

    card_style =
      case style do
        :article ->
          "display:block;padding:1.15rem 1.2rem;border:1px solid var(--paper-rule, #dde7e2);border-left:3px solid var(--paper-accent, #1e5347);border-radius:0.65rem;background:var(--paper-accent-soft, rgba(30,83,71,0.10));color:inherit;text-decoration:none"

        _ ->
          "display:block;padding:14px 16px;border:1px solid #dde7e2;border-radius:8px;color:#17332d;text-decoration:none"
      end

    ~s(<a data-paper-link-card href="#{href}" style="#{card_style}">) <>
      ~s|<strong style="display:block;font-size:1.02rem;line-height:1.35;color:var(--paper-accent, #1e5347)">#{Util.escape_html(ref.title)}</strong>| <>
      description <>
      reason <>
      metadata <>
      ~s(</a>)
  end

  defp paper_link_description(copy) do
    if copy,
      do:
        ~s|<span style="display:block;margin-top:0.42rem;color:var(--paper-ink-soft, #55635e);line-height:1.55">#{Util.escape_html(copy)}</span>|,
      else: ""
  end

  defp paper_link_reason(reason, description) do
    if reason && normalized_copy(reason) != normalized_copy(description),
      do:
        ~s|<span style="display:block;margin-top:0.65rem;color:var(--paper-ink, #17332d);font-size:0.88rem;line-height:1.45"><strong>Why it matters:</strong> #{Util.escape_html(reason)}</span>|,
      else: ""
  end

  defp normalized_copy(nil), do: nil

  defp normalized_copy(copy) do
    copy
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp paper_link_metadata(ref) do
    [ref.event_type, ref.rev && "rev #{ref.rev}", ref.updated_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        ""

      parts ->
        ~s|<span style="display:block;margin-top:0.7rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.72rem;letter-spacing:0.025em;color:var(--paper-ink-soft, #55635e)">#{Util.escape_html(Enum.join(parts, " · "))}</span>|
    end
  end

  defp live_value(map, key) when is_map(map),
    do: nonblank(Map.get(map, key) || Map.get(map, Atom.to_string(key)))

  defp live_value(_, _), do: nil

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(value) when is_integer(value), do: to_string(value)
  defp nonblank(_), do: nil

  # Children of a container block: `children` (preferred) or `blocks`.
  defp container_children(b), do: Map.get(b, "children") || Map.get(b, "blocks") || []

  defp figure_html(child, caption, style) do
    child_html =
      case child do
        c when is_map(c) ->
          composed = compose_block(c, style)
          pal = Barkpark.PortableDoc.Render.Palettes.palette_for(style)
          width = Map.fetch!(pal, :width)
          Walk.render_body(composed, width, pal)

        _ ->
          ""
      end

    {open, cap} =
      case style do
        :article ->
          c =
            if caption == "",
              do: "",
              else:
                ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">#{Figures.figcaption_inner(caption)}</figcaption>|

          {~s|<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">|,
           c}

        _ ->
          c =
            if caption == "",
              do: "",
              else:
                ~s(<div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">#{Figures.figcaption_inner(caption)}</div>)

          {~s(<figure style="margin:16px 0">), c}
      end

    open <> child_html <> cap <> "</figure>"
  end
end
