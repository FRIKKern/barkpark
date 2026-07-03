defmodule Barkpark.Media.Delivery.Events do
  @moduledoc """
  Outbound webhooks for the media lifecycle (`media.uploaded`, `media.processed`,
  `media.deleted`).

  Endpoints are configured via `:media_webhooks, :endpoints` — separate from
  document webhooks because media events are blob-centric.

  ## Converged onto the shared durable-row retry machinery

  A media delivery is NOT retried by an in-task `Process.sleep` anymore. Each
  configured endpoint gets a durable `webhook_deliveries` row (`source_kind:
  "media"`) whose `payload_snapshot` carries the url/secret/body, and the FIRST
  attempt runs through `Dispatcher.deliver_media/3` — the SAME state machine as
  document webhooks. On a retryable failure the dispatcher SCHEDULES the next
  attempt (`RetryWorker`) and RETURNS, freeing the bounded
  `WebhookDeliverySupervisor` slot instead of parking it in a backoff sleep (the
  old head-of-line-blocking twin). A crashed / BEAM-restarted attempt is recovered
  by the `StuckDeliverySweeper`, which rebuilds the media payload FROM the snapshot
  (media's source event is gone by design — `media.deleted` passes the file struct
  at delete time, nothing persists it). Media therefore inherits the SAME retry
  policy as document webhooks (`:webhook_retry_delays_ms` / `:webhook_max_attempts`)
  and the SAME lifecycle (`pending → ok / failed_giveup`).
  """

  require Logger
  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Tenancy
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Dispatcher, Webhook}

  @doc "Dispatch a media lifecycle event to configured webhook endpoints."
  @spec dispatch(String.t(), String.t(), struct(), struct() | nil) :: :ok
  def dispatch(dataset, event, file, doc \\ nil)
      when is_binary(dataset) and is_binary(event) do
    body = Jason.encode!(build_payload(event, dataset, file, doc))

    # Bounded fan-out: one outer supervised Task keeps the caller non-blocking;
    # inside it, async_stream_nolink on the dedicated WebhookDeliverySupervisor
    # runs at most `delivery_concurrency()` FIRST attempts at once and
    # BACKPRESSURES beyond that (queues, never drops). Each first attempt persists
    # a durable row and (on a retryable failure) SCHEDULES its retry off-slot, so
    # the pool is never saturated by sleeping tasks under a retry storm.
    endpoints = endpoints(dataset, event)

    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
      Barkpark.WebhookDeliverySupervisor
      |> Task.Supervisor.async_stream_nolink(
        endpoints,
        fn endpoint ->
          deliver(endpoint, body)
        end,
        max_concurrency: delivery_concurrency(),
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end)

    :ok
  end

  defp delivery_concurrency do
    Application.get_env(:barkpark, :webhook_delivery_concurrency, 100)
  end

  @doc "Build webhook payload map."
  @spec build_payload(String.t(), String.t(), struct(), struct() | nil) :: map()
  def build_payload(event, dataset, file, doc) do
    # Scope the sync-tags to the file's workspace/project so tenancy-correct
    # cache revalidation fires (mirrors dispatcher.ex build_payload). The legacy
    # `bp:ds:*` tags are retained for back-compat. resolve_scope_slugs handles
    # nil ids without a DB hit, falling back to the "default" slug.
    {ws_slug, project_slug} = Tenancy.resolve_scope_slugs(file.workspace_id, file.project_id)
    scoped = "bp:ws:#{ws_slug}:p:#{project_slug}:ds:#{dataset}"

    %{
      event: event,
      dataset: dataset,
      media_file_id: file.id,
      asset_doc_id: doc && doc.doc_id,
      mime_type: file.mime_type,
      filename: file.filename,
      original_name: file.original_name,
      paths: Cdn.invalidation_paths(file),
      cdn_urls: Cdn.url_map(file),
      sync_tags: [
        "#{scoped}:media",
        "#{scoped}:media:#{file.id}",
        "bp:ds:#{dataset}:media",
        "bp:ds:#{dataset}:media:#{file.id}"
      ],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp endpoints(dataset, event) do
    Application.get_env(:barkpark, :media_webhooks, [])
    |> Keyword.get(:endpoints, [])
    |> Enum.filter(fn endpoint ->
      endpoint_dataset = Map.get(endpoint, :dataset) || Map.get(endpoint, "dataset")
      events = Map.get(endpoint, :events) || Map.get(endpoint, "events") || []

      endpoint_dataset in [nil, "", dataset] and event in List.wrap(events)
    end)
  end

  # Persist a durable media delivery row (snapshotting url/secret/body — media's
  # source event is gone by design), then run the FIRST attempt through the shared
  # dispatcher. A retryable failure is SCHEDULED off-slot by the dispatcher; a
  # crash is recovered by the StuckDeliverySweeper. No in-task sleep.
  defp deliver(endpoint, body) do
    url = Map.get(endpoint, :url) || Map.get(endpoint, "url")

    if is_binary(url) and url != "" do
      secret = Map.get(endpoint, :secret) || Map.get(endpoint, "secret") || ""
      snapshot = %{"url" => url, "secret" => secret, "body" => body}

      case Webhooks.create_media_delivery(snapshot) do
        {:ok, delivery} ->
          webhook = %Webhook{id: nil, name: "media", url: url, secret: secret}
          _ = Dispatcher.deliver_media(webhook, body, delivery)
          :ok

        {:error, reason} ->
          # Durable row couldn't be persisted (rare DB hiccup). Don't strand the
          # event: fall back to a SINGLE best-effort signed attempt (no retry, no
          # in-slot sleep — the twin sleep path is gone). Degraded, but not silent.
          Logger.warning(
            "Media webhook: could not persist durable delivery row " <>
              "(#{inspect(reason)}); single best-effort attempt"
          )

          single_shot(url, secret, body)
          :ok
      end
    else
      :ok
    end
  end

  # Degraded fallback ONLY when the durable row can't be inserted: one best-effort
  # POST through the shared adapter seam, no retry loop, no sleep. Matches the media
  # wire format (content-type + combined signature + x-barkpark-timestamp) — the
  # signature pair is OMITTED when the secret is blank (see `Dispatcher.signature_headers/3`).
  defp single_shot(url, secret, body) do
    timestamp = System.system_time(:second)

    # OMIT the signature on a blank secret — an empty-key HMAC is fake
    # authenticity. An absent header honestly signals "unsigned" to the consumer.
    if Dispatcher.blank_secret?(secret) do
      Logger.warning(
        "Media webhook #{url} has a blank/nil secret — single best-effort " <>
          "attempt delivered UNSIGNED (x-barkpark-signature omitted)."
      )
    end

    headers =
      [
        {"content-type", "application/json"}
        | Dispatcher.signature_headers(body, timestamp, secret)
      ]

    _ = Dispatcher.http_post_resp(url, body, headers)
    :ok
  end
end
