defmodule Barkpark.Media.Renditions do
  @moduledoc """
  On-disk rendition cache and on-demand image transforms.

  Presets mirror WoodWing-style delivery profiles. Files live under
  `{upload_dir}/_renditions/{media_file_id}/{preset}.{ext}` and are
  generated lazily on first request or eagerly after image upload.
  """

  alias Barkpark.Media
  alias Barkpark.Media.{Blobstore, ImageBackend}
  alias Barkpark.Media.Storage.MediaFile

  # MIME types the rendition backend can actually decode. This mirrors the
  # raster set `Barkpark.Media.Probe.dimensions/2` supports (png/jpeg/gif/webp).
  # Other legit `image/*` mimes (SVG, TIFF, ICO, AVIF, HEIC) are accepted on
  # upload but have no libvips loader on the CI/ARM build, so `Image.open`
  # raises `Image.Error "Failed to find load"` — one warning per preset. We gate
  # on this raster set instead of the whole `image/*` prefix so those blobs are
  # cleanly treated as "no rendition" (original serving is unaffected).
  @rendition_mime_types ~w(image/png image/jpeg image/gif image/webp)

  @presets %{
    "thumb" => %{max_width: 320, max_height: 320, format: "jpg", quality: 80},
    "preview" => %{max_width: 1600, max_height: 1600, format: "jpg", quality: 85},
    "hero" => %{max_width: 1920, max_height: 1080, format: "webp", quality: 85},
    # `og` is an EXACT crop, not a fit: a share card must be a constant
    # 1200×630 whatever the source aspect (portrait sources upscale-and-crop to
    # fill), so the preview manifest can hardcode those dimensions with zero
    # per-asset lookup. `crop: :attention` centres the crop on the salient region.
    "og" => %{max_width: 1200, max_height: 630, format: "jpg", quality: 85, crop: :attention}
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

  @doc """
  Generate all image presets for a blob.

  Returns:

    * `:ok` — the blob is not a renderable raster image (nothing to do), or at
      least one preset was produced.
    * `{:error, :all_renditions_failed}` — the blob IS a renderable raster
      image but every preset failed. Callers use this to avoid reporting the
      asset `ready` when its entire rendition set is missing.
  """
  @spec generate_all(%MediaFile{}, keyword()) :: :ok | {:error, :all_renditions_failed}
  def generate_all(%MediaFile{} = file, opts \\ []) do
    if renderable?(file) do
      results = Enum.map(presets(), fn preset -> ensure(file, preset, opts) end)

      if Enum.any?(results, &match?({:ok, _}, &1)) do
        :ok
      else
        {:error, :all_renditions_failed}
      end
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

  # Reachability: `dest` is `Media.file_path/1` over `cache_relative/4` — the
  # fixed `_renditions` prefix, a DB-issued `MediaFile` UUID, a `@presets` key
  # and its format; no caller-supplied path component reaches the mkdir.
  # sobelow_skip ["Traversal.FileModule"]
  defp generate(%MediaFile{} = file, preset, spec, dest, rel, profile) do
    # The SOURCE original comes via the blobstore (a local path join today; a
    # one-time cache download under an object-storage backend). The rendition
    # OUTPUT stays a plain local write regardless of backend — renditions are
    # a regenerable cache, never routed through remote storage.
    # ROW-ADDRESSED (task-8eb6542ece62aff1): the rendition SOURCE must be this
    # row's own object, never whatever object another tenant's row happens to
    # hold at the same flat path — a substituted source would bake a foreign
    # image into a cache served under this row's id.
    case Blobstore.ensure_local(file) do
      {:ok, src} ->
        File.mkdir_p!(Path.dirname(dest))

        # libvips on macOS/Linux/Docker; ImageMagick CLI on Windows. See ImageBackend.
        case ImageBackend.impl().render(src, dest, spec, normalize_profile(profile)) do
          :ok ->
            # Post-generate parent recheck — closes the delete-vs-generate race.
            # A lazy generate that loaded `file` before an admin DELETE, then
            # ran mkdir_p!+render AFTER the delete's rm_rf, would re-create an
            # orphan dir under a now-deleted media_files id (never served, but
            # wasted disk). We re-read the row and reap our own write if the
            # parent is gone.
            #
            # RACE-SOUND on a strict ordering dependency: `Media.delete_file`
            # commits `Repo.delete` BEFORE the deferred `delete_for_file` rm_rf
            # (see media.ex — Repo.delete, then defer_media_effect). So:
            #   * any render landing AFTER that rm_rf sees the row gone here and
            #     reaps its own dir (the reap branch below);
            #   * any render the recheck KEEPS committed before the delete saw
            #     the row present, meaning its write predates the deferred rm_rf,
            #     which then sweeps it.
            # No interleaving survives an orphan. A refactor moving
            # `delete_for_file` BEFORE the Repo.delete commit would break this —
            # a kept render could then outlive the rm_rf. Keep rm_rf last.
            case Media.get_file(file.id) do
              {:ok, _} ->
                {:ok, rel}

              {:error, :not_found} ->
                File.rm_rf(Path.dirname(dest))
                {:error, :parent_deleted}
            end

          {:error, reason} ->
            log_generate_failure(preset, file, reason)
            {:error, reason}
        end

      {:error, reason} ->
        log_generate_failure(preset, file, reason)
        {:error, reason}
    end
  end

  defp log_generate_failure(preset, file, reason) do
    require Logger

    Logger.warning(
      "Barkpark.Media.Renditions.generate #{preset} for #{file.id}: #{inspect(reason)}"
    )
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

  # Only raster mimes libvips can decode get renditions. A non-raster `image/*`
  # (SVG/TIFF/ICO/AVIF/HEIC) is skipped cleanly — no backend call, no error log.
  defp renderable?(%MediaFile{mime_type: mime}) when is_binary(mime),
    do: mime in @rendition_mime_types

  defp renderable?(_), do: false
end
