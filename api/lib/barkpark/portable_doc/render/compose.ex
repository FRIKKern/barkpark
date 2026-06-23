defmodule Barkpark.PortableDoc.Render.Compose do
  @moduledoc """
  portable-doc block → Pd-tree composition for the PortableDoc render engine —
  the faithful Elixir port of kernel.ts `composeBlock`. One clause per block
  type. Trusts the AST has already been validated (the validator is the only
  gate); it does not re-validate URLs or tone palette membership.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). This is the COMPOSE recursive tree (`compose_block` →
  `compose_inline` / figure HTML); it never calls walk except via the generic
  `figure_html` bridge, which composes a child then renders it through
  `Render.Walk.render_body/3`. Output is byte-identical to the pre-split engine.
  """

  alias Barkpark.PortableDoc.Render.{Figures, Forms, Inline, Walk}

  import Inline, only: [compose_inline_children: 1, to_pd_node_from_inline_child: 1]

  @rule Barkpark.PortableDoc.Render.Palettes.rule()

  # ── compose_block: portable-doc block → Pd-tree ────────────────────────────

  # `compose_block/1` keeps the email (default) palette so existing call sites
  # and tests are byte-unchanged. The style-aware `compose_block/2` below carries
  # the render style so heading / eyebrow / byline / ingress can diverge.
  @doc false
  def compose_block(b), do: compose_block(b, :email)

  @doc false
  def compose_block(%{"type" => "heading"} = b, style) do
    text = Map.get(b, "text", "")
    level = heading_level(Map.get(b, "level"))

    # Article mode emits a real semantic heading node (`PdHeading` → `<h1>` /
    # `<h2>` / `<h3>`) so screen readers, the outline tree, and CSS `hN`
    # selectors all see a genuine heading — the styled `<span>` it used to be
    # registered as 0 real headings in the DOM. Email mode keeps the original
    # single bold span, byte-identical to the pre-article behaviour.
    if style == :article do
      %{"kind" => "PdHeading", "level" => level, "children" => [text]}
    else
      %{"kind" => "PdText", "weight" => "bold", "children" => [text]}
    end
  end

  def compose_block(%{"type" => "eyebrow"} = b, _style) do
    # Uppercase, letter-spaced, accent kicker (article) / muted line (email).
    # The walk reads `_role` to pick the styling per palette.
    %{
      "kind" => "PdText",
      "_role" => "eyebrow",
      "children" => [to_string(Map.get(b, "text", ""))]
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
        items when is_list(items) -> items |> Enum.map(&to_string/1) |> Enum.join(" · ")
        _ -> to_string(Map.get(b, "text", ""))
      end

    kind = if style == :article, do: "PdParagraph", else: "PdText"
    %{"kind" => kind, "_role" => "byline", "children" => [text]}
  end

  def compose_block(%{"type" => "ingress"} = b, style) do
    # Lead paragraph — heavier weight + larger size in article mode.
    # Article mode: real `<p>` carrying the ingress role's inline style so
    # the editor's block-level paragraph rules also apply (margin rhythm,
    # hyphens). Email/default mode keeps the byte-stable `<span>` form.
    kind = if style == :article, do: "PdParagraph", else: "PdText"

    %{
      "kind" => kind,
      "_role" => "ingress",
      "children" => compose_inline_children(Map.get(b, "content", []))
    }
  end

  def compose_block(%{"type" => "paragraph"} = b, style) do
    # Article mode emits a real `<p>` (PdParagraph) so the editor's
    # `.bp-paper-surface p { margin: 12pt 0 0; hyphens: auto }` CSS rule
    # (root.html.heex ~:2068) matches in the desk View pane — paragraphs
    # used to collapse against each other because they rendered as bare
    # spans with no block-level margins. Email/default mode keeps PdText
    # (`<span>`) so the email backend's byte-stable export is untouched.
    kind = if style == :article, do: "PdParagraph", else: "PdText"
    %{"kind" => kind, "children" => compose_inline_children(Map.get(b, "content", []))}
  end

  # Pullquote — italic serif, larger, muted, with a 3px terracotta left-border
  # (mirrors doc.css `.pullquote`) in article mode. Email/default mode degrades
  # to a plain italic span (no border / sizing cues) via the same `_role` hook
  # the other typographic roles use, so it stays a single styled `<span>`.
  def compose_block(%{"type" => "pullquote"} = b, _style) do
    %{
      "kind" => "PdText",
      "_role" => "pullquote",
      "italic" => true,
      "children" => compose_inline_children(Map.get(b, "content", []))
    }
  end

  # Article mode emits semantic `<ul>` / `<ol>` via PdList / PdListItem so
  # browsers / readers get real list semantics (a11y, copy-paste, default
  # spacing). Email / default mode keeps the flex-row PdBox scaffold below
  # with literal "• " / "1. " prefix spans — Outlook strips `<ul>` padding,
  # so the prefix-as-text scaffold is the byte-stable email target.
  def compose_block(%{"type" => "list"} = b, :article) do
    ordered = Map.get(b, "ordered") == true

    items =
      Map.get(b, "items", [])
      |> Enum.map(fn item ->
        %{
          "kind" => "PdListItem",
          "children" => [
            %{"kind" => "PdText", "children" => compose_inline_children(item)}
          ]
        }
      end)

    %{"kind" => "PdList", "ordered" => ordered, "children" => items}
  end

  def compose_block(%{"type" => "list"} = b, _style) do
    ordered = Map.get(b, "ordered") == true

    item_rows =
      Map.get(b, "items", [])
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        prefix = if ordered, do: "#{idx + 1}. ", else: "• "

        %{
          "kind" => "PdBox",
          "style" => %{"flexDirection" => "row"},
          "children" => [
            %{"kind" => "PdText", "children" => [prefix]},
            %{"kind" => "PdText", "children" => compose_inline_children(item)}
          ]
        }
      end)

    %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => item_rows}
  end

  def compose_block(%{"type" => "callout"} = b, style) do
    body = %{"kind" => "PdText", "children" => compose_inline_children(Map.get(b, "content", []))}

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

  def compose_block(%{"type" => "section"} = b, style) do
    leading = [%{"kind" => "PdHr"}]

    title =
      case Map.get(b, "title") do
        nil -> []
        t -> [%{"kind" => "PdText", "weight" => "bold", "children" => [t]}]
      end

    inner = Enum.map(Map.get(b, "blocks", []), &compose_block(&1, style))

    children = leading ++ title ++ inner ++ [%{"kind" => "PdHr"}]
    %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => children}
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
    source = to_string(Map.get(b, "source", ""))
    caption = to_string(Map.get(b, "caption", ""))
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
  def compose_block(%{"type" => "asciicast"} = b, :article) do
    src = to_string(Map.get(b, "src", ""))
    caption = to_string(Map.get(b, "caption", ""))
    %{"kind" => "_raw", "html" => Figures.asciicast_html(src, caption, :article)}
  end

  def compose_block(%{"type" => "asciicast"} = b, style) do
    src = to_string(Map.get(b, "src", ""))
    caption = to_string(Map.get(b, "caption", ""))
    %{"kind" => "_raw", "html" => Figures.asciicast_html(src, caption, style)}
  end

  # generic `figure` — wraps a child block + caption. Cheap and clean: compose
  # the child through the normal path, then wrap it in the same figure chrome
  # as `diagram` (caption only, no mermaid). Article mode gets the card; email
  # mode degrades to child + plain caption line.
  def compose_block(%{"type" => "figure"} = b, style) do
    caption = to_string(Map.get(b, "caption", ""))
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
    value = to_string(Map.get(b, "value", ""))
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

  def compose_block(%{"type" => "image"} = b, _style) do
    %{"kind" => "PdImage", "src" => Map.get(b, "src", ""), "alt" => Map.get(b, "alt", "")}
    |> maybe_put("width", Map.get(b, "width"))
    |> maybe_put("height", Map.get(b, "height"))
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
          Enum.map(rows, fn row -> row |> List.wrap() |> Enum.map(&to_string/1) end)

        _ ->
          []
      end

    pd = %{"kind" => "PdSheet", "rows" => rows}

    pd =
      case Map.get(snap, "head") do
        head when is_list(head) -> Map.put(pd, "head", Enum.map(head, &to_string/1))
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

    case Map.get(snap, "styles") do
      styles when is_map(styles) and map_size(styles) > 0 -> Map.put(pd, "styles", styles)
      _ -> pd
    end
  end

  def compose_block(%{"type" => "table"} = b, _style) do
    compose_cell = fn cell ->
      cell |> compose_inline_children() |> Enum.map(&to_pd_node_from_inline_child/1)
    end

    compose_row = fn row -> row |> List.wrap() |> Enum.map(compose_cell) end

    rows =
      Map.get(b, "rows", [])
      |> List.wrap()
      |> Enum.map(compose_row)

    pd = %{"kind" => "PdTable", "rows" => rows}

    case Map.get(b, "head") do
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

  def compose_block(%{"type" => "field-string"} = b, _style),
    do: field_row(b, field_value_text(b))

  def compose_block(%{"type" => "field-slug"} = b, _style), do: field_row(b, field_value_text(b))
  def compose_block(%{"type" => "field-text"} = b, _style), do: field_row(b, field_value_text(b))

  def compose_block(%{"type" => "field-boolean"} = b, _style) do
    field_row(b, if(Map.get(b, "value") == true, do: "Yes", else: "No"))
  end

  def compose_block(%{"type" => "field-select"} = b, _style) do
    value = Map.get(b, "value")

    label =
      Map.get(b, "options", [])
      |> Enum.find(fn opt -> Map.get(opt, "value") == value end)
      |> case do
        nil -> field_value_text(b)
        opt -> to_string(Map.get(opt, "label", Map.get(opt, "value", "")))
      end

    field_row(b, label)
  end

  def compose_block(%{"type" => "field-datetime"} = b, _style) do
    field_row(b, format_datetime(Map.get(b, "value", "")))
  end

  def compose_block(%{"type" => "field-color"} = b, _style) do
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
        "borderColor" => @rule,
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
  def compose_block(%{"type" => "field-image"} = b, _style) do
    src = media_field_url(Map.get(b, "value", ""))

    value_node =
      if src == "" do
        %{"kind" => "PdText", "children" => ["No image"]}
      else
        %{"kind" => "PdImage", "src" => src, "alt" => to_string(Map.get(b, "label", ""))}
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
  def compose_block(%{"type" => "codelist"} = b, _style) do
    code = field_value_text(b)
    label = b |> Map.get("_code_label", "") |> to_string()

    display =
      cond do
        code == "" -> "—"
        label != "" -> label
        true -> code
      end

    field_row(b, display)
  end

  # localizedText → labelled box, one row per language (lang: text).
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

  def compose_block(%{"type" => type}, _style) do
    raise ArgumentError, "compose_block: unhandled block type #{type}"
  end

  # Clamp a heading level to 1..3; default to 2 when absent/out of range.
  defp heading_level(l) when l in [1, 2, 3], do: l
  defp heading_level("1"), do: 1
  defp heading_level("2"), do: 2
  defp heading_level("3"), do: 3
  defp heading_level(_), do: 2

  # A labelled value row: bold label on its own line, then the value as PdText.
  defp field_row(b, value_text) when is_binary(value_text) do
    %{
      "kind" => "PdBox",
      "style" => %{"flexDirection" => "column"},
      "children" => [field_label_node(b), %{"kind" => "PdText", "children" => [value_text]}]
    }
  end

  defp field_label_node(b) do
    %{"kind" => "PdText", "weight" => "bold", "children" => [to_string(Map.get(b, "label", ""))]}
  end

  defp field_value_text(b), do: to_string(Map.get(b, "value", ""))

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

  defp media_field_url(v), do: to_string(v || "")

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
  defp format_datetime(v), do: to_string(v)

  # Put `key => value` only when value is not nil (mirrors the conditional
  # spreads in kernel.ts, e.g. `...(title !== undefined ? {title} : {})`).
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Like maybe_put but writes ONLY when the value is exactly `true` — so a
  # boolean attr's absence and an explicit `false` render identically (an
  # un-folded callout stays byte-identical even after a re-save).
  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _value), do: map

  # ── generic figure HTML emission (compose + walk bridge) ───────────────────
  # Generic figure: a composed child block + caption. nil child → caption only.
  # This is the ONE compose helper that recurses through walk — it composes the
  # child block then renders it to a body fragment via `Render.Walk.render_body`
  # (the `doctype: false` body twin of `render_html`).
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
                ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #6a6a6a);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{Figures.figcaption_inner(caption)}</figcaption>|

          {~s(<figure style="margin:1.6rem 0">), c}

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
