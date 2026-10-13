defmodule Barkpark.Media.Processing do
  @moduledoc """
  Upload-time metadata for a media blob: dimensions, the LQIP blur
  placeholder, and the processing status.

  Upload no longer builds renditions. Every size, crop and format is made on
  its first request (`Barkpark.Media.Renditions`, `Barkpark.Media.Transform`).
  What upload still needs is cheap and read once:

    * width and height from the file header (`Barkpark.Media.Probe`);
    * the LQIP, a ≤ 24 px JPEG as a `data:` URI, rendered in memory. It is
      also the decode check: a raster blob libvips cannot decode is marked
      `failed`, so a client never polls a `ready` asset whose every rendition
      would 404.

  `extract/1` computes these; `asset_fields/1` turns them into the
  `mediaAsset` content the media plugin writes when it CREATES the asset
  document, so a fresh upload costs one document write. `process/1` is the
  re-drive for a document that already exists (the stuck-processing sweeper,
  rows born before this pipeline): one upsert, only when something changed.
  """

  alias Barkpark.Content
  alias Barkpark.Media.{Blobstore, ImageBackend, Probe, Renditions}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.Delivery.{Cdn, Events}
  alias Barkpark.Plugins.Media.Assets

  require Logger

  @asset_type "mediaAsset"

  @type extracted :: %{
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          lqip: String.t() | nil,
          status: String.t()
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
  Read dimensions and the LQIP for `file`. Never raises: a blob that cannot be
  read yields nil metadata, and for a renderable raster image a `failed`
  status.
  """
  @spec extract(%MediaFile{}) :: extracted()
  def extract(%MediaFile{} = file) do
    # ensure_local/1, not file_path/1: with an object-storage backend the
    # original may not be on this disk (post-import, or a cold cache) — the
    # blobstore fetches it once into the write-through cache before probing.
    # ROW-ADDRESSED (task-8eb6542ece62aff1) — probing a substituted object would
    # write ANOTHER tenant's real width/height onto this row's asset doc.
    case Blobstore.ensure_local(file) do
      {:ok, src} ->
        {width, height} = dimensions(src, file)
        {status, lqip} = lqip(src, file)
        %{width: width, height: height, lqip: lqip, status: status}

      {:error, reason} ->
        Logger.warning(
          "Barkpark.Media.Processing: blob unreadable for #{file.id}: #{inspect(reason)}"
        )

        status = if Renditions.renderable?(file), do: "failed", else: "ready"
        %{width: nil, height: nil, lqip: nil, status: status}
    end
  rescue
    e ->
      Logger.warning("Barkpark.Media.Processing.extract #{file.id}: #{Exception.message(e)}")
      %{width: nil, height: nil, lqip: nil, status: "failed"}
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
      tmp = Path.join(System.tmp_dir!(), "bp-lqip-#{System.unique_integer([:positive])}.jpg")

      try do
        with :ok <- ImageBackend.impl().render(src, tmp, Renditions.preset_spec("lqip"), nil),
             {:ok, bytes} when byte_size(bytes) > 0 <- File.read(tmp) do
          {"ready", "data:image/jpeg;base64," <> Base.encode64(bytes)}
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
