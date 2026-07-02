defmodule Barkpark.Media.Delivery.Events do
  @moduledoc """
  Outbound webhooks for the media lifecycle (`media.uploaded`, `media.processed`, `media.deleted`).

  Endpoints are configured via `:media_webhooks, :endpoints` — separate from
  document webhooks because media events are blob-centric.
  """

  require Logger
  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Tenancy
  alias Barkpark.Webhooks.Dispatcher

  @default_retry_delays_ms [100, 500, 2_000]

  @doc "Dispatch a media lifecycle event to configured webhook endpoints."
  @spec dispatch(String.t(), String.t(), struct(), struct() | nil) :: :ok
  def dispatch(dataset, event, file, doc \\ nil)
      when is_binary(dataset) and is_binary(event) do
    body = Jason.encode!(build_payload(event, dataset, file, doc))

    # Bounded fan-out: one outer supervised Task keeps the caller
    # non-blocking; inside it, async_stream_nolink on the dedicated
    # WebhookDeliverySupervisor runs at most `delivery_concurrency()`
    # deliveries at once and BACKPRESSURES beyond that (queues, never drops).
    # Contrast the old `start_child` per endpoint, which spawned an unbounded
    # number of long-lived processes on the shared :infinity TaskSupervisor.
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

  defp deliver(endpoint, body) do
    url = Map.get(endpoint, :url) || Map.get(endpoint, "url")

    if is_binary(url) and url != "" do
      timestamp = System.system_time(:second)
      secret = Map.get(endpoint, :secret) || Map.get(endpoint, "secret") || ""

      headers = [
        {"content-type", "application/json"},
        {"x-barkpark-timestamp", Integer.to_string(timestamp)},
        # Combined Stripe-style signature (`t=<unix>,v1=<hex>`) so the SDK
        # handler's parseSignatureHeader accepts it; matches dispatcher.ex.
        {"x-barkpark-signature",
         "t=#{timestamp},#{Dispatcher.sign_payload(body, timestamp, secret)}"}
      ]

      do_attempt(url, body, headers, 1)
    else
      :ok
    end
  end

  # Routes through Dispatcher.http_post/3 (the `:webhook_http_adapter` seam) so
  # media's outbound calls share document webhooks' policy (timeouts, SSRF guard)
  # instead of a bypassing Req.post. Adapter returns `{:ok, status}` /
  # `{:error, reason}` — media keeps its own retry-count/backoff shell.
  defp do_attempt(url, body, headers, attempt) do
    case Dispatcher.http_post(url, body, headers) do
      {:ok, status} when status in 200..299 ->
        :ok

      {:ok, status} when status in 400..499 ->
        Logger.warning("Media webhook delivery failed with #{status} (terminal)")
        :ok

      {:ok, status} ->
        retry(url, body, headers, attempt, "HTTP #{status}")

      {:error, reason} ->
        retry(url, body, headers, attempt, inspect(reason))
    end
  end

  defp retry(url, body, headers, attempt, reason) do
    delays = retry_delays()

    # Off-by-one guard (mirrors dispatcher.ex maybe_retry's `if n < max_attempts()`):
    # the final attempt (attempt == length(delays) + 1) has no delay left in the
    # table, so give up here instead of sleeping a pointless final delay.
    if attempt < length(delays) + 1 do
      delay = Enum.at(delays, attempt - 1, 2_000)

      Logger.warning(
        "Media webhook attempt #{attempt} failed (#{reason}), retrying in #{delay}ms"
      )

      Process.sleep(delay)
      do_attempt(url, body, headers, attempt + 1)
    else
      Logger.warning("Media webhook gave up after #{attempt} attempts (#{reason})")
      :ok
    end
  end

  # Backoff table (ms) between retries; tunable via `:media_webhook_retry_delays_ms`
  # (mirrors Dispatcher.retry_delays/0). Attempt count is length + 1.
  defp retry_delays do
    Application.get_env(:barkpark, :media_webhook_retry_delays_ms, @default_retry_delays_ms)
  end
end
