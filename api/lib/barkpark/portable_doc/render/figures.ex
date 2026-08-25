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

  # The code-block bar is a reading-character cue (its TUI twin is
  # `Theme.CodeBar`/`ReadingAccent`), so it draws on the article reading accent —
  # the terracotta `--paper-reading-accent`, tokenized in `TokensGen` and threaded
  # through the palette (charter D8). Compile-time bound from `Palettes` (same as
  # `@font_mono`) so the fallback hex stays sourced, never a re-typed literal.
  @reading_accent Barkpark.PortableDoc.Render.Palettes.article_reading_accent()

  # ── article block HTML emission (code / section divider) ───────────────────

  # A single styled `<pre>` code block for article mode: monospace, cool
  # near-white `--paper-bg-deep` ground, a 3px **terracotta** left-border (the
  # reading accent, `var(--paper-reading-accent, #a23925)`), padding, and
  # horizontal scroll on overflow. The value is HTML-escaped (the `<pre>` shows
  # source verbatim, so no Mermaid `pre.mermaid` selector concern here).
  def code_block_html(value) do
    ~s|<pre style="background:var(--paper-bg-deep, #eaf1ee);border:0;border-radius:var(--bp-codeblock-radius, 0);border-left:var(--bp-codeblock-accent-w, 3px) solid #{@reading_accent};color:var(--paper-ink, #15211d);padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);| <>
      ~s|margin:var(--bp-codeblock-margin, 1.2rem 0);font-family:var(--paper-font-mono, #{@font_mono});font-size:var(--bp-codeblock-size, 0.9rem);line-height:var(--bp-codeblock-lh, 1.5);| <>
      ~s|overflow-x:auto;white-space:pre">#{escape_html(value)}</pre>|
  end

  # The doc.css `hr.section` look: a centered "§" glyph straddling a hairline
  # rule. The glyph sits in an inline-block box with the parchment page colour
  # as its background, masking the rule that runs behind it across the column.
  #
  # The `bp-section-divider` class carries NO styling here — every value stays
  # inline, and view_edit_parity_test.exs §8 still compares those inline
  # declarations against the edit mirror. It is a HANDLE: this was the last
  # article block emitting a class-less box, so the reader shell had no way to
  # say anything about a divider's position, and "a divider that sits directly in
  # front of a section head is drawing a boundary the head already draws" is
  # exactly such a claim (paper-surface.css, §divider dedup). The name is the one
  # the edit surface has bound its mirror to since the divider-lockstep slice
  # (`.bp-section-divider` / `.bp-section-divider__mark`), so this closes an
  # asymmetry rather than inventing a second vocabulary for one block.
  def section_divider_html do
    ~s|<div class="bp-section-divider" style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid var(--paper-rule, #dde7e2)">| <>
      ~s|<span class="bp-section-divider__mark" style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;| <>
      ~s|background:var(--paper-bg-deep, #eaf1ee);color:var(--paper-ink-soft, #55635e);font-size:1.1rem">§</span></div>|
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

  # The EVIDENCE BREAKOUT rides these inline styles rather than a stylesheet rule,
  # for the same reason the air beat above it does: a figure has to survive a sink
  # with no paper-surface.css, so the width and the re-centering pull are inline
  # `var(--bp-evidence-*, <fallback>)` reads. Every fallback resolves to "stay in
  # the column" (`100%` / `0px`), so a stylesheet-less sink loses the breakout and
  # nothing else. ARTICLE MODE ONLY — the email/default clauses below keep their
  # flat `margin:16px 0` and no width at all, because an email client has neither
  # a container to measure nor a viewport worth breaking out of.
  #
  # The canonical paper-article figure for a Mermaid diagram. Article mode: a
  # bordered, parchment, inset card mirroring doc.css `figure`; the figcaption
  # is muted/italic with the bold "Figure N." run-in. Email mode degrades to the
  # caption line + the source as a plain code block (Mermaid never runs there).
  def diagram_html(source, caption, :article) do
    cap =
      if caption == "" do
        ""
      else
        ~s|<figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">#{figcaption_inner(caption)}</figcaption>|
      end

    ~s|<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;padding:1.2rem;background:var(--paper-bg-deep, #eaf1ee);border:1px solid var(--paper-rule, #dde7e2);border-radius:4px;overflow-x:auto">| <>
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
  #
  # `poster` is the block's OPTIONAL resting frame — the asciinema-player
  # `poster` option, an npt timestamp (`"npt:1:23"`) or `"end"`. A recording
  # that opens on a banner and a reading pause posters as near-empty black at
  # the hardcoded `npt:0:1` default, so a block may name a later, FULL frame.
  # It rides `data-cast-poster` and is emitted ONLY when set — an unset poster
  # leaves the mount byte-identical to before, so every existing paper (and the
  # pd-golden/pd-parity fixtures) is untouched and the two client twins keep
  # owning the `npt:0:1` fallback. The value is attribute-escaped and handed to
  # the player verbatim (asciinema ignores a poster it cannot parse); it is NOT
  # a URL, so `safe_url` (the `src`/video-poster helper) does not apply.
  def asciicast_html(src, caption, poster, style),
    do: asciicast_html(src, caption, poster, nil, style)

  def asciicast_html(src, caption, poster, rows, :article) do
    cap =
      if caption == "" do
        ""
      else
        # `~s|…|`, not `~s(…)`: the caption measure is a `var(…)` read, and a
        # paren-delimited sigil ends at the first `)` — the same reason the
        # diagram figcaption above already uses the pipe form.
        ~s|<figcaption style="margin-top:0.8rem;color:#55635e;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">#{figcaption_inner(caption)}</figcaption>|
      end

    poster_attr =
      if poster == "", do: "", else: ~s( data-cast-poster="#{escape_html(poster)}")

    rows_attr =
      if is_integer(rows) and rows in 6..40, do: ~s( data-cast-rows="#{rows}"), else: ""

    ~s|<figure style="margin:var(--bp-air-asciicast, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">| <>
      ~s(<div class="bp-asciicast" data-cast-src="#{safe_url(src)}"#{poster_attr}#{rows_attr} style="border:1px solid #dde7e2;border-radius:6px;overflow:hidden"></div>) <>
      cap <>
      "</figure>"
  end

  def asciicast_html(src, caption, _poster, _rows, _style) do
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

  # Plain `<video>` file block (B062) — a native browser element, zero client
  # JS. Article mode emits the real `<video controls>` (plus optional
  # `poster`/`loop` attrs and a `<track>` per caption); email/default has no
  # video runtime, so it degrades to the poster image (if any) linking to the
  # src, else a plain "Watch the video" link (the asciicast degrade
  # precedent). `captions` is a pre-filtered list of `%{"lang" => …, "src" =>
  # …}` maps — the compose_block caller owns that filtering.
  def video_html(src, poster, captions, loop, :article) do
    poster_attr = if poster == "", do: "", else: ~s( poster="#{safe_url(poster)}")
    loop_attr = if loop, do: " loop", else: ""

    tracks =
      Enum.map_join(captions, "", fn c ->
        lang = Map.get(c, "lang", "")
        track_src = Map.get(c, "src", "")
        lang_attr = if lang == "", do: "", else: ~s( srclang="#{escape_html(lang)}")
        ~s(<track kind="captions"#{lang_attr} src="#{safe_url(track_src)}">)
      end)

    ~s|<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto">| <>
      ~s(<video controls playsinline style="max-width:100%;border-radius:6px"#{poster_attr}#{loop_attr} src="#{safe_url(src)}">) <>
      tracks <>
      "</video></figure>"
  end

  def video_html(src, poster, _captions, _loop, _style) do
    poster_img =
      if poster == "" do
        ""
      else
        ~s(<img src="#{safe_url(poster)}" alt="" style="max-width:100%;border-radius:6px;display:block;margin-bottom:8px">)
      end

    ~s(<figure style="margin:16px 0">) <>
      poster_img <>
      ~s(<a href="#{safe_url(src)}">Watch the video</a>) <>
      "</figure>"
  end
end
