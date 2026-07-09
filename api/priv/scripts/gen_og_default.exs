# Regenerate the branded default share card `priv/static/images/og-default.jpg`
# (1200×630 — the constant og geometry, D4/D5 of the preview-contract charter).
#
# Emitters fall back to this card whenever a document's preview manifest has no
# image, so EVERY shared Barkpark link unfurls branded, never blank. Palette is
# the evergreen brand ground + mint accent from design/tokens.json.
#
# Run (libvips / the :image dep required — any dev/CI host):
#
#     cd api && mix run --no-start priv/scripts/gen_og_default.exs
#
# Commit the produced jpg alongside this script — the script IS the provenance
# of the asset (A5): a brand refresh edits the constants here and re-runs.

defmodule Barkpark.Scripts.GenOgDefault do
  @width 1200
  @height 630

  # design/tokens.json — color.primary light "163 46% 22%" ≈ #1e5243 (evergreen);
  # gradient runs a slightly lifted evergreen into a deeper shade so the card
  # has depth without competing with the wordmark.
  @evergreen_top "#256052"
  @evergreen_bottom "#173d33"
  @mint "#75c7ac"
  @ink "#f6faf9"
  @tagline_ink "#b9dfcf"

  @font "Inter"
  @font_fallback "Helvetica Neue"

  @dest Path.expand("../static/images/og-default.jpg", __DIR__)

  def run do
    {:ok, bg} =
      Image.linear_gradient(@width, @height,
        start_color: @evergreen_top,
        finish_color: @evergreen_bottom,
        angle: 180
      )

    {:ok, accent} = Image.new(104, 8, color: @mint)

    {:ok, wordmark} = text("Barkpark", 150, @ink, weight: 700)
    {:ok, tagline} = text("Every document, a branded card.", 42, @tagline_ink, weight: 400)

    {:ok, card} =
      bg
      |> compose_centered(accent, 148)
      |> compose_centered(wordmark, 218)
      |> compose_centered(tagline, 388)

    File.mkdir_p!(Path.dirname(@dest))
    {:ok, _} = Image.write(card, @dest, quality: 80)

    IO.puts("wrote #{@dest} (#{File.stat!(@dest).size} bytes)")
  end

  defp text(string, size, color, weight: weight) do
    # Pango falls back by family name: the repo's Inter ships as woff2 (which
    # Pango can't load), so hosts without an installed Inter render the system
    # fallback — acceptable per A5.
    Image.Text.text(string,
      font: "#{@font}, #{@font_fallback}",
      font_size: size,
      font_weight: weight,
      text_fill_color: color
    )
  end

  defp compose_centered({:ok, base}, overlay, y), do: compose_centered(base, overlay, y)

  defp compose_centered(base, overlay, y) do
    x = div(@width - Image.width(overlay), 2)
    Image.compose(base, overlay, x: x, y: y)
  end
end

Barkpark.Scripts.GenOgDefault.run()
