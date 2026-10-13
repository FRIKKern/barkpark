defmodule Barkpark.Media.Renditions do
  @moduledoc """
  On-disk rendition cache and on-demand image transforms.

  Nothing here runs at upload. Every rendition is made on its first request
  and cached:

    * named presets (`thumb`, `preview`, `hero`, `og`, `lqip`) under
      `{upload_dir}/_renditions/{media_file_id}/{preset}.{ext}`;
    * URL-parameter transforms (`Barkpark.Media.Transform`) under
      `{upload_dir}/_renditions/{media_file_id}/t/{hash}.{ext}`, where the hash
      is taken over the normalised parameters.

  Both kinds go through one generate path: a per-file lock so concurrent first
  requests render once, a write to a temporary file, and a rename into place
  so a reader never sees a partial file.
  """

  alias Barkpark.ManagedRuntime.WriteAdmission.Door
  alias Barkpark.Media
  alias Barkpark.Media.{Blobstore, ImageBackend, Transform}
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
    "og" => %{max_width: 1200, max_height: 630, format: "jpg", quality: 85, crop: :attention},
    # `lqip` is the blur placeholder a schema `image` value carries as a data:
    # URI (Gyldendal parity E1.7, Barkpark.Media.ImageMetadata): a ≤ 24 px
    # JPEG, a few hundred bytes. Upload computes it once in memory and stores
    # it on the asset (`fileInfo.lqip`, `Barkpark.Media.Processing`); this
    # preset serves the file form on request.
    "lqip" => %{max_width: 24, max_height: 24, format: "jpg", quality: 40}
  }

  @doc "The spec for a named preset, or nil."
  @spec preset_spec(String.t()) :: map() | nil
  def preset_spec(preset), do: Map.get(@presets, preset)

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
        # C083: a GET may write rendition bytes; a held instance refuses the
        # generate (the cached rendition above still serves).
        render = fn src, tmp ->
          ImageBackend.impl().render(src, tmp, spec, normalize_profile(profile))
        end

        Door.admit(fn -> generate(file, preset, dest, rel, render) end)
      end
    else
      nil -> {:error, :unknown_preset}
    end
  end

  @doc """
  Ensure a URL-parameter transform exists on disk, generating it if needed.

  `plan` is a resolved `Barkpark.Media.Transform` plan. Returns the cached
  file's relative path, or:

    * `{:error, :not_transformable}` — the blob is not a raster image libvips
      decodes (png, jpeg, gif, webp);
    * `{:error, :transforms_unsupported}` — the selected image backend has no
      `transform/4` (the ImageMagick backend on Windows);
    * `{:error, :variant_limit}` — this asset already holds
      `Transform.max_variants_per_asset/0` cached transforms and this plan is
      not one of them.
  """
  @spec transform(%MediaFile{}, Transform.plan(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def transform(%MediaFile{} = file, plan, opts \\ []) do
    profile = normalize_profile(watermark_profile(opts))
    rel = Path.join(["_renditions", file.id, "t", Transform.cache_name(plan, profile)])
    dest = Media.file_path(rel)

    cond do
      not renderable?(file) ->
        {:error, :not_transformable}

      File.exists?(dest) ->
        {:ok, rel}

      not ImageBackend.transforms?() ->
        {:error, :transforms_unsupported}

      variant_count(file.id) >= Transform.max_variants_per_asset() ->
        {:error, :variant_limit}

      true ->
        render = fn src, tmp -> ImageBackend.impl().transform(src, tmp, plan, profile) end
        Door.admit(fn -> generate(file, "transform", dest, rel, render) end)
    end
  end

  @doc "Whether a blob is a raster image the rendition backend can decode."
  @spec renderable?(%MediaFile{}) :: boolean()
  def renderable?(%MediaFile{mime_type: mime}) when is_binary(mime),
    do: mime in @rendition_mime_types

  def renderable?(_), do: false

  # Reachability: the directory is `renditions_root/0` joined with a loaded
  # row's `:binary_id` UUID and the literal "t"; no request data reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  defp variant_count(media_file_id) do
    case File.ls(Path.join([renditions_root(), media_file_id, "t"])) do
      {:ok, names} -> Enum.count(names, &(not String.starts_with?(&1, ".")))
      {:error, _} -> 0
    end
  end

  @doc "Remove cached renditions for a blob id."
  @spec delete_for_file(String.t()) :: :ok
  # Reachability: `media_file_id` is a `MediaFile` PRIMARY KEY — a `:binary_id`
  # UUID autogenerated by Ecto (lib/barkpark/media/storage/media_file.ex:5), not
  # a request-supplied string. Both call sites pass a LOADED row's `.id`
  # (lib/barkpark/media.ex:732, the deferred delete effect; and
  # lib/barkpark/media/storage/checkout.ex:91, the force-release path), so the
  # value has already survived Ecto's binary_id cast and can contain neither `/`
  # nor `..`. The join therefore names exactly one direct child of
  # `renditions_root/0` (this module, `defp renditions_root` —
  # `{upload_dir}/_renditions`), and the rm_rf cannot escape that cache root.
  # sobelow_skip ["Traversal.FileModule"]
  def delete_for_file(media_file_id) when is_binary(media_file_id) do
    dir = Path.join(renditions_root(), media_file_id)
    File.rm_rf(dir)
    :ok
  end

  # Reachability: `dest` is `Media.file_path/1` over either `cache_relative/4`
  # (the fixed `_renditions` prefix, a DB-issued `MediaFile` UUID, a `@presets`
  # key and its format) or `transform/3`'s path (the same prefix and UUID, the
  # literal "t", and a hex SHA-256 prefix plus an allow-listed format). No
  # caller-supplied path component reaches the mkdir, the temp write or the
  # rename.
  # sobelow_skip ["Traversal.FileModule"]
  defp generate(%MediaFile{} = file, label, dest, rel, render) do
    # ONE RENDER PER FILE. Two first requests for the same uncached rendition
    # used to both decode the original and both write `dest`. The lock is keyed
    # on `dest`, and the holder re-checks the cache inside it, so the second
    # caller waits and then serves the first caller's file.
    :global.trans(
      {{__MODULE__, dest}, self()},
      fn ->
        if File.exists?(dest) do
          {:ok, rel}
        else
          do_generate(file, label, dest, rel, render)
        end
      end,
      [node()]
    )
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp do_generate(%MediaFile{} = file, preset, dest, rel, render) do
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

        # Render to a temporary name in the same directory, then rename: a
        # concurrent reader that finds `dest` always finds a whole file. The
        # temp name keeps `dest`'s extension because the backends pick the
        # encoder from it.
        tmp =
          Path.join(
            Path.dirname(dest),
            ".tmp-#{System.unique_integer([:positive])}-" <> Path.basename(dest)
          )

        # libvips on macOS/Linux/Docker; ImageMagick CLI on Windows. See ImageBackend.
        case render.(src, tmp) |> promote(tmp, dest) do
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
                File.rm_rf(Path.join(renditions_root(), file.id))
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

  # Reachability: as `promote/3` below; `dest` is `generate/5`'s server-built path.
  # sobelow_skip ["Traversal.FileModule"]
  defp promote(:ok, tmp, dest) do
    case File.rename(tmp, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # Reachability: `tmp` is built in `do_generate/5` from `dest`'s directory and
  # basename (see the waiver on `generate/5`) plus a unique integer.
  # sobelow_skip ["Traversal.FileModule"]
  defp promote(error, tmp, _dest) do
    File.rm(tmp)
    error
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
end
