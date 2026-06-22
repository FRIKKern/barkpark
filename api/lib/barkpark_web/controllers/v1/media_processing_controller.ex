defmodule BarkparkWeb.V1.MediaProcessingController do
  @moduledoc """
  Inbound callbacks from external media processors (transcode, AI tagging, etc.).
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Delivery.{AssetResponse, Cdn, Events}

  action_fallback BarkparkWeb.FallbackController

  @asset_type "mediaAsset"

  def callback(conn, %{"dataset" => dataset, "id" => id} = params) do
    with {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         %{} = doc <- Media.asset_doc_for_file(file, dataset) || {:error, :not_found} do
      status = normalize_status(params["status"] || params["processingStatus"])
      doc = patch_callback(doc, file, params, status)

      case status do
        "ready" ->
          Cdn.publish(file, doc)
          Events.dispatch(dataset, "media.processed", file, doc)

        "failed" ->
          Events.dispatch(dataset, "media.processing_failed", file, doc)

        _ ->
          :ok
      end

      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset),
        syncTags: ["bp:ds:#{dataset}:media:#{file.id}"]
      })
    end
  end

  defp patch_callback(doc, file, params, status) do
    content = doc.content || %{}
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    external =
      (Map.get(content, "bp_external_processing") || %{})
      |> Map.put("provider", params["provider"] || Map.get(params, "processor"))
      |> Map.put("jobId", params["jobId"] || params["job_id"])
      |> Map.put("lastCallbackAt", now)

    content =
      content
      |> Map.put("bp_processing_status", status)
      |> Map.put("bp_external_processing", external)
      |> maybe_merge_metadata(params["metadata"])

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => params["title"] || doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(@asset_type, attrs, file.dataset, source: :api) do
      {:ok, updated} -> updated
      _ -> Map.put(doc, :content, content)
    end
  end

  defp maybe_merge_metadata(content, metadata) when is_map(metadata) do
    Enum.reduce(metadata, content, fn {k, v}, acc ->
      if is_binary(k) and not is_nil(v), do: Map.put(acc, k, v), else: acc
    end)
  end

  defp maybe_merge_metadata(content, _), do: content

  defp normalize_status("complete"), do: "ready"
  defp normalize_status("completed"), do: "ready"
  defp normalize_status("error"), do: "failed"
  defp normalize_status(status) when status in ["ready", "processing", "failed"], do: status
  defp normalize_status(_), do: "processing"

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}
end
