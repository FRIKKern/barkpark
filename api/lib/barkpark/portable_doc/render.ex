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

    if Regex.match?(@allowed_scheme, trimmed) do
      escape_attr(trimmed)
    else
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
