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
  #
  # Fonts are theme-INVARIANT (charter D28) — they stay compile-time constants.
  @font_body "'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif"
  @font_mono "ui-monospace,Menlo,monospace"

  @default_width 600

  # Default theme id. Every colour accessor below defaults to it, so a caller
  # that passes no theme gets byte-identical output to the pre-theme constants.
  @default_theme :evergreen

  # The email-skin slots a theme override map may set (Map.take guards against
  # a caller injecting stray keys into the merged skin).
  @skin_keys [:brand, :brand_text, :rule, :page_bg, :paper, :text, :muted, :code_bg]

  @doc false
  def font_body, do: @font_body
  @doc false
  def font_mono, do: @font_mono
  @doc false
  def default_width, do: @default_width

  # ── Theme-resolved email skin (charter D28 relocation) ──────────────────────
  #
  # The brand/rule/page-bg colours were compile-time module attributes frozen to
  # evergreen at BEAM compile. They are now RUNTIME functions taking a `theme`
  # threaded from `Render.render_html(opts[:theme])`. The `theme` is EITHER:
  #
  #   * a theme IDENTITY (atom/string id) — resolved through the theme-keyed
  #     `TokensGen` (evergreen this wave; unknown/nil/empty → evergreen), or
  #   * a MAP of `{slot => value}` overrides merged over the resolved evergreen
  #     skin — the ts-w4b fixture-theme seam and the positive-proof test, i.e.
  #     the live end of the thread that proves a non-evergreen theme moves bytes.
  #
  # Evergreen (the default) stays VERBATIM the captured paperEmail hand hex —
  # NOT TokensGen's HSL-derived brand/rule (#1e5243/#e4e4e7), which are drifted
  # from the byte-locked email golden. So email bytes ship unretinted; w3
  # reconciles the two slots.
  @doc false
  def email_skin(theme \\ @default_theme)

  def email_skin(theme) when is_map(theme),
    do: Map.merge(TokensGen.email_skin(@default_theme), Map.take(theme, @skin_keys))

  def email_skin(theme), do: TokensGen.email_skin(theme)

  @doc false
  def brand(theme \\ @default_theme), do: email_skin(theme).brand
  @doc false
  def brand_text(theme \\ @default_theme), do: email_skin(theme).brand_text
  @doc false
  def rule(theme \\ @default_theme), do: email_skin(theme).rule
  @doc false
  def page_bg(theme \\ @default_theme), do: email_skin(theme).page_bg

  @doc false
  def email_palette(theme \\ @default_theme) do
    s = email_skin(theme)

    %{
      style: :email,
      font_body: @font_body,
      font_heading: @font_body,
      width: @default_width,
      bg: s.page_bg,
      paper: s.paper,
      text: s.text,
      muted: s.muted,
      rule: s.rule,
      accent: s.brand,
      link_color: s.brand,
      code_bg: s.code_bg,
      # The primary-action button foreground (walk.ex button/2) — was the
      # compile-time @brand_text; carried on the palette so the walker flips it
      # with the theme.
      brand_text: s.brand_text
    }
  end

  @doc false
  def article_palette(theme \\ @default_theme) do
    s = email_skin(theme)
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
      bg: "var(--paper-bg-deep, #{s.page_bg})",
      paper: "var(--paper-bg, #{s.paper})",
      text: "var(--paper-ink, #{s.text})",
      muted: "var(--paper-ink-soft, #{s.muted})",
      rule: "var(--paper-rule, #{s.rule})",
      accent: "var(--paper-accent, #{s.brand})",
      link_color: "var(--paper-accent, #{s.brand})",
      code_bg: "var(--paper-bg-deep, #{s.code_bg})",
      # Primary-action button foreground (walk.ex button/2) — the raw skin hex
      # (no var(): the button fg is not a `--paper-*` role), flips with theme.
      brand_text: s.brand_text
    }
  end

  @doc false
  def palette_for(style, theme \\ @default_theme)
  def palette_for(:article, theme), do: article_palette(theme)
  def palette_for(_, theme), do: email_palette(theme)
end
