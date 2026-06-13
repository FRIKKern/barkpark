defmodule Barkpark.Media.ImageBackend.Vix do
  @moduledoc """
  libvips rendition backend (via the `:image` dep). Canonical on
  macOS/Linux/Docker. The pipeline — open, aspect-preserving thumbnail, optional
  centered text watermark, write at quality — is the original `Renditions` code,
  moved behind `Barkpark.Media.ImageBackend` unchanged.

  `Image.*` resolves at runtime; on a host without the `:image` dep (e.g. native
  Windows, where this backend is never selected) these calls are simply never
  reached.
  """
  @behaviour Barkpark.Media.ImageBackend

  @impl true
  def available?, do: Code.ensure_loaded?(Image)

  @impl true
  def render(src, dest, spec, watermark) do
    with {:ok, image} <- Image.open(src),
         {:ok, thumb} <- Image.thumbnail(image, spec.max_width, height: spec.max_height),
         {:ok, stamped} <- maybe_watermark(thumb, watermark),
         :ok <- write_image(stamped, dest, spec) do
      :ok
    end
  end

  defp maybe_watermark(image, profile) when profile in [nil, "", "none"], do: {:ok, image}

  defp maybe_watermark(image, profile) when profile in ["draft", "editorial"] do
    label = watermark_label(profile)

    with {:ok, text_layer} <-
           Image.Text.text(label,
             font_size: watermark_font_size(image),
             text_fill_color: {255, 255, 255, 0.35},
             background_color: :none
           ),
         {:ok, watermarked} <- Image.compose(image, text_layer, x: :center, y: :middle) do
      {:ok, watermarked}
    else
      {:error, _} = error -> error
      _ -> {:ok, image}
    end
  end

  defp maybe_watermark(image, _profile), do: {:ok, image}

  defp watermark_label("draft"), do: "DRAFT"
  defp watermark_label("editorial"), do: "EDITORIAL USE ONLY"
  defp watermark_label(_), do: "DRAFT"

  defp watermark_font_size(image) do
    min(Image.width(image), Image.height(image))
    |> div(12)
    |> max(18)
  end

  defp write_image(image, dest, %{format: "webp"} = spec) do
    case Image.write(image, dest, suffix: ".webp", quality: spec.quality) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_image(image, dest, spec) do
    case Image.write(image, dest, suffix: ".jpg", quality: spec.quality) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
