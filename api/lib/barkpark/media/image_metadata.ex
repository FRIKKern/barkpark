defmodule Barkpark.Media.ImageMetadata do
  @moduledoc """
  Back-fills the denormalised image metadata a schema-declared `image` value
  carries — `url`, `width`, `height`, `lqip` — from the media asset it points
  at (Gyldendal parity E1.7, task-e2eab81cc3e87047).

  ## Why the value carries metadata at all

  Sanity resolves an image's dimensions and blur placeholder from the asset
  document at READ time. Barkpark's model denormalises them onto the field
  value at WRITE time: the twin site's `next/image` sizes the picture from
  `width`/`height` and blur-loads it from `lqip`, and the catalogue precompute
  copies them verbatim. The migration wrote them from Sanity's own metadata;
  the Studio picker wrote only `url`/`assetId`/`alt`/`focalX`/`focalY`, so the
  first cover an editor swapped shipped an image the site could neither size
  nor blur-load.

  ## What this module does — and never does

  `backfill_params/4` walks the DECLARED schema (top-level `image`, `arrayOf`
  of `image`, and `image` subfields inside `composite` rows, recursively) and
  fills ONLY the keys that are absent or blank on each image map. A value the
  editor or the migration already holds is never overwritten; a bare-URL
  string, a map without an `assetId`, an asset that cannot be found, or any
  storage error leaves the value byte-identical. Nothing here raises into the
  save path.

  Sources, in order: the `mediaAsset` document's `fileInfo` (url, width,
  height, lqip — written by `Barkpark.Media.Processing` at upload), reached
  through `Barkpark.Media.asset_doc_for_file/3`; the blob itself via
  `Barkpark.Media.Probe` when `fileInfo` has no dimensions yet; and for
  `lqip` on an asset uploaded before upload stored it, the `"lqip"` rendition
  preset (a ≤ 24 px JPEG, base64-encoded as a `data:` URI), generated on
  demand through `Barkpark.Media.Renditions` — never fabricated.

  Lives under `Barkpark.Media` (not `Content`): it is the media concept that
  knows blobs, asset documents and renditions; the Studio save path calls it
  from the web layer, and the content kernel keeps no edge to media.
  """

  alias Barkpark.Media
  alias Barkpark.Media.{Blobstore, Probe, Renditions}

  require Logger

  @lqip_preset "lqip"

  @doc """
  Walk `params` by `schema.fields` and back-fill every declared image value.
  `opts` carries the tenancy scope (`:workspace_id` / `:project_id`) the
  asset lookup must honour.
  """
  @spec backfill_params(map(), map() | nil, String.t(), keyword()) :: map()
  def backfill_params(params, nil, _dataset, _opts), do: params

  def backfill_params(params, schema, dataset, opts) when is_map(params) do
    fields = schema_fields(schema)
    walk_fields(params, fields, dataset, opts)
  end

  def backfill_params(params, _schema, _dataset, _opts), do: params

  @doc """
  Back-fill ONE image map. Only `url`, `width`, `height` and `lqip` that are
  absent or blank are filled; everything else passes through untouched.
  """
  @spec backfill(term(), String.t(), keyword()) :: term()
  def backfill(%{"assetId" => asset_id} = image, dataset, opts)
      when is_binary(asset_id) and asset_id != "" do
    # One spelling for `assetId` (Gyldendal friction 78): the bare blob id —
    # what the migration wrote, what `Media.get_file/2` and the renditions
    # take. The picker used to store the asset DOCUMENT id (`asset-<blob>`)
    # on a fresh pick, so two spellings lived side by side. This is a
    # normalisation of the key that names the asset, not an overwrite of any
    # metadata: a bare id passes through byte-identically.
    image = Map.put(image, "assetId", file_id(asset_id))

    if complete?(image) do
      image
    else
      try do
        do_backfill(image, file_id(asset_id), dataset, scope(opts))
      rescue
        e ->
          Logger.warning(
            "ImageMetadata.backfill #{asset_id}: #{Exception.message(e)} — value kept as posted"
          )

          image
      end
    end
  end

  # The reference shape, `{asset: {_ref}}` (task-7ea6f41cede5ee97). The Studio
  # picker points a picked image at its asset DOCUMENT, `asset-<blob id>`.
  # A site that reads Sanity's shape follows `asset._ref` as a Sanity image id
  # (`@sanity/image-url` parses it, GROQ `asset->` resolves it), so the save
  # writes the id Sanity would have: the media file's `source_id` when it is
  # one (an imported Sanity asset, whose asset document has that id), else
  # `image-<sha1>-<w>x<h>-<ext>` from the stored bytes, which
  # `MediaController.serve_sanity_image` serves. A ref already in that form, or
  # a blob that cannot be found or measured, is left as posted.
  def backfill(%{"asset" => %{"_ref" => "asset-" <> _ = ref} = asset} = image, dataset, opts) do
    case sanity_image_id(file_id(ref), dataset, scope(opts)) do
      id when is_binary(id) -> Map.put(image, "asset", Map.put(asset, "_ref", id))
      _ -> image
    end
  rescue
    e ->
      Logger.warning(
        "ImageMetadata.backfill #{ref}: #{Exception.message(e)} — value kept as posted"
      )

      image
  end

  def backfill(%{"asset" => %{"_ref" => "drafts.asset-" <> rest} = asset} = image, dataset, opts),
    do: backfill(Map.put(image, "asset", Map.put(asset, "_ref", "asset-" <> rest)), dataset, opts)

  def backfill(other, _dataset, _opts), do: other

  @sanity_image_id ~r/\Aimage-[0-9a-f]{40}-[1-9][0-9]*x[1-9][0-9]*-[a-z0-9]+\z/

  @doc false
  # The Sanity image id for a Barkpark media file, or nil.
  def sanity_image_id(file_id, dataset, scope) do
    with {:ok, %Media.Storage.MediaFile{} = file} <- Media.get_file(file_id, scope) do
      cond do
        is_binary(file.source_id) and Regex.match?(@sanity_image_id, file.source_id) ->
          file.source_id

        is_binary(file.sha1) and Regex.match?(~r/\A[0-9a-f]{40}\z/, file.sha1) ->
          with {w, h} when is_integer(w) and is_integer(h) <-
                 file_dimensions(file, dataset, scope),
               ext when is_binary(ext) <- sanity_ext(file) do
            "image-#{file.sha1}-#{w}x#{h}-#{ext}"
          else
            _ -> nil
          end

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp file_dimensions(file, dataset, scope) do
    fi = asset_file_info(Media.asset_doc_for_file(file, dataset, scope))

    case {int(Map.get(fi, "width")), int(Map.get(fi, "height"))} do
      {w, h} when is_integer(w) and w > 0 and is_integer(h) and h > 0 ->
        {w, h}

      _ ->
        with {:ok, path} <- Blobstore.ensure_local(file),
             {:ok, %{width: w, height: h}} <- Probe.probe(path, file.mime_type) do
          {w, h}
        else
          _ -> nil
        end
    end
  end

  # Sanity's extension for an image: its mime subtype, "jpg" for JPEG.
  defp sanity_ext(%{mime_type: "image/jpeg"}), do: "jpg"
  defp sanity_ext(%{mime_type: "image/svg+xml"}), do: "svg"

  defp sanity_ext(%{mime_type: "image/" <> sub}) when sub != "",
    do: if(Regex.match?(~r/\A[a-z0-9]+\z/, sub), do: sub, else: nil)

  defp sanity_ext(_), do: nil

  # ── the walk ────────────────────────────────────────────────────────────────

  defp walk_fields(params, fields, dataset, opts) when is_map(params) do
    Enum.reduce(fields, params, fn field, acc ->
      name = Map.get(field, "name")

      case is_binary(name) and Map.fetch(acc, name) do
        {:ok, value} -> Map.put(acc, name, walk_value(field, value, dataset, opts))
        _ -> acc
      end
    end)
  end

  defp walk_fields(params, _fields, _dataset, _opts), do: params

  defp walk_value(%{"type" => "image"}, value, dataset, opts),
    do: backfill(value, dataset, opts)

  defp walk_value(%{"type" => "arrayOf", "of" => of}, value, dataset, opts)
       when is_map(of) and is_list(value),
       do: Enum.map(value, &walk_value(of, &1, dataset, opts))

  defp walk_value(%{"type" => "composite", "fields" => subs}, value, dataset, opts)
       when is_list(subs) and is_map(value),
       do: walk_fields(value, subs, dataset, opts)

  defp walk_value(_field, value, _dataset, _opts), do: value

  defp schema_fields(%{fields: fields}) when is_list(fields), do: fields
  defp schema_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp schema_fields(_), do: []

  # ── one image ───────────────────────────────────────────────────────────────

  defp do_backfill(image, file_id, dataset, scope) do
    case Media.get_file(file_id, scope) do
      {:ok, %Media.Storage.MediaFile{} = file} ->
        file_info = asset_file_info(Media.asset_doc_for_file(file, dataset, scope))

        image
        |> put_missing("url", Map.get(file_info, "url"))
        |> put_missing("width", int(Map.get(file_info, "width")))
        |> put_missing("height", int(Map.get(file_info, "height")))
        |> put_missing("lqip", Map.get(file_info, "lqip"))
        |> maybe_probe_dimensions(file)
        |> maybe_lqip(file)

      _ ->
        image
    end
  end

  defp asset_file_info(%{content: %{"fileInfo" => %{} = fi}}), do: fi
  defp asset_file_info(_), do: %{}

  # Dimensions from the blob when the asset document has none yet (a fresh
  # upload whose processing job has not run, or a pre-processing row).
  defp maybe_probe_dimensions(image, file) do
    if blank?(Map.get(image, "width")) or blank?(Map.get(image, "height")) do
      with {:ok, path} <- Blobstore.ensure_local(file),
           {:ok, %{width: w, height: h}} <- Probe.probe(path, file.mime_type) do
        image
        |> put_missing("width", w)
        |> put_missing("height", h)
      else
        _ -> image
      end
    else
      image
    end
  end

  # The blur placeholder: the `lqip` rendition (≤ 24 px JPEG) as a data: URI.
  # Only when the rendition backend can decode the blob — Renditions gates on
  # the raster mime set and answers {:error, _} otherwise, which leaves `lqip`
  # unset rather than fabricated.
  # Reachability: `rel` is never caller data — it is `Renditions.ensure/2`'s
  # return value (lib/barkpark/media/renditions.ex:93), which is always
  # `cache_relative/4`'s output (`cache_relative/4` in lib/barkpark/media/renditions.ex):
  # `Path.join(["_renditions", id, "<preset><suffix>.<ext>"])` over a fixed
  # literal prefix, the `MediaFile` `:binary_id` UUID
  # (lib/barkpark/media/storage/media_file.ex:5), the `@presets` key
  # `@lqip_preset` and that preset's own declared format. This call passes NO
  # opts, so `watermark_profile/1` yields "none" and the suffix is the empty
  # string — no argument of `maybe_lqip/2` reaches any path component.
  # `Media.file_path/1` (lib/barkpark/media.ex, `def file_path`) then joins that under
  # `Media.upload_dir/0`, so the read is confined to one file inside the
  # rendition cache root.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_lqip(image, file) do
    if blank?(Map.get(image, "lqip")) do
      with {:ok, rel} <- Renditions.ensure(file, @lqip_preset),
           {:ok, bytes} when byte_size(bytes) > 0 <- File.read(Media.file_path(rel)) do
        Map.put(image, "lqip", "data:image/jpeg;base64," <> Base.encode64(bytes))
      else
        _ -> image
      end
    else
      image
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The canonical `assetId` is the blob id; the companion document is
  # `asset-<blob id>` and its draft twin `drafts.asset-<blob id>`. Accept every
  # spelling on the way in, emit the bare one.
  defp file_id("drafts.asset-" <> rest), do: rest
  defp file_id("asset-" <> rest), do: rest
  defp file_id(id), do: id

  defp scope(opts) when is_list(opts), do: Keyword.take(opts, [:workspace_id, :project_id])
  defp scope(_), do: []

  defp complete?(image) do
    Enum.all?(["url", "width", "height", "lqip"], fn k -> not blank?(Map.get(image, k)) end)
  end

  defp put_missing(image, _key, nil), do: image
  defp put_missing(image, _key, ""), do: image

  defp put_missing(image, key, value) do
    if blank?(Map.get(image, key)), do: Map.put(image, key, value), else: image
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp int(v) when is_integer(v) and v > 0, do: v

  defp int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp int(_), do: nil
end
