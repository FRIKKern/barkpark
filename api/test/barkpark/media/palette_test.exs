defmodule Barkpark.Media.PaletteTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Palette

  # n pixels of one RGB colour, as the 3-band binary the backend hands over.
  defp fill(n, {r, g, b}), do: :binary.copy(<<r, g, b>>, n)

  test "Sanity's palette shape: seven swatches with hex colours, text colours and population" do
    # 60 % a dark green, 30 % a bright yellow, 10 % a pale blue-grey.
    pixels = fill(600, {60, 140, 68}) <> fill(300, {249, 201, 59}) <> fill(100, {200, 210, 220})
    palette = Palette.from_pixels(pixels, 3)

    assert palette["_type"] == "sanity.imagePalette"

    for name <- ~w(dominant vibrant darkVibrant lightVibrant muted darkMuted lightMuted),
        swatch = palette[name],
        swatch != nil do
      assert swatch["background"] =~ ~r/\A#[0-9a-f]{6}\z/
      assert swatch["foreground"] in ["#fff", "#000"]
      assert swatch["title"] in ["#fff", "#000"]
      assert is_float(swatch["population"])
    end

    # The most common colour is dominant, with its share of the pixels.
    assert palette["dominant"]["population"] == 60.0
    assert palette["dominant"]["foreground"] == "#fff"
    # The saturated yellow is the vibrant swatch; dark text on it.
    assert palette["vibrant"]["population"] == 30.0
    assert palette["vibrant"]["foreground"] == "#000"
  end

  test "transparent and near-white pixels do not count" do
    rgba = :binary.copy(<<10, 20, 200, 0>>, 50) <> :binary.copy(<<255, 255, 255, 255>>, 50)
    assert Palette.from_pixels(rgba, 4) == nil

    rgba = rgba <> :binary.copy(<<10, 20, 200, 255>>, 10)
    assert Palette.from_pixels(rgba, 4)["dominant"]["population"] == 100.0
  end
end
