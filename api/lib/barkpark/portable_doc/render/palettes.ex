defmodule Barkpark.PortableDoc.Render.Palettes do
  @moduledoc """
  Per-render palettes (and the colour / font / width constants they draw on)
  for the PortableDoc render engine.

  A `palette` is the per-render context threaded through `walk/3`. The DEFAULT
  is `:email` — its values are the module constants, so existing call sites
  that pass no `:style` are byte-identical to before. `:article` mirrors
  doc.css `:root` (serif body, parchment bg, terracotta accent) for the
  native paper-article surface. The palette also carries `:style` so the
  compose / walk clauses that diverge by mode (headings, eyebrow, byline,
  ingress) can branch on it.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). The constants are re-exported as `0`-arity functions so the
  Walk / Figures / Forms families can reference them without sharing module
  attributes.
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

  @doc false
  def font_body, do: @font_body
  @doc false
  def font_mono, do: @font_mono
  @doc false
  def brand, do: @brand
  @doc false
  def brand_text, do: @brand_text
  @doc false
  def rule, do: @rule
  @doc false
  def page_bg, do: @page_bg
  @doc false
  def default_width, do: @default_width

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

  @doc false
  def palette_for(:article), do: article_palette()
  def palette_for(_), do: email_palette()
end
