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
  height — written by `Barkpark.Media.Processing` after upload), reached
  through `Barkpark.Media.asset_doc_for_file/3`; the blob itself via
  `Barkpark.Media.Probe` when `fileInfo` has no dimensions yet; and for
  `lqip` the `"lqip"` rendition preset (a ≤ 24 px JPEG, base64-encoded as a
  `data:` URI), generated on demand through `Barkpark.Media.Renditions` —
  never fabricated.

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

  def backfill(other, _dataset, _opts), do: other

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
  # `Media.file_path/1` (lib/barkpark/media.ex:930) then joins that under
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

  # The picker stores the blob id as `assetId`; the companion document is
  # `asset-<blob id>`. Accept either spelling.
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
