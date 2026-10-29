defmodule Barkpark.Media.Processing do
  @moduledoc """
  Upload-time metadata for a media blob: dimensions, the LQIP blur
  placeholder, and the processing status.

  Upload no longer builds renditions. Every size, crop and format is made on
  its first request (`Barkpark.Media.Renditions`, `Barkpark.Media.Transform`).
  What upload still needs is cheap and read once:

    * width and height from the file header (`Barkpark.Media.Probe`);
    * the LQIP, 20 px wide (PNG for a PNG source) as a `data:` URI, rendered in memory. It is
      also the decode check: a raster blob libvips cannot decode is marked
      `failed`, so a client never polls a `ready` asset whose every rendition
      would 404.

  Since task-fd05a9327034f89c it also reads what Sanity keeps on an image
  asset as `metadata` — `hasAlpha`, `isOpaque`, `blurHash`, the seven-swatch
  `palette` and, when the uploader asks (`:meta`, Sanity's `meta` upload
  parameter, the field's `options.metadata`), `exif` and `location`
  (`Barkpark.Media.ImageBackend.analyze/2`) — and writes it, with `dimensions`
  and `lqip`, under the asset document's `metadata` in Sanity's shape. A site
  reading `asset->metadata` finds what it found on Sanity.

  `extract/1` computes these; `asset_fields/1` turns them into the
  `mediaAsset` content the media plugin writes when it CREATES the asset
  document, so a fresh upload costs one document write. `process/1` is the
  re-drive for a document that already exists (the stuck-processing sweeper,
  rows born before this pipeline): one upsert, only when something changed.
  """

  alias Barkpark.Content
  alias Barkpark.Media.{Blobstore, ImageBackend, Probe, Renditions, Transform}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.Delivery.{Cdn, Events}
  alias Barkpark.Plugins.Media.Assets

  require Logger

  @asset_type "mediaAsset"

  @type extracted :: %{
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          lqip: String.t() | nil,
          status: String.t(),
          analysis: map() | nil
        }

  @doc "Re-drive processing for a blob whose `mediaAsset` document exists."
  @spec process(%MediaFile{}) :: :ok
  def process(%MediaFile{} = file),
    do: Barkpark.ManagedRuntime.WriteAdmission.Door.admit(fn -> admitted_process(file) end)

  defp admitted_process(%MediaFile{} = file) do
    case Assets.find_by_media_file_id(file.id, file.dataset, MediaFile.scope_opts(file)) do
      nil ->
        :ok

      doc ->
        extracted = extract(file)
        doc = record(doc, file, extracted)
        finish(file, doc, extracted)
    end
  end

  @doc """
  Read dimensions, the LQIP and Sanity's image metadata for `file`. Never
  raises: a blob that cannot be read yields nil metadata, and for a renderable
  raster image a `failed` status. `opts[:meta]` lists the optional metadata
  to read as well (`"exif"`, `"location"`).
  """
  @spec extract(%MediaFile{}, keyword()) :: extracted()
  def extract(%MediaFile{} = file, opts \\ []) do
    # ensure_local/1, not file_path/1: with an object-storage backend the
    # original may not be on this disk (post-import, or a cold cache) — the
    # blobstore fetches it once into the write-through cache before probing.
    # ROW-ADDRESSED (task-8eb6542ece62aff1) — probing a substituted object would
    # write ANOTHER tenant's real width/height onto this row's asset doc.
    case Blobstore.ensure_local(file) do
      {:ok, src} ->
        {width, height} = dimensions(src, file)
        {status, lqip} = lqip(src, file)
        analysis = if status == "ready", do: analyze(src, file, opts)
        %{width: width, height: height, lqip: lqip, status: status, analysis: analysis}

      {:error, reason} ->
        Logger.warning(
          "Barkpark.Media.Processing: blob unreadable for #{file.id}: #{inspect(reason)}"
        )

        status = if Renditions.renderable?(file), do: "failed", else: "ready"
        %{width: nil, height: nil, lqip: nil, status: status, analysis: nil}
    end
  rescue
    e ->
      Logger.warning("Barkpark.Media.Processing.extract #{file.id}: #{Exception.message(e)}")
      %{width: nil, height: nil, lqip: nil, status: "failed", analysis: nil}
  end

  @doc """
  The `mediaAsset` content keys `extracted` sets: `bp_processing_status`,
  `bp_cdn_status`, and `fileInfo.width`/`height`/`lqip`. The `fileInfo` map
  holds only those keys; the caller merges it over its own.
  """
  @spec asset_fields(extracted()) :: map()
  def asset_fields(extracted) do
    %{
      "bp_processing_status" => extracted.status,
      "bp_cdn_status" => Cdn.publish_status(),
      "fileInfo" =>
        %{
          "width" => int_string(extracted.width),
          "height" => int_string(extracted.height)
        }
        |> maybe_put("lqip", extracted.lqip)
    }
    |> maybe_put("metadata", sanity_metadata(extracted))
  end

  @doc """
  Sanity's `sanity.imageMetadata` for `extracted`, or nil when nothing was
  read (not an image, or a backend that cannot analyse).
  """
  @spec sanity_metadata(extracted()) :: map() | nil
  def sanity_metadata(%{analysis: %{} = a, width: w, height: h} = extracted)
      when is_integer(w) and is_integer(h) and h > 0 do
    %{
      "_type" => "sanity.imageMetadata",
      "dimensions" => %{
        "_type" => "sanity.imageDimensions",
        "width" => w,
        "height" => h,
        "aspectRatio" => w / h
      },
      "hasAlpha" => a.has_alpha,
      "isOpaque" => a.is_opaque
    }
    |> maybe_put("lqip", extracted.lqip)
    |> maybe_put("blurHash", a[:blur_hash])
    |> maybe_put("palette", a[:palette])
    |> maybe_put("exif", a[:exif])
    |> maybe_put("location", a[:location])
  end

  def sanity_metadata(_extracted), do: nil

  # Only a raster image the backend can decode is analysed; any failure there
  # leaves the metadata out and never fails the upload.
  defp analyze(src, %MediaFile{} = file, opts) do
    if Renditions.renderable?(file) do
      case ImageBackend.analyze(src, meta: Keyword.get(opts, :meta, [])) do
        {:ok, analysis} ->
          analysis

        {:error, :analyze_unsupported} ->
          nil

        {:error, reason} ->
          Logger.warning(
            "Barkpark.Media.Processing: metadata not read for #{file.id}: #{inspect(reason)}"
          )

          nil
      end
    end
  end

  @doc """
  After the asset document holds `extracted`: purge the CDN in the background
  and send the `media.processed` (or `media.processing_failed`) webhook.
  """
  @spec finish(%MediaFile{}, struct(), extracted()) :: :ok
  def finish(%MediaFile{} = file, doc, extracted) do
    Cdn.purge_async(file)

    event =
      case extracted.status do
        "failed" -> "media.processing_failed"
        _ -> "media.processed"
      end

    Events.dispatch(file.dataset, event, file, doc)
    :ok
  end

  @doc """
  Write `extracted` onto an existing asset document in ONE upsert, or skip the
  write when the document already holds those values.
  """
  @spec record(struct(), %MediaFile{}, extracted()) :: struct()
  def record(doc, %MediaFile{} = file, extracted) do
    content = doc.content || %{}
    fields = asset_fields(extracted)
    file_info = Map.merge(Map.get(content, "fileInfo", %{}), fields["fileInfo"])

    # A re-drive reads no EXIF or location (nobody asked again): what the
    # upload stored under `metadata` stays unless read anew.
    fields =
      case {content["metadata"], fields["metadata"]} do
        {%{} = old, %{} = new} -> Map.put(fields, "metadata", Map.merge(old, new))
        _ -> fields
      end

    new_content =
      content
      |> Map.merge(Map.delete(fields, "fileInfo"))
      |> Map.put("fileInfo", file_info)

    if new_content == content do
      doc
    else
      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => doc.title,
        "status" => doc.status,
        "content" => new_content
      }

      case Content.upsert_document(
             @asset_type,
             attrs,
             file.dataset,
             [source: :worker] ++ MediaFile.scope_opts(file)
           ) do
        {:ok, updated} ->
          updated

        {:error, reason} ->
          Logger.warning("Barkpark.Media.Processing failed: #{inspect(reason)}")
          doc
      end
    end
  end

  defp dimensions(src, %MediaFile{mime_type: mime}) do
    case Probe.probe(src, mime) do
      {:ok, %{width: w, height: h}} -> {w, h}
      _ -> {nil, nil}
    end
  end

  # Render the `lqip` preset to a temporary file outside the rendition cache,
  # read it, delete it. Nothing lands under `_renditions` at upload.
  # Reachability: `tmp` is `System.tmp_dir!/0` joined with a literal prefix and
  # a unique integer; no request or row data reaches the read or the delete.
  # sobelow_skip ["Traversal.FileModule"]
  defp lqip(src, %MediaFile{} = file) do
    if Renditions.renderable?(file) do
      spec = Renditions.spec_for(file, "lqip")

      tmp =
        Path.join(
          System.tmp_dir!(),
          "bp-lqip-#{System.unique_integer([:positive])}.#{spec.format}"
        )

      try do
        with :ok <- ImageBackend.impl().render(src, tmp, spec, nil),
             {:ok, bytes} when byte_size(bytes) > 0 <- File.read(tmp) do
          {"ready", "data:#{Transform.mime(spec.format)};base64," <> Base.encode64(bytes)}
        else
          other ->
            Logger.warning(
              "Barkpark.Media.Processing: LQIP failed for #{file.id}: #{inspect(other)}"
            )

            {"failed", nil}
        end
      after
        File.rm(tmp)
      end
    else
      {"ready", nil}
    end
  end

  defp int_string(n) when is_integer(n), do: Integer.to_string(n)
  defp int_string(_), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
