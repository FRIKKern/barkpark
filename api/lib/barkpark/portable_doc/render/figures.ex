defmodule Barkpark.PortableDoc.Render.Figures do
  @moduledoc """
  Standalone figure / code-block / divider HTML emission for the PortableDoc
  render engine — the `_raw` escape-hatch markup that must reach the DOM
  byte-exact (Mermaid's `pre.mermaid` selector, the asciinema mount point).

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). These helpers are leaf string emitters — they depend only
  on `Render.Util` (escape / safe_url) and the mono-font constant. The generic
  `figure_html` (which recurses through compose_block + walk) stays in the
  Compose family, not here. Output is byte-identical to the pre-split engine.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1, safe_url: 1]

  @font_mono Barkpark.PortableDoc.Render.Palettes.font_mono()

  # ── article block HTML emission (code / section divider) ───────────────────

  # A single styled `<pre>` code block for article mode: monospace, parchment
  # `#f1ede2` background, a 3px terracotta `#a23925` left-border, padding, and
  # horizontal scroll on overflow. The value is HTML-escaped (the `<pre>` shows
  # source verbatim, so no Mermaid `pre.mermaid` selector concern here).
  def code_block_html(value) do
    ~s|<pre style="background:var(--paper-bg-deep, #f5f2e9);border:0;border-radius:0;border-left:3px solid var(--paper-accent, #a23925);color:var(--paper-ink, #1a1a1a);padding:0.9rem 1.1rem;| <>
      ~s|margin:1.2rem 0;font-family:#{@font_mono};font-size:0.9rem;line-height:1.5;| <>
      ~s|overflow-x:auto;white-space:pre">#{escape_html(value)}</pre>|
  end

  # The doc.css `hr.section` look: a centered "§" glyph straddling a hairline
  # rule. The glyph sits in an inline-block box with the parchment page colour
  # as its background, masking the rule that runs behind it across the column.
  def section_divider_html do
    ~s|<div style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid var(--paper-rule, #e6e2d8)">| <>
      ~s|<span style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;| <>
      ~s|background:var(--paper-bg-deep, #f5f2e9);color:var(--paper-ink-soft, #6a6a6a);font-size:1.1rem">§</span></div>|
  end

  # ── diagram / figure HTML emission ─────────────────────────────────────────

  # Entity-encode ONLY the three structural chars Mermaid source can carry
  # (`&` first, then `<` `>`) — NOT quotes/apostrophes. The encoded text lives
  # as the text content of `<pre class="mermaid">`, so it survives the static
  # body_html extractor unchanged AND Mermaid's runtime reads `textContent`
  # (which the browser decodes back to the literal `&`/`<`/`>`). Encoding quotes
  # would be wrong here: Mermaid label syntax uses them and they're harmless as
  # element text.
  def encode_mermaid(source) when is_binary(source) do
    source
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Bold "Figure N." run-in: split a "Figure 1. rest" caption so the leading
  # "Figure N." is bolded and the remainder stays plain. Falls back to the whole
  # caption (no bold) when it doesn't match the convention.
  def figcaption_inner(""), do: ""

  def figcaption_inner(caption) do
    case Regex.run(~r/^(Figure\s+\S+?\.)\s*(.*)$/s, caption) do
      [_, lead, rest] ->
        rest_html = if rest == "", do: "", else: " " <> escape_html(rest)
        "<b>#{escape_html(lead)}</b>" <> rest_html

      _ ->
        escape_html(caption)
    end
  end

  # The canonical paper-article figure for a Mermaid diagram. Article mode: a
  # bordered, parchment, inset card mirroring doc.css `figure`; the figcaption
  # is muted/italic with the bold "Figure N." run-in. Email mode degrades to the
  # caption line + the source as a plain code block (Mermaid never runs there).
  def diagram_html(source, caption, :article) do
    cap =
      if caption == "" do
        ""
      else
        ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #6a6a6a);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif">#{figcaption_inner(caption)}</figcaption>|
      end

    ~s|<figure style="margin:1.6rem 0;padding:1.2rem;background:var(--paper-bg-deep, #f5f2e9);border:1px solid var(--paper-rule, #e6e2d8);border-radius:4px">| <>
      ~s(<pre class="mermaid">#{encode_mermaid(source)}</pre>) <>
      cap <>
      "</figure>"
  end

  def diagram_html(source, caption, _style) do
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
  def asciicast_html(src, caption, :article) do
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

  def asciicast_html(src, caption, _style) do
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
end
