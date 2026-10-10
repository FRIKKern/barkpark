defmodule Barkpark.PortableDoc.Render.ArticleThemeColourTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{Palettes, ParityFixture, TokensGen}

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

  @colour ~r/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|var\(--paper-[a-z-]+/

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
