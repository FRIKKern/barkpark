defmodule Barkpark.Media.Renditions do
  @moduledoc """
  On-disk rendition cache and on-demand image transforms.

  Presets mirror WoodWing-style delivery profiles. Files live under
  `{upload_dir}/_renditions/{media_file_id}/{preset}.{ext}` and are
  generated lazily on first request or eagerly after image upload.
  """

  alias Barkpark.Media
  alias Barkpark.Media.ImageBackend
  alias Barkpark.Media.Storage.MediaFile

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

    # libvips on macOS/Linux/Docker; ImageMagick CLI on Windows. See ImageBackend.
    case ImageBackend.impl().render(src, dest, spec, normalize_profile(profile)) do
      :ok ->
        {:ok, rel}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Barkpark.Media.Renditions.generate #{preset} for #{file.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Collapse the "no watermark" sentinels to nil for the backend contract.
  defp normalize_profile(profile) when profile in [nil, "", "none"], do: nil
  defp normalize_profile(profile), do: profile

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
