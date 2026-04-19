defmodule Barkpark.Webhooks.Dispatcher do
  @moduledoc """
  Delivers webhook payloads with HMAC signing, retries, and per-event dedup.

  Wire format (Stripe-inspired):

    X-Barkpark-Timestamp: <unix-seconds>
    X-Barkpark-Signature: v1=<hex HMAC-SHA256(secret, "timestamp.body")>
    X-Barkpark-Event-ID:  <mutation_events.id>

  Retries follow fixed backoff `[1s, 5s, 30s]` with `@max_attempts` attempts
  total on 5xx or transport error. 4xx responses are terminal (no retry).
  Delivery is deduped via UNIQUE(endpoint_id, event_id) in `webhook_deliveries`.
  """

  require Logger
  alias Barkpark.Webhooks

  @default_retry_delays_ms [1_000, 5_000, 30_000]
  @default_max_attempts 3

  @doc """
  Public entry point called from `Content.tap_broadcast/5`. Spawns one
  supervised Task per matching webhook so a slow endpoint cannot block
  callers or other deliveries.
  """
  def dispatch_async(dataset, event, type, doc_id, document, event_id)
      when is_integer(event_id) do
    body = Jason.encode!(build_payload(event, type, doc_id, document, dataset))
    webhooks = Webhooks.active_webhooks_for(dataset, event, type)

    Enum.each(webhooks, fn wh ->
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        deliver(wh, body, event_id)
      end)
    end)
  end

  # Back-compat: callers that haven't threaded event_id through yet.
  # Dedup is skipped in this path; retry + signing still apply.
  def dispatch_async(dataset, event, type, doc_id, document) do
    body = Jason.encode!(build_payload(event, type, doc_id, document, dataset))
    webhooks = Webhooks.active_webhooks_for(dataset, event, type)

    Enum.each(webhooks, fn wh ->
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        deliver_without_dedup(wh, body)
      end)
    end)
  end

  @doc "Builds the JSON-serialisable payload map."
  def build_payload(event, type, doc_id, document, dataset) do
    %{
      event: event,
      type: type,
      doc_id: doc_id,
      document: document,
      dataset: dataset,
      sync_tags: [
        "bp:ds:#{dataset}:doc:#{doc_id}",
        "bp:ds:#{dataset}:type:#{type}"
      ],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Returns a `v1=<hex>` HMAC-SHA256 signature of `"timestamp.body"` using
  the given secret. Timestamp is unix seconds.
  """
  def sign_payload(body, timestamp, secret)
      when is_binary(body) and is_integer(timestamp) and is_binary(secret) do
    material = "#{timestamp}.#{body}"
    sig = :crypto.mac(:hmac, :sha256, secret, material) |> Base.encode16(case: :lower)
    "v1=#{sig}"
  end

  @doc """
  Verifies an incoming signature against the list of currently-effective
  secrets (primary + unexpired previous). Constant-time comparison.
  """
  def verify_signature(body, timestamp, signature_header, secrets)
      when is_list(secrets) do
    Enum.any?(secrets, fn s ->
      expected = sign_payload(body, timestamp, s)
      Plug.Crypto.secure_compare(expected, signature_header)
    end)
  end

  @doc """
  Synchronous delivery with retries and dedup. Used by `dispatch_async/6`
  and directly in tests. Returns `{:ok, status, attempts}` on success,
  `{:error, reason, attempts}` on terminal failure, or
  `{:skipped, :already_delivered}` when the (endpoint, event) pair is
  already recorded.
  """
  def deliver(webhook, body, event_id) when is_integer(event_id) do
    case Webhooks.claim_delivery(webhook.id, event_id) do
      {:ok, delivery} ->
        attempt(webhook, body, event_id, delivery, 1)

      {:error, :already_delivered} ->
        {:skipped, :already_delivered}

      {:error, _} = err ->
        err
    end
  end

  defp deliver_without_dedup(webhook, body) do
    attempt(webhook, body, nil, nil, 1)
  end

  defp attempt(webhook, body, event_id, delivery, n) do
    timestamp = System.system_time(:second)
    sig = sign_payload(body, timestamp, webhook.secret || "")

    base_headers = [
      {"content-type", "application/json"},
      {"x-barkpark-signature", sig},
      {"x-barkpark-timestamp", Integer.to_string(timestamp)}
    ]

    headers =
      if event_id, do: [{"x-barkpark-event-id", Integer.to_string(event_id)} | base_headers], else: base_headers

    case http_post(webhook.url, body, headers) do
      {:ok, status} when status in 200..299 ->
        if delivery, do: Webhooks.mark_delivered(delivery, status, n)
        Logger.info("Webhook #{webhook.name} delivered (#{status}) on attempt #{n}")
        {:ok, status, n}

      {:ok, status} when status in 400..499 ->
        reason = "http #{status}"
        if delivery, do: Webhooks.mark_giveup(delivery, status, reason, n)
        Logger.warning("Webhook #{webhook.name} gave up: 4xx (#{status})")
        {:error, :giveup_4xx, n}

      {:ok, status} ->
        maybe_retry(webhook, body, event_id, delivery, n, status, "http #{status}")

      {:error, reason} ->
        maybe_retry(webhook, body, event_id, delivery, n, nil, inspect(reason))
    end
  end

  defp maybe_retry(webhook, body, event_id, delivery, n, last_status, reason_text) do
    if n < max_attempts() do
      delay = Enum.at(retry_delays(), n - 1) || List.last(retry_delays())
      Process.sleep(delay)
      attempt(webhook, body, event_id, delivery, n + 1)
    else
      if delivery, do: Webhooks.mark_giveup(delivery, last_status, reason_text, n)
      Logger.warning("Webhook #{webhook.name} gave up after #{n} attempts: #{reason_text}")
      {:error, :exhausted, n}
    end
  end

  defp http_post(url, body, headers) do
    adapter = Application.get_env(:barkpark, :webhook_http_adapter, __MODULE__.ReqAdapter)
    adapter.post(url, body, headers)
  end

  defp retry_delays do
    Application.get_env(:barkpark, :webhook_retry_delays_ms, @default_retry_delays_ms)
  end

  defp max_attempts do
    Application.get_env(:barkpark, :webhook_max_attempts, @default_max_attempts)
  end

  defmodule ReqAdapter do
    @moduledoc false

    def post(url, body, headers) do
      case Req.post(url, body: body, headers: headers, receive_timeout: 10_000) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
