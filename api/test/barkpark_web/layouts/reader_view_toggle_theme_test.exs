defmodule BarkparkWeb.Layouts.ReaderViewToggleThemeTest do
  @moduledoc """
  The reader's view-toggle pills (Mode / TUI view / Email view, bottom-right of
  `/papers/:slug`) must take their chrome from the paper palette, not from a
  hand-typed color.

  The pills FLOAT over the article ground, so they follow it or they fight it.
  Every other floating affordance in `layouts/bulldocs.html.heex` already does:
  `.bp-paper-actions` stands on `var(--paper-bg)` / `var(--paper-rule)`, and
  `.bp-image-lightbox__*` on the `Canvas` / `CanvasText` system pair. The pills
  alone were `#2f6b4e` ink on `rgba(255,255,255,0.86)` — a white pill stranded
  on a dark article, the Mode pill that advertises dark mode included.

  This is deliberately a RULE, not a list of the two selectors that were wrong.
  The sheet theme-swaps SIX palettes (base + five `data-bp-theme` skins) across
  four routes (`prefers-color-scheme`, stamped `html[data-theme]`, `@media
  print`, and the no-JS first paint); a per-arm dark companion would have to be
  written twenty-four times and would rot the moment a seventh skin lands.
  Reading `--paper-*` covers all of them at once, so the guard asserts exactly
  that: in any pill rule that is NOT scoped to a fixed-ground view, a color
  value is token-derived.

  `body.bp-tui` is the one exemption and it is a real one: the TUI view renders
  the REAL pdrender output on a terminal-dark ground that does not follow the
  paper theme, so its pill literals (`#5fcf9c` on `rgba(10,15,12,0.9)`) are
  correct AS literals. The test uses that arm as its own positive control — if
  the scanner stops seeing hex there, the scanner is broken, not the sheet.
  """
  use ExUnit.Case, async: true

  @bulldocs Path.expand(
              "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
              __DIR__
            )

  # Selectors that pin the pill onto a ground which does NOT follow the paper
  # palette. A selector earns a place here only by being provably fixed-ground.
  @fixed_ground ["body.bp-tui"]

  # INK + GROUND. These are the properties that decide whether the pill reads as
  # light or dark, so NO literal survives here — not a hex and not an
  # `rgba()` either: the pill's old ground was `rgba(255,255,255,0.86)`, a pure
  # white with no `#` in sight, and a hex-only detector would let exactly the
  # reported defect back in one property over.
  @ground_props ~w(color background background-color border-color outline-color)

  # OVERLAY + shorthand. A translucent `rgba()` drop shadow reads the same over
  # either ground (that is what an overlay IS), so these are held only to the
  # no-bare-hex bar.
  @overlay_props ~w(border border-top border-right border-bottom border-left
                    outline box-shadow fill stroke)

  @color_props @ground_props ++ @overlay_props

  defp sheet, do: File.read!(@bulldocs)

  # Strip /* … */ so a PR ref or a hex quoted in prose never counts as paint.
  defp strip_comments(css), do: Regex.replace(~r|/\*.*?\*/|s, css, " ")

  # Every flat CSS rule whose selector list names a view-toggle part, as
  # {selector, declarations}. `[^{}]*` cannot cross a brace, so the text it
  # captures before `{` is the selector list — inside an @media just the same.
  defp pill_rules(css) do
    ~r/([^{}]*\.bp-(?:view-toggle|vt-dot)[^{}]*)\{([^{}]*)\}/
    |> Regex.scan(css)
    |> Enum.map(fn [_, sel, body] ->
      {sel |> String.trim() |> String.replace(~r/\s+/, " "), body}
    end)
  end

  defp fixed_ground?(sel), do: Enum.any?(@fixed_ground, &String.contains?(sel, &1))

  # {property, value} pairs that paint, for one rule body.
  defp paint_decls(body) do
    body
    |> String.split(";")
    |> Enum.flat_map(fn decl ->
      case String.split(decl, ":", parts: 2) do
        [prop, value] ->
          prop = prop |> String.trim() |> String.downcase()
          if prop in @color_props, do: [{prop, String.trim(value)}], else: []

        _ ->
          []
      end
    end)
  end

  # A bare hex color. `(?<!&)` keeps `&#160;`-style character references out,
  # the same lookbehind scripts/studio-literal-check.sh carries.
  @hex ~r/(?<!&)#[0-9a-fA-F]{3,8}\b/

  # A hex inside `var(--token, #hex)` is the FALLBACK floor, not the paint: every
  # arm of this sheet declares `--paper-*`, so the token is what resolves and the
  # literal is what the sheet's own `var(--paper-*, hex)` convention writes
  # beside it. Peel `var(…)` spans innermost-first (so a `var()` nested inside a
  # `color-mix()` goes too) and scan what is LEFT — which is where a hand-typed
  # color would actually sit.
  defp strip_vars(value) do
    stripped = Regex.replace(~r/var\([^()]*\)/, value, " ")
    if stripped == value, do: value, else: strip_vars(stripped)
  end

  # An `rgb()` / `rgba()` / `hsl()` function VALUE — a hand-written channel
  # triple. `color-mix()` is NOT one: it is how a token is tinted.
  @channel_fn ~r/\b(?:rgba?|hsla?)\(/

  defp literal_paint?(prop, value) do
    rest = strip_vars(value)

    Regex.match?(@hex, rest) or
      (prop in @ground_props and Regex.match?(@channel_fn, rest))
  end

  test "the scanner sees the sheet it claims to scan" do
    rules = sheet() |> strip_comments() |> pill_rules()

    assert length(rules) >= 8,
           "parsed #{length(rules)} view-toggle rules out of bulldocs.html.heex — the pill " <>
             "block moved or renamed, so every verdict below is vacuous."

    assert Enum.any?(rules, fn {sel, _} -> fixed_ground?(sel) end),
           "no body.bp-tui pill rule found — the fixed-ground exemption has no subject."

    # POSITIVE CONTROL: the exempt arm really does carry hex literals. If this
    # ever stops firing, the hex detector is dead and the real assertion below
    # is green for the wrong reason.
    tui_paint =
      rules
      |> Enum.filter(fn {sel, _} -> fixed_ground?(sel) end)
      |> Enum.flat_map(fn {_, body} -> paint_decls(body) end)

    assert Enum.any?(tui_paint, fn {p, v} -> literal_paint?(p, v) end),
           "the body.bp-tui pill arm carries no hex literal — the hex detector cannot " <>
             "distinguish a token from a literal, so this suite proves nothing. Scanned: " <>
             inspect(tui_paint)
  end

  test "every theme-following pill rule takes its color from the paper palette" do
    rules = sheet() |> strip_comments() |> pill_rules()

    scanned =
      for {sel, body} <- rules,
          not fixed_ground?(sel),
          {prop, value} <- paint_decls(body),
          do: {sel, prop, value}

    assert scanned != [],
           "zero paint declarations scanned across the theme-following pill rules — the " <>
             "@color_props list or the rule parser no longer matches the sheet."

    offenders =
      for {sel, prop, value} <- scanned,
          literal_paint?(prop, value),
          do: "#{sel} { #{prop}: #{value} }"

    assert offenders == [],
           """
           Reader view-toggle pills carry a hand-typed color.

           These pills float over the article ground and must follow it: take the
           value from the paper palette — `var(--paper-accent)`, `var(--paper-bg)`,
           `var(--paper-rule)`, or a `color-mix()` over one — the way
           `.bp-paper-actions` already does. A literal here paints the same chrome
           in every one of the six palettes and both modes, which is how the white
           pill ended up stranded on the dark article.

           If the rule genuinely sits on a ground that does NOT follow the paper
           theme (the way `body.bp-tui` does), scope it that way and add the
           selector to @fixed_ground with the reason.

           #{Enum.join(Enum.sort(offenders), "\n           ")}
           """
  end
end
