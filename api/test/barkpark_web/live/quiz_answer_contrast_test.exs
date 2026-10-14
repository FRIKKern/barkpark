defmodule BarkparkWeb.QuizAnswerContrastTest do
  @moduledoc """
  The four answer tiles on the public quiz page (task-53c5c80feacf44dc).
  White on the old fills read 2.04-4.01 (axe color-contrast on every tile),
  and the tally inside each tile was ink-soft at 1.07-1.65.

  Read from the RENDERED layout, the same bytes a phone gets: the tile ink and
  the four fills from the quiz chrome, the ground and the tally track from the
  dark paper-surface block it embeds. Text holds 4.5:1, also at the disabled
  opacity the audience reads once answers lock. Each tile holds 3:1 off the
  ground and the host's tally track. Each colour also carries its own shape,
  so colour is never the only signal.
  """
  use BarkparkWeb.ConnCase, async: true

  @moduletag :requires_plugins

  setup %{conn: conn} do
    html =
      conn
      |> get("/quiz/host/contrast-#{System.unique_integer([:positive])}")
      |> html_response(200)

    %{css: html}
  end

  test "tile text reads at 4.5:1 on every fill, enabled and disabled", %{css: css} do
    ink = tile_ink(css)
    ground = ground(css, "--paper-bg")
    op = disabled_opacity(css)

    for {n, fill} <- fills(css) do
      assert contrast(ink, fill) >= 4.5,
             "c#{n} #{fill}: ink #{ink} reads #{Float.round(contrast(ink, fill), 2)}:1"

      dimmed = contrast(blend(ink, ground, op), blend(fill, ground, op))

      assert dimmed >= 4.5,
             "c#{n} #{fill} disabled (opacity #{op}): reads #{Float.round(dimmed, 2)}:1"
    end
  end

  test "each tile stands 3:1 off the ground and the tally track", %{css: css} do
    for {n, fill} <- fills(css),
        ground <- [ground(css, "--paper-bg"), ground(css, "--paper-bg-deep")] do
      assert contrast(fill, ground) >= 3.0,
             "c#{n} #{fill} on #{ground}: #{Float.round(contrast(fill, ground), 2)}:1"
    end
  end

  test "the tally inside a tile reads in the tile's ink", %{css: css} do
    assert css =~ ~r/\.q-choice \.q-count\s*\{\s*color:\s*inherit;/
  end

  test "the four fills stay distinguishable, and each carries its own shape", %{css: css} do
    hues = fills(css) |> Enum.map(fn {_, f} -> hue(f) end)

    for {a, i} <- Enum.with_index(hues), {b, j} <- Enum.with_index(hues), i < j do
      d = abs(a - b)

      assert min(d, 360 - d) >= 25,
             "c#{i} and c#{j} hues sit #{round(min(d, 360 - d))} degrees apart"
    end

    shapes =
      for n <- 0..3 do
        rule = Regex.run(~r/\.q-choice\.c#{n}::before,([^{]*)\{([^}]*)\}/, css)
        assert rule, "c#{n}: the answer tile carries no shape"
        [_, also, body] = rule
        assert also =~ ".q-bar-row:has(.c#{n})", "c#{n}: the host tally row carries no shape"
        [_, shape] = Regex.run(~r/content:\s*"([^"]+)"\s*\/\s*""/, body)
        shape
      end

    assert length(Enum.uniq(shapes)) == 4, "shapes: #{inspect(shapes)}"
  end

  # --- reading the rendered CSS ---

  defp fills(css) do
    found = Regex.scan(~r/--c([0-3]):\s*(#[0-9a-fA-F]{6})/, css, capture: :all_but_first)
    assert length(found) == 4, "expected --c0..--c3 once each, got #{inspect(found)}"
    Enum.map(found, fn [n, hex] -> {n, hex} end)
  end

  defp tile_ink(css) do
    [_, rule] = Regex.run(~r/\n\s*\.q-choice\s*\{([^}]*)\}/, css)
    [_, color] = Regex.run(~r/(?:^|[;\s])color:\s*([^;]+);/, rule)
    resolve(css, String.trim(color))
  end

  defp disabled_opacity(css) do
    case Regex.run(~r/\.q-choice\[disabled\]\s*\{[^}]*opacity:\s*([\d.]+)/, css) do
      [_, op] -> String.to_float(op)
      nil -> 1.0
    end
  end

  # The page's own theme: html[data-theme="dark"] with no data-bp-theme. That
  # selector opens several blocks; as in the cascade, the last value wins.
  defp ground(css, name) do
    values =
      for [block] <-
            Regex.scan(
              ~r/html\[data-theme="dark"\] \.bp-paper-surface,\s*html\[data-theme="dark"\] \.bp-paper-body\s*\{([^}]*)\}/,
              css,
              capture: :all_but_first
            ),
          [hex] <- Regex.scan(~r/#{name}:\s*(#[0-9a-fA-F]{6});/, block, capture: :all_but_first),
          do: hex

    assert values != [], "no #{name} in the dark paper-surface blocks"
    List.last(values)
  end

  defp resolve(css, "var(" <> rest) do
    name = rest |> String.trim_trailing(")") |> String.trim()
    [_, hex] = Regex.run(~r/#{name}:\s*(#[0-9a-fA-F]{6})/, css)
    hex
  end

  defp resolve(_css, "#fff"), do: "#ffffff"
  defp resolve(_css, hex), do: hex

  # --- WCAG 2.x arithmetic ---

  defp rgb("#" <> hex) do
    hex
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(&String.to_integer(Enum.join(&1), 16))
  end

  defp luminance(hex) do
    [r, g, b] =
      Enum.map(rgb(hex), fn v ->
        c = v / 255
        if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp contrast(a, b) do
    [hi, lo] = Enum.sort([luminance(a), luminance(b)], :desc)
    (hi + 0.05) / (lo + 0.05)
  end

  # An element at `op` opacity composites over the ground in sRGB.
  defp blend(fg, ground, op) do
    channels =
      Enum.zip_with(rgb(fg), rgb(ground), fn f, g -> round(op * f + (1 - op) * g) end)

    "#" <> Enum.map_join(channels, &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end

  defp hue(hex) do
    [r, g, b] = Enum.map(rgb(hex), &(&1 / 255))
    {mx, mn} = {Enum.max([r, g, b]), Enum.min([r, g, b])}
    d = mx - mn

    h =
      cond do
        d == 0 -> 0.0
        mx == r -> 60 * :math.fmod((g - b) / d, 6)
        mx == g -> 60 * ((b - r) / d + 2)
        true -> 60 * ((r - g) / d + 4)
      end

    if h < 0, do: h + 360, else: h
  end
end
