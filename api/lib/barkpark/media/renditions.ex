defmodule Barkpark.Media.Renditions do
  @moduledoc """
  On-disk rendition cache and on-demand image transforms.

  Presets mirror WoodWing-style delivery profiles. Files live under
  `{upload_dir}/_renditions/{media_file_id}/{preset}.{ext}` and are
  generated lazily on first request or eagerly after image upload.
  """

  alias Barkpark.Media
  alias Barkpark.Media.MediaFile

  @presets %{
    "thumb" => %{max_width: 320, max_height: 320, format: "jpg", quality: 80},
    "preview" => %{max_width: 1600, max_height: 1600, format: "jpg", quality: 85},
    "hero" => %{max_width: 1920, max_height: 1080, format: "webp", quality: 85},
    "og" => %{max_width: 1200, max_height: 630, format: "jpg", quality: 85}
  }

  @doc "All supported preset names."
  @spec presets() :: [String.t()]
  def presets, do: Map.keys(@presets)

  @doc "Public URL for a preset rendition."
  @spec url(%MediaFile{}, String.t()) :: String.t() | nil
  def url(%MediaFile{id: id}, preset) do
    if Map.has_key?(@presets, preset) do
      "/media/renditions/#{id}/#{preset}"
    end
  end

  @doc "Relative cache path for a preset, if it exists on disk."
  @spec relative_path(%MediaFile{}, String.t(), keyword()) :: String.t() | nil
  def relative_path(%MediaFile{} = file, preset, opts \\ []) do
    case Map.get(@presets, preset) do
      nil ->
        nil

      spec ->
        rel = cache_relative(file.id, preset, spec.format, watermark_profile(opts))

        if File.exists?(Media.file_path(rel)), do: rel, else: nil
    end
  end

  @doc "Generate all image presets for a blob. Non-images are skipped."
  @spec generate_all(%MediaFile{}, keyword()) :: :ok | {:error, term()}
  def generate_all(%MediaFile{} = file, opts \\ []) do
    if image?(file) do
      Enum.each(presets(), fn preset ->
        _ = ensure(file, preset, opts)
      end)

      :ok
    else
      :ok
    end
  end

  @doc "Ensure a rendition exists on disk, generating if needed."
  @spec ensure(%MediaFile{}, String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%MediaFile{} = file, preset, opts \\ []) do
    with spec when not is_nil(spec) <- Map.get(@presets, preset),
         profile = watermark_profile(opts),
         rel = cache_relative(file.id, preset, spec.format, profile),
         dest = Media.file_path(rel) do
      if File.exists?(dest) do
        {:ok, rel}
      else
        generate(file, preset, spec, dest, rel, profile)
      end
    else
      nil -> {:error, :unknown_preset}
    end
  end

  @doc "Remove cached renditions for a blob id."
  @spec delete_for_file(String.t()) :: :ok
  def delete_for_file(media_file_id) when is_binary(media_file_id) do
    dir = Path.join(renditions_root(), media_file_id)
    File.rm_rf(dir)
    :ok
  end

  defp generate(%MediaFile{} = file, preset, spec, dest, rel, profile) do
    src = Media.file_path(file.path)
    File.mkdir_p!(Path.dirname(dest))

    with {:ok, image} <- Image.open(src),
         {:ok, thumb} <- Image.thumbnail(image, spec.max_width, height: spec.max_height),
         {:ok, stamped} <- maybe_watermark(thumb, profile),
         :ok <- write_image(stamped, dest, spec) do
      {:ok, rel}
    else
      {:error, reason} ->
        require Logger

        Logger.warning(
          "Barkpark.Media.Renditions.generate #{preset} for #{file.id}: #{inspect(reason)}"
        )

        {:error, reason}
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

  defp cache_relative(id, preset, ext, profile) do
    suffix =
      case profile do
        p when p in [nil, "", "none"] -> ""
        p -> ".wm-#{p}"
      end

    Path.join(["_renditions", id, "#{preset}#{suffix}.#{ext}"])
  end

  defp watermark_profile(opts) do
    Keyword.get(opts, :watermark, "none") || "none"
  end

  defp renditions_root, do: Path.join(Media.upload_dir(), "_renditions")

  defp image?(%MediaFile{mime_type: mime}) when is_binary(mime),
    do: String.starts_with?(mime, "image/")

  defp image?(_), do: false
end
