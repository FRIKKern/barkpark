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
    %{
      style: :article,
      font_body:
        "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,'Source Serif 4',serif",
      font_heading: "system-ui,-apple-system,'SF Pro Text',sans-serif",
      width: 680,
      bg: "#fbfaf6",
      paper: "#ffffff",
      text: "#1a1a1a",
      muted: "#6a6a6a",
      rule: "#e6e2d8",
      accent: "#a23925",
      link_color: "#a23925",
      code_bg: "#f1ede2"
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

    base = %{"kind" => "PdText", "weight" => "bold", "children" => [text]}

    # Article mode stamps a transient size hint the heading walk reads to size
    # by level (h1 > h2 > h3). Email mode leaves the node as the original single
    # bold span — byte-identical to the pre-article behaviour.
    if style == :article do
      Map.put(base, "_heading_level", level)
    else
      base
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

  def compose_block(%{"type" => "byline"} = b, _style) do
    # `items` (list) joined by " · ", else a plain `text`. Muted sans line with
    # a bottom rule in article mode.
    text =
      case Map.get(b, "items") do
        items when is_list(items) -> items |> Enum.map(&to_string/1) |> Enum.join(" · ")
        _ -> to_string(Map.get(b, "text", ""))
      end

    %{"kind" => "PdText", "_role" => "byline", "children" => [text]}
  end

  def compose_block(%{"type" => "ingress"} = b, _style) do
    # Lead paragraph — heavier weight + larger size in article mode.
    %{
      "kind" => "PdText",
      "_role" => "ingress",
      "children" => compose_inline_children(Map.get(b, "content", []))
    }
  end

  def compose_block(%{"type" => "paragraph"} = b, _style) do
    %{"kind" => "PdText", "children" => compose_inline_children(Map.get(b, "content", []))}
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

    base = %{"kind" => "PdCallout", "tone" => Map.get(b, "tone"), "children" => [body]}
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

  def compose_block(%{"type" => "table"} = b, _style) do
    rows =
      Map.get(b, "rows", [])
      |> Enum.map(fn row ->
        Enum.map(row, fn cell ->
          cell |> compose_inline_children() |> Enum.map(&to_pd_node_from_inline_child/1)
        end)
      end)

    %{"kind" => "PdTable", "rows" => rows}
  end

  # ── field-* LEAF blocks (P2.1) ─────────────────────────────────────────────
  # Structured field blocks carry their own `value` (the editable datum) plus a
  # human `label`. View-mode renders a labelled row: a bold label followed by the
  # rendered value. Each clause composes to a PdBox(column) so the fragment is
  # self-contained and walks through the existing renderer with no new PdNode
  # kinds. All values flow through PdText, so they inherit `escape_html` at walk
  # time — no field-* clause emits raw HTML.

  def compose_block(%{"type" => "field-string"} = b, _style), do: field_row(b, field_value_text(b))
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
        ~s(<figcaption style="margin-top:0.8rem;color:#6a6a6a;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>)
      end

    ~s(<figure style="margin:1.6rem 0;padding:1.2rem;background:#fbfaf6;border:1px solid #e6e2d8;border-radius:4px">) <>
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

  # Generic figure: a composed child block + caption. nil child → caption only.
  defp figure_html(child, caption, style) do
    child_html =
      case child do
        c when is_map(c) -> c |> compose_block(style) |> render_html(%{doctype: false, style: style})
        _ -> ""
      end

    {open, cap} =
      case style do
        :article ->
          c =
            if caption == "",
              do: "",
              else:
                ~s(<figcaption style="margin-top:0.8rem;color:#6a6a6a;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>)

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

  # ── inline walker (kernel.ts composeInline) ────────────────────────────────

  defp compose_inline_children(nodes) when is_list(nodes) do
    Enum.map(nodes, &compose_inline(&1, false))
  end

  defp compose_inline_children(_), do: []

  defp compose_inline(%{"type" => "text"} = n, _inside_link), do: Map.get(n, "value", "")

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

  # Link children are PdText | string only.
  defp compose_inline_for_link_children(node, inside_link) do
    case compose_inline(node, inside_link) do
      s when is_binary(s) -> s
      %{"kind" => "PdText"} = t -> t
      # `code` or a flattened nested link → wrap in a PdText so the type holds.
      other -> %{"kind" => "PdText", "children" => [other]}
    end
  end

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
  defp walk(%{"kind" => "PdCallout"} = n, width, pal), do: callout(n, width, pal)

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

    if bw != nil and bc && bs do
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

  # ── article typographic roles ──────────────────────────────────────────────
  # Applied only when the compose clause stamped a hint AND the palette is the
  # article palette. The accumulator `out` is in REVERSE-build order (it gets
  # `Enum.reverse`d before joining), so we APPEND role declarations here — they
  # land at the FRONT of the final style string, ahead of weight/italic/deco.

  defp apply_text_role(out, inner, n, %{style: :article} = pal) do
    cond do
      level = Map.get(n, "_heading_level") ->
        # Drop the plain bold flag; the heading rule carries its own weight.
        out = List.delete(out, "font-weight:bold")
        out = heading_style(level, pal) ++ out
        {out, inner}

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

      true ->
        {out, inner}
    end
  end

  defp apply_text_role(out, inner, _n, _pal), do: {out, inner}

  # Heading declarations by clamped level (article palette). Sizes descend
  # h1 > h2 > h3; h1/h2 use weight 700, h3 weight 600. Sans heading font.
  defp heading_style(1, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "letter-spacing:-0.02em",
      "line-height:1.1",
      "margin:1.6rem 0 0.8rem",
      "font-weight:700",
      "font-size:32px"
    ]
  end

  defp heading_style(2, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.2",
      "margin:1.4rem 0 0.6rem",
      "font-weight:700",
      "font-size:24px"
    ]
  end

  defp heading_style(_3, pal) do
    [
      "font-family:#{pal.font_heading}",
      "color:#{pal.text}",
      "line-height:1.25",
      "margin:1.2rem 0 0.5rem",
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
      (case Map.get(n, "width") do
         nil -> ""
         w -> ~s( width="#{w}")
       end) <>
        (case Map.get(n, "height") do
           nil -> ""
           h -> ~s( height="#{h}")
         end)

    ~s(<img src="#{safe_url(Map.get(n, "src", ""))}" alt="#{escape_attr(Map.get(n, "alt", ""))}" style="max-width:100%;height:auto"#{dims}>)
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
end
