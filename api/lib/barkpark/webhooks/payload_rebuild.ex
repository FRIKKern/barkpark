defmodule Barkpark.Webhooks.PayloadRebuild do
  @moduledoc """
  Rebuilds the `{webhook, body}` needed to RESUME a durable `webhook_deliveries`
  row. This is the SINGLE place the `source_kind` branch lives — shared by both
  crash-recovery drivers (`RetryWorker`, `StuckDeliverySweeper`) so the two can
  never drift (a divergent second rebuild path is exactly the twin the media
  convergence set out to kill):

    * `"document"` — the payload is rebuilt from the durable `mutation_events` row
      (`event_id`), which stays the source of truth, and the webhook is the live
      `webhooks` row (`endpoint_id`). `payload_snapshot` is NIL for these.
    * `"media"` — the source event is gone by design (`media.deleted` passes the
      file struct at delete time; nothing persists it), so the body is read back
      verbatim from the row's `payload_snapshot`, and a TRANSIENT (unpersisted)
      `%Webhook{}` carrying the snapshotted url/secret re-signs the attempt.
      `endpoint_id` / `event_id` are NULL for these.

  Returns `{:ok, webhook, body}`, or `:gone` when the row is no longer recoverable
  — a document row whose webhook/event was cascade-deleted, or a media row with a
  malformed/absent snapshot — in which case the caller skips without delivering.
  """

  require Logger

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Delivery, Dispatcher, Webhook}

  def rebuild(%Delivery{source_kind: "media"} = delivery) do
    case delivery.payload_snapshot do
      %{"url" => url, "body" => body} = snap when is_binary(url) and is_binary(body) ->
        secret = Map.get(snap, "secret") || ""
        # Transient, UNPERSISTED webhook struct — just enough for the signed
        # attempt loop (url + secret + name for the log line). id is nil, so the
        # terminal mark_* writes count against no endpoint (media is config-driven).
        {:ok, %Webhook{id: nil, name: "media", url: url, secret: secret}, body}

      _ ->
        Logger.warning(
          "Media webhook delivery ##{delivery.id} has no usable payload_snapshot; skipping"
        )

        :gone
    end
  end

  def rebuild(%Delivery{} = delivery) do
    with %Webhook{} = webhook <- Repo.get(Webhook, delivery.endpoint_id),
         %MutationEvent{} = event <- Repo.get(MutationEvent, delivery.event_id) do
      body =
        Dispatcher.build_payload(
          event.mutation,
          event.type,
          event.doc_id,
          event.document,
          event.dataset,
          workspace_id: event.workspace_id,
          project_id: event.project_id
        )
        |> Jason.encode!()

      {:ok, webhook, body}
    else
      nil -> :gone
    end
  end
end
