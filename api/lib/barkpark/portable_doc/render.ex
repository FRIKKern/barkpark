defmodule Barkpark.PortableDoc.Render do
  @moduledoc """
  Pd-tree → inline-styled HTML string. Pure string emission. NO React, NO JSX,
  NO Node sidecar — a direct in-process port of the TS `walk()` in
  `portable-doc/packages/backend-web/src/static/render.ts`.

  Output sticks to inline styles only (no `<style>` blocks, no class selectors)
  so it stays byte-comparable with the email backend.

  A Pd-tree node is a plain map keyed by string keys, e.g.

      %{"kind" => "PdText", "weight" => "bold", "children" => ["hi"]}

  This module is **pure**: no Repo, no GenServer, no I/O.
  """

  # Font names are wrapped in single quotes inside CSS so the surrounding
  # double-quoted style attribute stays valid HTML. (Embedding `"SF Pro Text"`
  # directly would terminate the attribute at the first `"`.)
  @font_body "-apple-system,'SF Pro Text',system-ui,sans-serif"
  @font_mono "ui-monospace,Menlo,monospace"
  @brand "#4f46e5"
  @brand_text "#ffffff"
  @rule "#e5e7eb"
  @page_bg "#f9fafb"

  @default_width 600

  @allowed_scheme ~r/^(?:https?|mailto|tel):/i

  # ── render styles (palettes) ───────────────────────────────────────────────
  #
  # A `palette` is the per-render context threaded through `walk/3`. The DEFAULT
  # is `:email` — its values are the module constants above, so existing call
  # sites that pass no `:style` are byte-identical to before. `:article` mirrors
  # doc.css `:root` (serif body, parchment bg, terracotta accent) for the
  # paperflow-native article surface. The palette also carries `:style` so the
  # compose / walk clauses that diverge by mode (headings, eyebrow, byline,
  # ingress) can branch on it.
  #
  # Font names are single-quoted inside CSS so the surrounding double-quoted
  # `style` attribute stays valid HTML.

  @doc false
  def email_palette do
    %{
      style: :email,
      font_body: @font_body,
      font_heading: @font_body,
      width: @default_width,
      bg: @page_bg,
      paper: "#ffffff",
      text: "#111827",
      muted: "#6b7280",
      rule: @rule,
      accent: @brand,
      link_color: "#1d4ed8",
      code_bg: "#f3f4f6"
    }
  end

  @doc false
  def article_palette do
    # All colour fields embed `var(--paper-*, <hex>)` rather than a bare hex.
    # When the rendered HTML lives inside `.bp-paper-surface` (Studio + the
    # editor panes — see root.html.heex ~:1973/:1989), the CSS variables
    # resolve to themed values (light → warm parchment + dark ink; dark →
    # warm-dark + light ink) so the inline styles flip with the host theme.
    # When the same HTML is rendered standalone — paper.html.heex (`/papers/:slug`)
    # or an email backend with no `--paper-*` context — the bare-hex fallback
    # paints exactly the same colour the palette used to emit before this
    # change. Net result: dark-mode Studio finally shows readable headings +
    # text without breaking the standalone parchment look.
    %{
      style: :article,
      font_body:
        "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,'Source Serif 4',serif",
      # Headings use the SAME serif family as the body so the View pane reads
      # identically to the Edit pane (where `.bp-paper-surface h1, h2, h3`
      # resolves to `var(--paper-font-serif)` — root.html.heex ~:2064).
      # Sans-serif headings on a serif body produce a jarring read; aligning
      # the family here plus the weight/margin/line-height nudges in
      # heading_style/2 below makes a paper render visually the same way
      # in View and in Edit, which is what users see when they toggle.
      font_heading:
        "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,'Source Serif 4',serif",
      width: 680,
      bg: "var(--paper-bg-deep, #fbfaf6)",
      paper: "var(--paper-bg, #ffffff)",
      text: "var(--paper-ink, #1a1a1a)",
      muted: "var(--paper-ink-soft, #6a6a6a)",
      rule: "var(--paper-rule, #e6e2d8)",
      accent: "var(--paper-accent, #a23925)",
      link_color: "var(--paper-accent, #a23925)",
      code_bg: "var(--paper-bg-deep, #f1ede2)"
    }
  end

  defp palette_for(:article), do: article_palette()
  defp palette_for(_), do: email_palette()

  @doc """
  Render a Pd-tree `root` to an HTML string.

  Options (a map):

    * `:doctype` — wrap the body in a full `<!doctype html>…</html>` document.
      Defaults to `true`; pass `false` to emit only the body fragment.
    * `:container_width` — outer width budget in px. Defaults to `600`.
    * `:style` — render palette: `:email` (default, the module constants) or
      `:article` (paperflow-native serif/parchment palette). Opt-in only; the
      `:email` default keeps existing output byte-unchanged.
  """
  def render_html(root, opts \\ %{}) do
    palette = palette_for(Map.get(opts, :style, :email))
    width = Map.get(opts, :container_width, Map.fetch!(palette, :width))
    body = walk(root, width, palette)

    if Map.get(opts, :doctype, true) == false do
      body
    else
      ~s(<!doctype html><html><head><meta charset="utf-8"></head>) <>
        ~s(<body style="background:#{palette.bg};margin:0;padding:0;">) <>
        body <>
        "</body></html>"
    end
  end

  # ── block → HTML (Wave 4 entry point) ──────────────────────────────────────
  #
  # The functions above render a *Pd-tree* (`%{"kind" => "PdText", …}`). The
  # functions below render a portable-doc *block list* — the AST shape that
  # `Barkpark.PortableDoc.Patch` operates on (`%{"id" => …, "type" => …}`) and
  # that the Papers context stores. They first `compose_block/1` each block into
  # a Pd-tree (the in-process twin of `composeBlock` in
  # `portable-doc/packages/primitives/src/kernel.ts`), then `walk/2` it — the
  # exact pairing of `renderBlockHtml` in the TS `backend-web` static renderer.

  @doc """
  Render a single portable-doc block to a bare HTML fragment — no `<!doctype>`,
  no `<html>`, no container `<div>`.

  The composed Pd-tree is walked with `doctype: false`, so the output is the
  same fragment that block would produce inside a full-document render. A
  `section` block carries its own leading/trailing `PdHr` rules (they live in
  the block's composed sub-tree), so they survive here by design.
  """
  def render_block(block, opts \\ %{}) when is_map(block) do
    style = Map.get(opts, :style, :email)

    block
    |> resolve_ref_title(opts)
    |> resolve_code_label(opts)
    |> compose_block(style)
    |> render_html(Map.put(opts, :doctype, false))
  end

  # field-reference View resolves the referenced doc's TITLE for display. The
  # renderer itself stays pure (no Repo): the caller supplies a `:ref_resolver`
  # fn in `opts` — `fn value, ref_type -> title_string end` — typically
  # `&Content.reference_title(&1, &2, dataset)`. We stash the resolved title on
  # a transient `"_ref_title"` key the field-reference compose clause reads;
  # the key never reaches the AST/cache (compose only emits a Pd-tree). With no
  # resolver the block is untouched and View falls back to the raw id, matching
  # the prior behaviour (and keeping pure unit tests Repo-free).
  defp resolve_ref_title(%{"type" => "field-reference", "value" => value} = block, opts)
       when is_binary(value) and value != "" do
    case Map.get(opts, :ref_resolver) do
      resolver when is_function(resolver, 2) ->
        ref_type = Map.get(block, "refType", "")
        Map.put(block, "_ref_title", to_string(resolver.(value, ref_type)))

      _ ->
        block
    end
  end

  defp resolve_ref_title(block, _opts), do: block

  # codelist View resolves the selected CODE → its human LABEL for display,
  # using the same pure-renderer + injected-resolver pattern as
  # `resolve_ref_title`. The caller supplies a `:codelist_resolver` fn in
  # `opts` — `fn plugin, codelist_id, code -> label_string end` — typically
  # `&Content.codelist_label(&1, &2, &3)`. We stash the resolved label on a
  # transient `"_code_label"` key the codelist compose clause reads. With no
  # resolver the block is untouched and View falls back to the raw code
  # (pure unit tests stay Repo-free). The `plugin` discriminator defaults to
  # `"core"` — the same default `CodelistField` carries — so blocks pointing
  # at a non-core registry (e.g. OnixEdit) must set `"plugin"`.
  defp resolve_code_label(%{"type" => "codelist", "value" => code} = block, opts)
       when is_binary(code) and code != "" do
    case Map.get(opts, :codelist_resolver) do
      resolver when is_function(resolver, 3) ->
        plugin = Map.get(block, "plugin", "core")
        codelist_id = Map.get(block, "codelistId", "")
        Map.put(block, "_code_label", to_string(resolver.(plugin, codelist_id, code)))

      _ ->
        block
    end
  end

  defp resolve_code_label(block, _opts), do: block

  @doc """
  Render a full portable-doc block list to one concatenated HTML fragment, in
  order. Used to refresh the `body_html` cache from the block source of truth.
  """
  def render_blocks(blocks, opts \\ %{}) when is_list(blocks) do
    blocks
    |> Enum.map(&render_block(&1, opts))
    |> Enum.join("")
  end

  # ── compose_block: portable-doc block → Pd-tree ────────────────────────────
  # Faithful Elixir port of kernel.ts `composeBlock`. One clause per block type.
  # Trusts the AST has already been validated (the validator is the only gate);
  # it does not re-validate URLs or tone palette membership.

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

  def compose_block(%{"type" => "callout"} = b, _style) do
    body = %{"kind" => "PdText", "children" => compose_inline_children(Map.get(b, "content", []))}

    tone = Map.get(b, "tone") || "info"
    base = %{"kind" => "PdCallout", "tone" => tone, "children" => [body]}
    maybe_put(base, "title", Map.get(b, "title"))
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
    %{"kind" => "_raw", "html" => section_divider_html()}
  end

  def compose_block(%{"type" => "divider"}, _style), do: %{"kind" => "PdHr"}

  # ── diagram / figure blocks (P1 slice 2) ───────────────────────────────────
  # `diagram` emits the canonical paperflow Mermaid figure. Unlike every other
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
    %{"kind" => "_raw", "html" => diagram_html(source, caption, style)}
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
    %{"kind" => "_raw", "html" => asciicast_html(src, caption, :article)}
  end

  def compose_block(%{"type" => "asciicast"} = b, style) do
    src = to_string(Map.get(b, "src", ""))
    caption = to_string(Map.get(b, "caption", ""))
    %{"kind" => "_raw", "html" => asciicast_html(src, caption, style)}
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
    %{"kind" => "_raw", "html" => code_block_html(value)}
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
  # key holds the cached dense value grid (`Barkpark.Sheets.snapshot_for/2`,
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
  # Renders a paperflow grill / questionnaire as native portable-doc markup.
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
    %{"kind" => "_raw", "html" => form_html(b, style)}
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

  # ── article block HTML emission (code / section divider) ───────────────────

  # A single styled `<pre>` code block for article mode: monospace, parchment
  # `#f1ede2` background, a 3px terracotta `#a23925` left-border, padding, and
  # horizontal scroll on overflow. The value is HTML-escaped (the `<pre>` shows
  # source verbatim, so no Mermaid `pre.mermaid` selector concern here).
  defp code_block_html(value) do
    ~s|<pre style="background:var(--paper-bg-deep, #f1ede2);border-left:3px solid var(--paper-accent, #a23925);color:var(--paper-ink, #1a1a1a);padding:0.9rem 1.1rem;| <>
      ~s|margin:1.2rem 0;font-family:#{@font_mono};font-size:0.9rem;line-height:1.5;| <>
      ~s|overflow-x:auto;white-space:pre">#{escape_html(value)}</pre>|
  end

  # The doc.css `hr.section` look: a centered "§" glyph straddling a hairline
  # rule. The glyph sits in an inline-block box with the parchment page colour
  # as its background, masking the rule that runs behind it across the column.
  defp section_divider_html do
    ~s|<div style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid var(--paper-rule, #e6e2d8)">| <>
      ~s|<span style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;| <>
      ~s|background:var(--paper-bg-deep, #fbfaf6);color:var(--paper-ink-soft, #6a6a6a);font-size:1.1rem">§</span></div>|
  end

  # ── diagram / figure HTML emission ─────────────────────────────────────────

  # Entity-encode ONLY the three structural chars Mermaid source can carry
  # (`&` first, then `<` `>`) — NOT quotes/apostrophes. The encoded text lives
  # as the text content of `<pre class="mermaid">`, so it survives the static
  # body_html extractor unchanged AND Mermaid's runtime reads `textContent`
  # (which the browser decodes back to the literal `&`/`<`/`>`). Encoding quotes
  # would be wrong here: Mermaid label syntax uses them and they're harmless as
  # element text.
  defp encode_mermaid(source) when is_binary(source) do
    source
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Bold "Figure N." run-in: split a "Figure 1. rest" caption so the leading
  # "Figure N." is bolded and the remainder stays plain. Falls back to the whole
  # caption (no bold) when it doesn't match the convention.
  defp figcaption_inner(""), do: ""

  defp figcaption_inner(caption) do
    case Regex.run(~r/^(Figure\s+\S+?\.)\s*(.*)$/s, caption) do
      [_, lead, rest] ->
        rest_html = if rest == "", do: "", else: " " <> escape_html(rest)
        "<b>#{escape_html(lead)}</b>" <> rest_html

      _ ->
        escape_html(caption)
    end
  end

  # The canonical paperflow figure for a Mermaid diagram. Article mode: a
  # bordered, parchment, inset card mirroring doc.css `figure`; the figcaption
  # is muted/italic with the bold "Figure N." run-in. Email mode degrades to the
  # caption line + the source as a plain code block (Mermaid never runs there).
  defp diagram_html(source, caption, :article) do
    cap =
      if caption == "" do
        ""
      else
        ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #6a6a6a);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>|
      end

    ~s|<figure style="margin:1.6rem 0;padding:1.2rem;background:var(--paper-bg-deep, #fbfaf6);border:1px solid var(--paper-rule, #e6e2d8);border-radius:4px">| <>
      ~s(<pre class="mermaid">#{encode_mermaid(source)}</pre>) <>
      cap <>
      "</figure>"
  end

  defp diagram_html(source, caption, _style) do
    # Email / default: no Mermaid runtime, so show the source as a code block
    # plus the caption. The `<pre class="mermaid">` literal is intentionally
    # ABSENT here — the engine must not be triggered in email contexts.
    cap =
      if caption == "" do
        ""
      else
        ~s(<div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">#{figcaption_inner(caption)}</div>)
      end

    ~s(<figure style="margin:16px 0">) <>
      ~s(<pre style="background:#f3f4f6;padding:12px;font-family:#{@font_mono};font-size:0.9em;overflow:auto;white-space:pre-wrap">#{escape_html(source)}</pre>) <>
      cap <>
      "</figure>"
  end

  # The asciinema terminal-recording figure. Article mode: a bordered mount
  # point the PaperMermaid hook's `runAsciicast()` upgrades into a live player
  # at runtime. The cast URL is carried in `data-cast-src` via `safe_url` (scheme
  # allowlist + attribute escape). The figcaption reuses diagram_html's article
  # styling. Email / default mode: no player runtime — degrade to a plain link.
  defp asciicast_html(src, caption, :article) do
    cap =
      if caption == "" do
        ""
      else
        ~s(<figcaption style="margin-top:0.8rem;color:#6a6a6a;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>)
      end

    ~s(<figure style="margin:1.6rem 0">) <>
      ~s(<div class="bp-asciicast" data-cast-src="#{safe_url(src)}" style="border:1px solid #e6e2d8;border-radius:6px;overflow:hidden"></div>) <>
      cap <>
      "</figure>"
  end

  defp asciicast_html(src, caption, _style) do
    # Email / default: no asciinema runtime, so link to the recording instead of
    # mounting a player. The `bp-asciicast` mount point is intentionally ABSENT
    # here — the hook must not be triggered in email contexts.
    cap =
      if caption == "" do
        ""
      else
        ~s(<div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">#{figcaption_inner(caption)}</div>)
      end

    ~s(<figure style="margin:16px 0">) <>
      ~s(<a href="#{safe_url(src)}">Terminal recording</a>) <>
      cap <>
      "</figure>"
  end

  # Generic figure: a composed child block + caption. nil child → caption only.
  defp figure_html(child, caption, style) do
    child_html =
      case child do
        c when is_map(c) ->
          c |> compose_block(style) |> render_html(%{doctype: false, style: style})

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
                ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #6a6a6a);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>|

          {~s(<figure style="margin:1.6rem 0">), c}

        _ ->
          c =
            if caption == "",
              do: "",
              else:
                ~s(<div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">#{figcaption_inner(caption)}</div>)

          {~s(<figure style="margin:16px 0">), c}
      end

    open <> child_html <> cap <> "</figure>"
  end

  # ── form / questionnaire HTML emission (P4) ────────────────────────────────
  #
  # A render-only grill / questionnaire: one <fieldset> per question, clean
  # semantic controls per the grill.js input types. No <script>, no
  # action/method, no submit wiring. Every user string is escape_html'd. The
  # container class (`bp-form bp-form-<kind>`) lets the host CSS hook in; the
  # `kind` discriminator defaults to "grill". Article mode adds a couple of
  # inline style cues (muted lines, spacing); email mode is the plainer twin.
  # Both are deterministic.

  defp form_html(b, style) do
    kind = b |> Map.get("kind", "grill") |> to_string()
    kind_class = if kind == "questionnaire", do: "bp-form-questionnaire", else: "bp-form-grill"

    questions =
      b
      |> Map.get("questions", [])
      |> List.wrap()
      |> Enum.map(&form_question_html(&1, style))
      |> Enum.join("")

    ~s(<section class="bp-form #{kind_class}">) <> questions <> "</section>"
  end

  defp form_question_html(q, style) when is_map(q) do
    id = q |> Map.get("id", "") |> to_string()
    prompt = q |> Map.get("prompt", "") |> to_string()
    type = q |> Map.get("type", "text") |> to_string()

    legend = ~s(<legend>#{escape_html(prompt)}</legend>)

    rationale_line = form_muted_line(Map.get(q, "rationale"), "", style)
    recommendation_line = form_muted_line(Map.get(q, "recommendation"), "Recommendation: ", style)

    control = form_control_html(type, id, q, style)

    ~s(<fieldset class="bp-form-question">) <>
      legend <> rationale_line <> recommendation_line <> control <> "</fieldset>"
  end

  defp form_question_html(_q, _style), do: ""

  # A muted context/recommendation paragraph; rendered only when text present.
  defp form_muted_line(nil, _prefix, _style), do: ""
  defp form_muted_line("", _prefix, _style), do: ""

  defp form_muted_line(text, prefix, style) when is_binary(text) do
    color = if style == :article, do: "#6a6a6a", else: "#6b7280"

    ~s(<p style="color:#{color};font-size:0.9em;margin:0.3rem 0">#{escape_html(prefix)}#{escape_html(text)}</p>)
  end

  defp form_muted_line(text, prefix, style), do: form_muted_line(to_string(text), prefix, style)

  # Per-type control markup. All names share the question id so grouped
  # radios/checkboxes round-trip to one answer field at the interactive phase.
  defp form_control_html("yesno", id, _q, style) do
    form_radio_group(id, ["Yes", "No"], style)
  end

  defp form_control_html("single", id, q, style) do
    options = q |> Map.get("options", []) |> List.wrap() |> Enum.map(&to_string/1)
    form_radio_group(id, options, style)
  end

  defp form_control_html("multi", id, q, style) do
    options = q |> Map.get("options", []) |> List.wrap() |> Enum.map(&to_string/1)
    form_choice_group(id, options, "checkbox", style)
  end

  defp form_control_html("scale", id, q, style) do
    scale = Map.get(q, "scale", %{})
    min = scale_bound(Map.get(scale, "min"), 1)
    max = scale_bound(Map.get(scale, "max"), 5)
    labels = if max >= min, do: Enum.map(min..max, &Integer.to_string/1), else: []
    form_radio_group(id, labels, style)
  end

  defp form_control_html("text", id, _q, _style) do
    ~s(<textarea name="#{escape_attr(id)}" rows="3"></textarea>)
  end

  # Unknown type → degrade to a text control (render-only, never crash).
  defp form_control_html(_type, id, _q, _style) do
    ~s(<textarea name="#{escape_attr(id)}" rows="3"></textarea>)
  end

  defp form_radio_group(id, labels, style), do: form_choice_group(id, labels, "radio", style)

  defp form_choice_group(id, labels, input_type, style) do
    gap = if style == :article, do: "0.35rem", else: "0.2rem"

    labels
    |> Enum.map(fn label ->
      ~s(<label style="display:block;margin:#{gap} 0">) <>
        ~s(<input type="#{input_type}" name="#{escape_attr(id)}" value="#{escape_attr(label)}"> ) <>
        ~s(<span>#{escape_html(label)}</span></label>)
    end)
    |> Enum.join("")
  end

  # Coerce a scale bound to an integer, falling back to `default`.
  defp scale_bound(v, _default) when is_integer(v), do: v

  defp scale_bound(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp scale_bound(_v, default), do: default

  # ── inline walker (kernel.ts composeInline) ────────────────────────────────

  defp compose_inline_children(nodes) when is_list(nodes) do
    Enum.map(nodes, &compose_inline(&1, false))
  end

  # Tolerate scalar cells (a plain string where a list of inline nodes was
  # expected — common in tables emitted by upstream converters that flatten
  # text-only cells). Treat the scalar as a single text node so the cell
  # renders as its string value instead of vanishing.
  defp compose_inline_children(s) when is_binary(s), do: [s]
  defp compose_inline_children(n) when is_number(n), do: [to_string(n)]
  defp compose_inline_children(_), do: []

  defp compose_inline(%{"type" => "text"} = n, inside_link) do
    value = Map.get(n, "value", "")

    case Map.get(n, "marks") do
      nil -> value
      [] -> value
      marks when is_list(marks) -> apply_marks(value, marks, inside_link)
      _ -> value
    end
  end

  defp compose_inline(%{"type" => "strong"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "weight" => "bold",
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  defp compose_inline(%{"type" => "em"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "italic" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  defp compose_inline(%{"type" => "code"} = n, _inside_link) do
    %{"kind" => "PdInlineCode", "value" => Map.get(n, "value", "")}
  end

  defp compose_inline(%{"type" => "link"} = n, inside_link) do
    children = Enum.map(Map.get(n, "children", []), &compose_inline_for_link_children(&1, true))

    if inside_link do
      # Nested link — flatten to a plain text wrapper to keep links non-recursive.
      %{"kind" => "PdText", "children" => children}
    else
      %{"kind" => "PdLink", "href" => Map.get(n, "href", ""), "children" => children}
    end
  end

  defp compose_inline(%{"type" => type}, _inside_link) do
    raise ArgumentError, "compose_inline: unhandled inline type #{type}"
  end

  # Tolerate scalar inline nodes — upstream converters (and the list-block
  # `items: [["a"]]` shape in the public ingest contract) flatten text-only
  # inlines to bare strings/numbers. Mirrors `compose_inline_children/1`.
  defp compose_inline(s, _inside_link) when is_binary(s), do: s
  defp compose_inline(n, _inside_link) when is_number(n), do: to_string(n)

  # Link children are PdText | string only.
  defp compose_inline_for_link_children(node, inside_link) do
    case compose_inline(node, inside_link) do
      s when is_binary(s) -> s
      %{"kind" => "PdText"} = t -> t
      # `code` or a flattened nested link → wrap in a PdText so the type holds.
      other -> %{"kind" => "PdText", "children" => [other]}
    end
  end

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

  # Unknown marks pass through (no wrapper).
  defp apply_mark(_unknown, acc, _il), do: acc

  defp wrap_children(acc) when is_binary(acc), do: [acc]
  defp wrap_children(acc) when is_list(acc), do: acc
  defp wrap_children(acc), do: [acc]

  defp link_child(s, _il) when is_binary(s), do: s
  defp link_child(%{"kind" => "PdText"} = t, _il), do: t
  defp link_child(other, _il), do: %{"kind" => "PdText", "children" => [other]}

  # Coerce an inline child into a Pd-node for table cells.
  defp to_pd_node_from_inline_child(child) when is_binary(child) do
    %{"kind" => "PdText", "children" => [child]}
  end

  defp to_pd_node_from_inline_child(child), do: child

  # Put `key => value` only when value is not nil (mirrors the conditional
  # spreads in kernel.ts, e.g. `...(title !== undefined ? {title} : {})`).
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── walk: one clause per PdNode kind ───────────────────────────────────────
  #
  # `walk/3` threads the render `palette` (email default) alongside the width.
  # Email values equal the module constants, so email output is byte-identical
  # to the pre-palette walker; the article palette only diverges where the
  # compose clauses stamped a `_role` / `_heading_level` hint.

  defp walk(%{"kind" => "PdContainer"} = n, width, pal), do: container(n, width, pal)
  defp walk(%{"kind" => "PdBox"} = n, width, pal), do: box(n, width, pal)
  defp walk(%{"kind" => "PdHeading"} = n, width, pal), do: heading(n, width, pal)
  defp walk(%{"kind" => "PdParagraph"} = n, width, pal), do: paragraph(n, width, pal)
  defp walk(%{"kind" => "PdText"} = n, width, pal), do: text(n, width, pal)
  defp walk(%{"kind" => "PdLink"} = n, width, pal), do: link(n, width, pal)

  defp walk(%{"kind" => "PdInlineCode"} = n, _width, pal) do
    ~s(<code style="background:#{pal.code_bg};padding:2px 6px;font-family:#{@font_mono};font-size:0.95em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  defp walk(%{"kind" => "PdButton"} = n, _width, pal), do: button(n, pal)
  defp walk(%{"kind" => "PdHr"} = n, _width, pal), do: hr(n, pal)
  defp walk(%{"kind" => "PdImage"} = n, _width, _pal), do: image(n)
  defp walk(%{"kind" => "PdTable"} = n, width, pal), do: table(n, width, pal)
  defp walk(%{"kind" => "PdSheet"} = n, width, pal), do: sheet(n, width, pal)
  defp walk(%{"kind" => "PdCallout"} = n, width, pal), do: callout(n, width, pal)
  defp walk(%{"kind" => "PdList"} = n, width, pal), do: list(n, width, pal)
  defp walk(%{"kind" => "PdListItem"} = n, width, pal), do: list_item(n, width, pal)

  # `_raw` is a pre-rendered HTML escape hatch. The diagram / figure compose
  # clauses emit it because their `<figure>` / `<pre class="mermaid">` markup
  # must reach the DOM byte-exact (the Mermaid engine selects on `pre.mermaid`)
  # — they can't round-trip through the PdText escape path. The HTML they carry
  # is built from already-escaped parts in `diagram_html` / `figure_html`.
  defp walk(%{"kind" => "_raw", "html" => html}, _width, _pal), do: html

  defp walk(%{"kind" => kind}, _width, _pal) do
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
    # paperflow_to_blocks.py table walker) now get a header-less table
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

    title_html =
      case Map.get(n, "title") do
        nil -> ""
        "" -> ""
        title -> "<strong>#{escape_html(title)}</strong> "
      end

    inner = render_children(Map.get(n, "children", []), width, pal)

    ~s(<div style="border-left:4px solid #{tone.fg};background:#{tone.bg};padding:16px;color:#{tone.fg}">#{title_html}#{inner}</div>)
  end

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

  @doc """
  Escape the five HTML-significant characters in the EXACT order `& < > " '`.

  The ampersand must go first so we never double-escape the entities the later
  replacements introduce.
  """
  def escape_html(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc "Stricter escape for attribute values — same as `escape_html/1`."
  def escape_attr(s) when is_binary(s), do: escape_html(s)

  @doc """
  Return the URL attribute-escaped if its scheme is allowlisted
  (`http | https | mailto | tel`, case-insensitive), else `#`.

  Leading ASCII control characters / whitespace are stripped before matching,
  mirroring browser tolerance for `\\tjavascript:…`.
  """
  def safe_url(href) when is_binary(href) do
    trimmed = String.replace(href, ~r/^[\x00-\x20]+/, "")

    cond do
      String.starts_with?(trimmed, "/") ->
        escape_attr(trimmed)

      Regex.match?(@allowed_scheme, trimmed) ->
        escape_attr(trimmed)

      true ->
        "#"
    end
  end

  @doc "Background / foreground palette for a callout tone."
  def tone_palette("success"), do: %{bg: "#ecfdf5", fg: "#047857"}
  def tone_palette("warning"), do: %{bg: "#fffbeb", fg: "#92400e"}
  def tone_palette("danger"), do: %{bg: "#fef2f2", fg: "#b91c1c"}
  def tone_palette("info"), do: %{bg: "#eff6ff", fg: "#1d4ed8"}
  def tone_palette("neutral"), do: %{bg: "#f3f4f6", fg: "#374151"}
  def tone_palette(_), do: %{bg: "#eff6ff", fg: "#1d4ed8"}
end
