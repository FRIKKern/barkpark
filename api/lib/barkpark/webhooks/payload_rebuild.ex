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

  # A chat_blocked row (herd layer, charter D57h) targets a real workspace-scoped
  # `webhooks` row (`endpoint_id`) but has no `mutation_events` source
  # (`event_id` NULL), so the signed body was snapshotted at claim time and is
  # read back verbatim — NEVER rebuilt from the ask (the pending row may already
  # have been answered/deleted by retry time). MUST precede the catch-all clause:
  # the catch-all's `Repo.get(MutationEvent, nil)` RAISES on a NULL event_id, so
  # without this a snapshot-carrying retry would crash RetryWorker /
  # StuckDeliverySweeper instead of resuming.
  def rebuild(%Delivery{source_kind: "chat_blocked"} = delivery) do
    with %Webhook{} = webhook <- Repo.get(Webhook, delivery.endpoint_id),
         %{"body" => body} when is_binary(body) <- delivery.payload_snapshot do
      {:ok, webhook, body}
    else
      _ -> :gone
    end
  end

  # An audit row (auth-event bridge, era-w7) targets a real `webhooks` row
  # (`endpoint_id`) but has no `mutation_events` source (`event_id` NULL — the
  # source lives in `audit_events`, a different table), so the body is
  # re-encoded from the row's `payload_snapshot`. Unlike chat_blocked, the
  # snapshot is the RAW decoded payload map `Dispatcher.deliver_audit/2` stored
  # (`Jason.decode!(body)`), NOT a `%{"body" => body}` wrapper — so the whole
  # map is re-encoded (semantically equivalent; the attempt loop re-signs
  # whatever body it is handed, so exact byte order is irrelevant). MUST precede
  # the catch-all clause: its `Repo.get(MutationEvent, nil)` RAISES on the NULL
  # event_id, and `StuckDeliverySweeper.sweep/1`'s reduce is unguarded, so one
  # audit row would abort recovery for the whole cron batch.
  def rebuild(%Delivery{source_kind: "audit"} = delivery) do
    with %Webhook{} = webhook <- Repo.get(Webhook, delivery.endpoint_id),
         snapshot when is_map(snapshot) <- delivery.payload_snapshot do
      {:ok, webhook, Jason.encode!(snapshot)}
    else
      _ ->
        Logger.warning(
          "Audit webhook delivery ##{delivery.id} is unrecoverable (webhook deleted or no usable payload_snapshot); skipping"
        )

        :gone
    end
  end

  # A "test" row (GR45) is a one-shot admin probe: the synchronous single attempt
  # in `Dispatcher.deliver_test/3` already wrote its verdict. A row stranded
  # "pending" by a crash mid-probe is never worth resuming (the admin has long
  # moved on and would just re-click), so it is abandoned. MUST precede the
  # catch-all: that clause's `Repo.get(MutationEvent, nil)` — `event_id` is NULL
  # for a test — would crash the sweeper / RetryWorker instead of skipping.
  def rebuild(%Delivery{source_kind: "test"}), do: :gone

  # Document catch-all — the DEFAULT rebuild path. Guarded on an INTEGER
  # `event_id`: the durable `mutation_events` row is the source of truth, so
  # `Repo.get(MutationEvent, event_id)` must never be handed a nil (Ecto raises
  # ArgumentError "cannot perform Ecto.Repo.get/2 because the given value is nil"
  # at query-build time — BEFORE any DB round-trip — so the `with/else nil` arm
  # can NEVER catch it; a crash-orphan document row with a NULL event_id, or any
  # future untyped kind, would abort the whole StuckDeliverySweeper batch).
  def rebuild(%Delivery{event_id: event_id} = delivery) when is_integer(event_id) do
    with %Webhook{} = webhook <- Repo.get(Webhook, delivery.endpoint_id),
         %MutationEvent{} = event <- Repo.get(MutationEvent, event_id) do
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

  # Terminal fallback: any delivery that matched no typed clause AND has no
  # integer `event_id` to rebuild from is unrecoverable. Return `:gone` (the
  # caller skips) rather than fall into the guarded catch-all's
  # `Repo.get(MutationEvent, nil)` raise — a single such poison row must never
  # crash RetryWorker or abort a StuckDeliverySweeper batch. Logged LOUDLY,
  # naming the row so an operator can see what stranded.
  def rebuild(%Delivery{} = delivery) do
    Logger.warning(
      "Webhook delivery ##{delivery.id} is unrecoverable " <>
        "(source_kind=#{inspect(delivery.source_kind)}, event_id=#{inspect(delivery.event_id)}); skipping"
    )

    :gone
  end
end
