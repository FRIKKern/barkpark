defmodule Barkpark.PortableDoc.Render.ArticleThemeColourTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{Palettes, ParityFixture, TokensGen}
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  # ── no inline THEME colour on `:article` output (task-10ca9c3597695db7) ─────
  #
  # article_inline_allowlist_test pins the inline property NAMES, and states its
  # own hole: a THEME value riding a name that also has a permanent DATA use
  # (`color`, `background`) slips past it. This test is keyed on VALUES. It
  # renders the all-kinds fixture as `:article` in every theme and collects every
  # colour inside a `style="…"` attribute. A colour is author DATA only when the
  # fixture itself wrote it; anything else is the renderer's own paint, and on
  # `:article` the paper-surface stylesheet owns that paint (View and Edit by
  # construction). So:
  #
  #   * no `var(--paper-*)` token rides inline — the token IS the theme;
  #   * no colour of the theme's palette rides inline unless the fixture
  #     authored that exact hex.
  #
  # The `:email` control renders the same fixture with the same detector and must
  # FIND palette colours: email inlines its whole theme, so a detector that comes
  # back empty there is blind, not proof.

  # A colour: a hex, an rgb()/rgba(), or a `--paper-*` token (not the
  # `--paper-font-*` faces, which are type, not paint).
  @colour ~r/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|var\(--paper-(?!font-)[a-z-]+/

  # ── the block-level sweep (task-ef9f386f8cb5e32a) ────────────────────────────
  #
  # The same detector over every pd-parity fixture, one block type at a time.
  # @known is a SHRINK-ONLY ratchet: the block types that still inline a theme
  # colour on `:article` today, each a slice of the follow-up row. An unlisted
  # type that inlines one fails (a new theme style), and a listed type that comes
  # back clean fails too, so its entry leaves the list in the diff that fixed it.
  @known MapSet.new(~w(code code-tabs diagram))

  test "in every theme, :article output carries no inline var(--paper-*) and no palette colour the fixture did not author" do
    authored = authored_colours()

    for theme <- TokensGen.themes() do
      colours = inline_colours(render(:article, theme))
      tokens = Enum.filter(colours, &String.starts_with?(&1, "var(--paper-"))
      theme_paint = colours |> MapSet.intersection(palette(theme)) |> MapSet.difference(authored)

      assert tokens == [], "#{theme}: :article inlines theme tokens #{inspect(tokens)}"

      assert MapSet.size(theme_paint) == 0,
             "#{theme}: :article inlines palette colours #{inspect(MapSet.to_list(theme_paint))}"
    end
  end

  test "control: the same detector finds the palette inline in :email output, in every theme" do
    for theme <- TokensGen.themes() do
      found = inline_colours(render(:email, theme)) |> MapSet.intersection(palette(theme))

      assert MapSet.size(found) >= 3,
             "#{theme}: the detector saw #{inspect(MapSet.to_list(found))} in :email"
    end
  end

  test "control: the fixture's authored colours do reach :article output (the data allowance is not vacuous)" do
    authored = authored_colours()
    assert MapSet.size(authored) > 0
    seen = inline_colours(render(:article, :evergreen)) |> MapSet.intersection(authored)
    assert MapSet.size(seen) > 0
  end

  test "every pd-parity block type outside @known inlines no theme colour on :article, in every theme" do
    offenders =
      GenPdParity.types()
      |> Enum.filter(&theme_paint?(GenPdParity.input(&1)))
      |> MapSet.new()

    new = MapSet.difference(offenders, @known)
    cleared = MapSet.difference(@known, offenders)

    assert MapSet.size(new) == 0,
           "these block types inline a theme colour on :article: #{inspect(MapSet.to_list(new))}"

    assert MapSet.size(cleared) == 0,
           "these @known types no longer inline one — delete them from @known: #{inspect(MapSet.to_list(cleared))}"
  end

  test "control: the block-level detector flags a known offender and the :email render of paper-links" do
    assert theme_paint?(GenPdParity.input("diagram"))
    assert theme_paint?(GenPdParity.input("paper-links"), :email)
  end

  # The guard is about COLOUR. A `--paper-font-*` face is a theme FONT, and fonts
  # are deliberately out of scope: a font token must never trip it by accident.
  test "control: the detector sees colour tokens and ignores font tokens" do
    style =
      ~s|<p style="font-family:var(--paper-font-mono);color:var(--paper-ink-soft, #55635e)">|

    assert inline_colours(style) == MapSet.new(["var(--paper-ink-soft", "#55635e"])
    assert inline_colours(~s|<p style="font-family:var(--paper-font-serif)">|) == MapSet.new()
  end

  # True when `block`, rendered in `style` in ANY theme, carries an inline
  # `var(--paper-*)` or a palette colour the block itself did not author.
  defp theme_paint?(block, style \\ :article) do
    authored =
      ~r/#[0-9a-fA-F]{3,8}\b/
      |> Regex.scan(Jason.encode!(block))
      |> List.flatten()
      |> MapSet.new(&String.downcase/1)

    Enum.any?(TokensGen.themes(), fn theme ->
      colours = inline_colours(Render.render_block(block, %{style: style, theme: theme}))

      Enum.any?(colours, &String.starts_with?(&1, "var(--paper-")) or
        colours
        |> MapSet.intersection(palette(theme))
        |> MapSet.difference(authored)
        |> MapSet.size() > 0
    end)
  end

  defp render(style, theme) do
    Render.render_html(
      ParityFixture.tree(),
      style |> ParityFixture.render_opts() |> Map.put(:theme, theme)
    )
  end

  defp inline_colours(html) do
    ~r/style="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.flat_map(fn [_, body] -> @colour |> Regex.scan(body) |> List.flatten() end)
    |> MapSet.new(&String.downcase/1)
  end

  defp palette(theme) do
    theme
    |> Palettes.email_skin()
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> MapSet.new(&String.downcase/1)
  end

  defp authored_colours do
    ~r/#[0-9a-fA-F]{3,8}\b/
    |> Regex.scan(Jason.encode!(ParityFixture.tree()))
    |> List.flatten()
    |> MapSet.new(&String.downcase/1)
  end
end
