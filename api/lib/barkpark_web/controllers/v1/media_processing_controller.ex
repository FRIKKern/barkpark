defmodule BarkparkWeb.V1.MediaProcessingController do
  @moduledoc """
  Inbound callbacks from external media processors (transcode, AI tagging, etc.).

  ## Tenancy

  The route is FLAT (`/v1/media/:dataset/processing/:id/callback`) behind the
  `:media_processing_callback` pipeline, whose only credential is
  `RequireMediaProcessingCallbackToken` — ONE instance-wide shared secret. The
  conn therefore carries no workspace to scope by, and `Media.get_file/2` is
  deliberately an unscoped resolution: the blob id IS the tenant resolver here,
  exactly as it is for a webhook.

  Everything DOWNSTREAM of that resolution is confined to what it produced, via
  `Assets.file_scope_opts/1` — the same helper `Media.patch_asset_metadata/3`,
  `V1.MediaController.asset_doc/2` and `AssetResponse.render/3` already use, so
  the lookup, the write-back and the rendered response cannot disagree about
  which tenant's document they mean.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Delivery.{AssetResponse, Cdn, Events}
  alias Barkpark.Plugins.Media.Assets

  action_fallback BarkparkWeb.FallbackController

  @asset_type "mediaAsset"

  # Content keys this controller OWNS. A processor's `metadata` may never write
  # them: they are the controller's own state record, and a caller-supplied
  # value for either one both loses the real state and (for
  # `bp_external_processing`) persists a non-map that the NEXT callback would
  # `Map.put/3` over. See `maybe_merge_metadata/2`.
  @reserved_content_keys ["bp_processing_status", "bp_external_processing"]

  def callback(conn, %{"dataset" => dataset, "id" => id} = params) do
    # Unscoped by design — see the moduledoc. This resolution is what DEFINES
    # the tenant for the rest of the action.
    with {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         scope = Assets.file_scope_opts(file),
         %{} = doc <- Media.asset_doc_for_file(file, dataset, scope) || {:error, :not_found} do
      status = normalize_status(params["status"] || params["processingStatus"])
      doc = patch_callback(doc, file, params, status, scope)

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

  defp patch_callback(doc, file, params, status, scope) do
    content = doc.content || %{}
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    external =
      content
      |> external_processing_record()
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

    case Content.upsert_document(
           @asset_type,
           attrs,
           file.dataset,
           [source: :api] ++ scope
         ) do
      {:ok, updated} -> updated
      _ -> Map.put(doc, :content, content)
    end
  end

  # RECOVERY, not just prevention. `@reserved_content_keys` stops a NEW poisoned
  # value from landing, but an asset poisoned before that guard shipped still
  # holds a non-map at `bp_external_processing`, and `Map.put/3` over it raises
  # BadMapError — a 500 on every future callback for that blob, with no path
  # that ever repairs it. Starting from a fresh map whenever the stored value is
  # not one heals the row on its next callback instead of stranding it.
  defp external_processing_record(%{"bp_external_processing" => %{} = record}), do: record
  defp external_processing_record(_content), do: %{}

  # Merge a processor's free-form `metadata`, minus the keys this controller
  # owns. The merge deliberately stays LAST, exactly where it was: a processor's
  # metadata still wins over anything already in `content` for every key that is
  # genuinely its to write. `@reserved_content_keys` is the single guard, so
  # removing it re-opens the poisoning — the alternative of merely reordering
  # this call would leave a second, silent way for a caller value to reach the
  # jsonb the moment someone moved the pipeline back.
  defp maybe_merge_metadata(content, metadata) when is_map(metadata) do
    Enum.reduce(metadata, content, fn {k, v}, acc ->
      if is_binary(k) and not is_nil(v) and k not in @reserved_content_keys,
        do: Map.put(acc, k, v),
        else: acc
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
