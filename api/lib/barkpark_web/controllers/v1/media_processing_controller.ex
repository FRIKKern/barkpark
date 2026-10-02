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
  `MediaFile.scope_opts/1` (the CORE row-scope accessor, ex-`Assets.file_scope_opts/1`)
  — the same helper `Media.patch_asset_metadata/3`,
  `V1.MediaController.asset_doc/2` and `AssetResponse.render/3` already use, so
  the lookup, the write-back and the rendered response cannot disagree about
  which tenant's document they mean.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Delivery.{AssetResponse, Cdn, Events}
  alias Barkpark.Media.Storage.MediaFile
  alias BarkparkWeb.ErrorResponse

  action_fallback BarkparkWeb.FallbackController

  @asset_type "mediaAsset"

  # Content keys this controller OWNS. A processor's `metadata` may never write
  # them: they are the controller's own state record, and a caller-supplied
  # value for either one both loses the real state and (for
  # `bp_external_processing`) persists a non-map that the NEXT callback would
  # `Map.put/3` over. See `maybe_merge_metadata/2`.
  @reserved_content_keys ["bp_processing_status", "bp_external_processing"]

  # Every status string an external processor may legitimately send, echoed in
  # the 422 so a mis-integrated processor can fix itself in one round trip.
  # Kept beside `normalize_status/1`, which is the clause list it describes.
  @accepted_statuses ["ready", "processing", "failed", "complete", "completed", "error"]

  def callback(conn, %{"dataset" => dataset, "id" => id} = params) do
    # REFUSE BEFORE RESOLVING. An unrecognised (or absent) `status` used to fall
    # through `normalize_status/1`'s catch-all to "processing", which REWROTE a
    # terminal row: an asset the sweeper had given up on as "failed" went back
    # to "processing" and re-armed the reconciliation loop, on nothing more than
    # a typo or a forged callback. There is no status this endpoint can infer —
    # the processor is the only thing that knows — so the only honest answer is
    # 422 and NO write. The check is first because it reads the BODY only; a
    # malformed body is refused without a tenant lookup.
    case normalize_status(params["status"] || params["processingStatus"]) do
      {:ok, status} -> do_callback(conn, dataset, id, params, status)
      :error -> refuse_unknown_status(conn, params["status"] || params["processingStatus"])
    end
  end

  defp do_callback(conn, dataset, id, params, status) do
    # Unscoped by design — see the moduledoc. This resolution is what DEFINES
    # the tenant for the rest of the action.
    with {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         scope = MediaFile.scope_opts(file),
         %{} = doc <- Media.asset_doc_for_file(file, dataset, scope) || {:error, :not_found} do
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

  # The CLOSED set of inbound statuses. Everything a processor may legitimately
  # send is named here; the catch-all refuses instead of guessing, because the
  # only guess available ("processing") is the one that destroys a terminal
  # state. `nil` (no `status` and no `processingStatus` in the body) lands on
  # the catch-all too — an untyped callback is exactly as uninterpretable as a
  # mistyped one.
  defp normalize_status("complete"), do: {:ok, "ready"}
  defp normalize_status("completed"), do: {:ok, "ready"}
  defp normalize_status("error"), do: {:ok, "failed"}

  defp normalize_status(status) when status in ["ready", "processing", "failed"],
    do: {:ok, status}

  defp normalize_status(_), do: :error

  # 422 with the `unprocessable` code the v1 error vocabulary already carries
  # (`Content.Errors.known_codes/0`) — no new code enters the shared registry
  # for a one-endpoint body validation. Emitted through `ErrorResponse`, the
  # single §9 envelope owner, so the response carries `request_id` and the
  # code-keyed `hint` like every other refusal. Hand-building the envelope map
  # here instead is caught by `ErrorEnvelopeForkGuardTest`, which greps this
  # file's TEXT — so do not spell the forked shape out even in a comment.
  defp refuse_unknown_status(conn, raw) do
    ErrorResponse.emit_custom(
      conn,
      422,
      "unprocessable",
      "unrecognised processing status #{inspect(raw)} — expected one of " <>
        Enum.join(@accepted_statuses, ", "),
      %{accepted: @accepted_statuses}
    )
  end

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}
end
