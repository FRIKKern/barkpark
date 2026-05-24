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

  @doc """
  Render a Pd-tree `root` to an HTML string.

  Options (a map):

    * `:doctype` — wrap the body in a full `<!doctype html>…</html>` document.
      Defaults to `true`; pass `false` to emit only the body fragment.
    * `:container_width` — outer width budget in px. Defaults to `600`.
  """
  def render_html(root, opts \\ %{}) do
    width = Map.get(opts, :container_width, @default_width)
    body = walk(root, width)

    if Map.get(opts, :doctype, true) == false do
      body
    else
      ~s(<!doctype html><html><head><meta charset="utf-8"></head>) <>
        ~s(<body style="background:#{@page_bg};margin:0;padding:0;">) <>
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
    block
    |> resolve_ref_title(opts)
    |> resolve_code_label(opts)
    |> compose_block()
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

  @doc false
  def compose_block(%{"type" => "heading"} = b) do
    %{"kind" => "PdText", "weight" => "bold", "children" => [Map.get(b, "text", "")]}
  end

  def compose_block(%{"type" => "paragraph"} = b) do
    %{"kind" => "PdText", "children" => compose_inline_children(Map.get(b, "content", []))}
  end

  def compose_block(%{"type" => "list"} = b) do
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

  def compose_block(%{"type" => "callout"} = b) do
    body = %{"kind" => "PdText", "children" => compose_inline_children(Map.get(b, "content", []))}

    base = %{"kind" => "PdCallout", "tone" => Map.get(b, "tone"), "children" => [body]}
    maybe_put(base, "title", Map.get(b, "title"))
  end

  def compose_block(%{"type" => "action"} = b) do
    %{
      "kind" => "PdButton",
      "href" => Map.get(b, "href", ""),
      "label" => Map.get(b, "label", ""),
      "priority" => Map.get(b, "priority")
    }
  end

  def compose_block(%{"type" => "section"} = b) do
    leading = [%{"kind" => "PdHr"}]

    title =
      case Map.get(b, "title") do
        nil -> []
        t -> [%{"kind" => "PdText", "weight" => "bold", "children" => [t]}]
      end

    inner = Enum.map(Map.get(b, "blocks", []), &compose_block/1)

    children = leading ++ title ++ inner ++ [%{"kind" => "PdHr"}]
    %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => children}
  end

  def compose_block(%{"type" => "divider"}), do: %{"kind" => "PdHr"}

  def compose_block(%{"type" => "code"} = b) do
    children =
      Map.get(b, "value", "")
      |> String.split("\n")
      |> Enum.map(fn line ->
        %{"kind" => "PdText", "children" => [%{"kind" => "PdInlineCode", "value" => line}]}
      end)

    %{"kind" => "PdBox", "style" => %{"flexDirection" => "column"}, "children" => children}
  end

  def compose_block(%{"type" => "image"} = b) do
    %{"kind" => "PdImage", "src" => Map.get(b, "src", ""), "alt" => Map.get(b, "alt", "")}
    |> maybe_put("width", Map.get(b, "width"))
    |> maybe_put("height", Map.get(b, "height"))
  end

  def compose_block(%{"type" => "table"} = b) do
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

  def compose_block(%{"type" => "field-string"} = b), do: field_row(b, field_value_text(b))
  def compose_block(%{"type" => "field-slug"} = b), do: field_row(b, field_value_text(b))
  def compose_block(%{"type" => "field-text"} = b), do: field_row(b, field_value_text(b))

  def compose_block(%{"type" => "field-boolean"} = b) do
    field_row(b, if(Map.get(b, "value") == true, do: "Yes", else: "No"))
  end

  def compose_block(%{"type" => "field-select"} = b) do
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

  def compose_block(%{"type" => "field-datetime"} = b) do
    field_row(b, format_datetime(Map.get(b, "value", "")))
  end

  def compose_block(%{"type" => "field-color"} = b) do
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
  def compose_block(%{"type" => "field-reference"} = b) do
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
  def compose_block(%{"type" => "field-image"} = b) do
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
  def compose_block(%{"type" => "composite"} = b) do
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
  def compose_block(%{"type" => "arrayOf"} = b) do
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
  def compose_block(%{"type" => "codelist"} = b) do
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
  def compose_block(%{"type" => "localizedText"} = b) do
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

  def compose_block(%{"type" => type}) do
    raise ArgumentError, "compose_block: unhandled block type #{type}"
  end

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

  defp walk(%{"kind" => "PdContainer"} = n, width), do: container(n, width)
  defp walk(%{"kind" => "PdBox"} = n, width), do: box(n, width)
  defp walk(%{"kind" => "PdText"} = n, width), do: text(n, width)
  defp walk(%{"kind" => "PdLink"} = n, width), do: link(n, width)

  defp walk(%{"kind" => "PdInlineCode"} = n, _width) do
    ~s(<code style="background:#f3f4f6;padding:2px 6px;font-family:#{@font_mono};font-size:0.95em">) <>
      escape_html(Map.get(n, "value", "")) <> "</code>"
  end

  defp walk(%{"kind" => "PdButton"} = n, _width), do: button(n)
  defp walk(%{"kind" => "PdHr"} = n, _width), do: hr(n)
  defp walk(%{"kind" => "PdImage"} = n, _width), do: image(n)
  defp walk(%{"kind" => "PdTable"} = n, width), do: table(n, width)
  defp walk(%{"kind" => "PdCallout"} = n, width), do: callout(n, width)

  defp walk(%{"kind" => kind}, _width) do
    raise ArgumentError, "render_html: unhandled #{kind}"
  end

  # ── per-kind renderers ──────────────────────────────────────────────────────

  defp container(n, width) do
    # Trap: clamp container width with min(maxWidth, width).
    # Match TS `n.maxWidth ?? width` (nullish, not falsy) so a literal `0`
    # maxWidth is honored rather than silently replaced by the budget.
    w = min(Map.get(n, "maxWidth", width), width)
    inner = render_children(Map.get(n, "children", []), w)

    ~s(<div style="max-width:#{w}px;margin:0 auto;padding:24px;font-family:#{@font_body};color:#111827;background:#ffffff">) <>
      inner <> "</div>"
  end

  defp box(n, width) do
    inner = render_children(Map.get(n, "children", []), width)
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

  defp text(n, width) do
    # Trap: PdText.children mixes raw strings (escaped) and child nodes (recursed).
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width)
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
    out = Enum.reverse(out)

    # Trap: emit NO style= attr when the style list is empty.
    if out == [] do
      "<span>#{inner}</span>"
    else
      ~s(<span style="#{Enum.join(out, ";")}">#{inner}</span>)
    end
  end

  defp link(n, width) do
    # Trap: PdLink.children mixes raw strings (escaped) and child nodes (recursed).
    inner =
      Map.get(n, "children", [])
      |> Enum.map(fn
        k when is_binary(k) -> escape_html(k)
        k -> walk(k, width)
      end)
      |> Enum.join("")

    ~s(<a href="#{safe_url(Map.get(n, "href", ""))}" style="color:#1d4ed8;text-decoration:underline">#{inner}</a>)
  end

  defp button(n) do
    label = escape_html(Map.get(n, "label", ""))
    href = safe_url(Map.get(n, "href", ""))

    if Map.get(n, "priority") == "primary" do
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;background:#{@brand};color:#{@brand_text};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    else
      ~s(<a href="#{href}" style="display:inline-block;padding:10px 20px;border:2px solid #{@brand};color:#{@brand};text-decoration:none;font-weight:bold;border-radius:0">#{label}</a>)
    end
  end

  defp hr(n) do
    t = Map.get(n, "thickness") || 1
    ~s(<hr style="border:none;border-top:#{t}px solid #{@rule};margin:16px 0">)
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

  defp table(n, width) do
    rows =
      Map.get(n, "rows", [])
      |> Enum.map(fn row ->
        cells =
          row
          |> Enum.map(fn cell ->
            inner = render_children(cell, width)
            ~s(<td style="border:1px solid #{@rule};padding:8px 12px;vertical-align:top">#{inner}</td>)
          end)
          |> Enum.join("")

        "<tr>#{cells}</tr>"
      end)
      |> Enum.join("")

    ~s(<table role="presentation" style="border-collapse:collapse;width:100%">#{rows}</table>)
  end

  defp callout(n, width) do
    pal = tone_palette(Map.get(n, "tone"))

    title_html =
      case Map.get(n, "title") do
        nil -> ""
        "" -> ""
        title -> "<strong>#{escape_html(title)}</strong> "
      end

    inner = render_children(Map.get(n, "children", []), width)

    ~s(<div style="border-left:4px solid #{pal.fg};background:#{pal.bg};padding:16px;color:#{pal.fg}">#{title_html}#{inner}</div>)
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp render_children(children, width) do
    children
    |> Enum.map(&walk(&1, width))
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
