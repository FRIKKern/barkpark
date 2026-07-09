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

  alias Barkpark.PortableDoc.Render.TokensGen

  # Font names are wrapped in single quotes inside CSS so the surrounding
  # double-quoted style attribute stays valid HTML. (Embedding `"SF Pro Text"`
  # directly would terminate the attribute at the first `"`.)
  @font_body "'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif"
  @font_mono "ui-monospace,Menlo,monospace"
  # Evergreen profile — the same brand the reader, Studio, TUI and web carry.
  # Sourced VERBATIM from design/tokens.json paperEmail via TokensGen (theme-
  # system Wave 1 CAPTURE). NOTE: these deliberately DIVERGE from TokensGen's
  # HSL-derived brand/rule (#1e5243/#e4e4e7) — email bytes ship to mail clients,
  # so the drifted slots would retint the byte-locked golden; w3 reconciles.
  @brand TokensGen.email_brand()
  @brand_text TokensGen.email_brand_text()
  @rule TokensGen.email_rule()
  @page_bg TokensGen.email_page_bg()

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
      paper: TokensGen.email_paper(),
      text: TokensGen.email_text(),
      muted: TokensGen.email_muted(),
      rule: @rule,
      accent: @brand,
      link_color: @brand,
      code_bg: TokensGen.email_code_bg()
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
      # The `var(--paper-*, <fallback>)` fallbacks ship as HTML bytes when the
      # render lands outside a `.bp-paper-surface` context (paper.html.heex, an
      # email backend), so they MUST come from the same captured paperEmail hex
      # as the email palette above — never a re-typed literal.
      bg: "var(--paper-bg-deep, #{TokensGen.email_page_bg()})",
      paper: "var(--paper-bg, #{TokensGen.email_paper()})",
      text: "var(--paper-ink, #{TokensGen.email_text()})",
      muted: "var(--paper-ink-soft, #{TokensGen.email_muted()})",
      rule: "var(--paper-rule, #{TokensGen.email_rule()})",
      accent: "var(--paper-accent, #{TokensGen.email_brand()})",
      link_color: "var(--paper-accent, #{TokensGen.email_brand()})",
      code_bg: "var(--paper-bg-deep, #{TokensGen.email_code_bg()})"
    }
  end

  @doc false
  def palette_for(:article), do: article_palette()
  def palette_for(_), do: email_palette()
end
