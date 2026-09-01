defmodule Barkpark.Media.Processing do
  @moduledoc """
  Post-upload pipeline: probe dimensions, generate renditions, patch asset doc.
  """

  alias Barkpark.Content
  alias Barkpark.Media.{Blobstore, Probe, Renditions}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.Delivery.{Cdn, Events}
  alias Barkpark.Plugins.Media.Assets

  @asset_type "mediaAsset"

  @doc "Run after a blob lands and its `mediaAsset` draft exists."
  @spec process(%MediaFile{}) :: :ok
  def process(%MediaFile{} = file) do
    case Assets.find_by_media_file_id(file.id, file.dataset) do
      nil ->
        :ok

      doc ->
        doc = set_status(doc, file, "processing")
        doc = maybe_probe_and_patch(doc, file)

        # Only report `ready` when renditions actually succeeded (or there were
        # none to make). If the whole rendition set failed, the asset is `failed`
        # — a bare `ready` would lie: serve_rendition would 404 on every preset.
        # "failed" is the established terminal state (see the processing-callback
        # controller's normalize_status/1).
        {status, event} =
          case Renditions.generate_all(file) do
            :ok -> {"ready", "media.processed"}
            {:error, _reason} -> {"failed", "media.processing_failed"}
          end

        doc = set_status(doc, file, status)
        Cdn.publish(file, doc)
        Events.dispatch(file.dataset, event, file, doc)
        :ok
    end
  end

  defp maybe_probe_and_patch(doc, %MediaFile{} = file) do
    # ensure_local/1, not file_path/1: with an object-storage backend the
    # original may not be on this disk (post-import, or a cold cache) — the
    # blobstore fetches it once into the write-through cache before probing.
    # ROW-ADDRESSED (task-8eb6542ece62aff1) — probing a substituted object would
    # write ANOTHER tenant's real width/height onto this row's asset doc.
    with {:ok, src} <- Blobstore.ensure_local(file),
         {:ok, %{width: w, height: h}} <- Probe.probe(src, file.mime_type) do
      patch_dimensions(doc, file, w, h)
    else
      _ -> doc
    end
  end

  defp patch_dimensions(doc, %MediaFile{} = file, width, height) do
    content = doc.content || %{}
    file_info = Map.get(content, "fileInfo", %{})

    file_info =
      file_info
      |> Map.put("width", Integer.to_string(width))
      |> Map.put("height", Integer.to_string(height))

    content = Map.put(content, "fileInfo", file_info)

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(
           @asset_type,
           attrs,
           file.dataset,
           [source: :worker] ++ Assets.file_scope_opts(file)
         ) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        log_failure(reason)
        doc
    end
  end

  defp set_status(doc, %MediaFile{} = file, status) do
    content = Map.put(doc.content || %{}, "bp_processing_status", status)

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(
           @asset_type,
           attrs,
           file.dataset,
           [source: :worker] ++ Assets.file_scope_opts(file)
         ) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        log_failure(reason)
        doc
    end
  end

  defp log_failure(reason) do
    require Logger
    Logger.warning("Barkpark.Media.Processing failed: #{inspect(reason)}")
    :ok
  end
end
