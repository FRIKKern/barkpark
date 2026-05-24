defmodule Barkpark.Media.Processing do
  @moduledoc """
  Post-upload pipeline: probe dimensions, generate renditions, patch asset doc.
  """

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.{MediaFile, Probe, Renditions}
  alias Barkpark.Media.{Cdn, Events}
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
        _ = Renditions.generate_all(file)
        doc = set_status(doc, file, "ready")
        Cdn.publish(file, doc)
        Events.dispatch(file.dataset, "media.processed", file, doc)
        :ok
    end
  end

  defp maybe_probe_and_patch(doc, %MediaFile{} = file) do
    src = Media.file_path(file.path)

    case Probe.probe(src, file.mime_type) do
      {:ok, %{width: w, height: h}} ->
        patch_dimensions(doc, file, w, h)

      {:error, _} ->
        doc
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

    case Content.upsert_document(@asset_type, attrs, file.dataset, source: :worker) do
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

    case Content.upsert_document(@asset_type, attrs, file.dataset, source: :worker) do
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
