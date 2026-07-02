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
  alias Barkpark.Tenancy

  @default_retry_delays_ms [1_000, 5_000, 30_000]
  @default_max_attempts 3

  @doc """
  Public entry point called from `Content.tap_broadcast/5`. Spawns one
  supervised Task per matching webhook so a slow endpoint cannot block
  callers or other deliveries.

  `opts` may carry `:workspace_id` / `:project_id` so the delivered payload
  emits workspace/project-scoped sync-tags. When absent, the scope is
  resolved to the default slugs (pre-tenancy back-compat path).
  """
  def dispatch_async(dataset, event, type, doc_id, document, event_id, opts \\ [])
      when is_integer(event_id) do
    body = Jason.encode!(build_payload(event, type, doc_id, document, dataset, opts))
    # Scope selection to the changed doc's workspace/project so a content
    # change in workspace B never selects (or delivers to) workspace A's
    # webhooks. `opts` carries `:workspace_id` / `:project_id`; an unscoped
    # caller (no workspace_id) keeps the dataset-only behaviour.
    webhooks = Webhooks.active_webhooks_for(dataset, event, type, opts)

    fan_out(webhooks, fn wh -> deliver(wh, body, event_id) end)
  end

  # Back-compat: callers that haven't threaded event_id through yet.
  # Dedup is skipped in this path; retry + signing still apply.
  def dispatch_async(dataset, event, type, doc_id, document) do
    body = Jason.encode!(build_payload(event, type, doc_id, document, dataset))
    webhooks = Webhooks.active_webhooks_for(dataset, event, type)

    fan_out(webhooks, fn wh -> deliver_without_dedup(wh, body) end)
  end

  # Bounded fan-out. One outer supervised Task keeps the caller non-blocking;
  # inside it, async_stream_nolink on the dedicated WebhookDeliverySupervisor
  # runs at most `delivery_concurrency()` deliveries at once and BACKPRESSURES
  # beyond that (queues, never drops — there is no {:error, :max_children}
  # path). Contrast the old `start_child` per webhook, which spawned an
  # unbounded number of long-lived processes on the shared :infinity
  # TaskSupervisor.
  defp fan_out(webhooks, deliver_fun) do
    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
      Barkpark.WebhookDeliverySupervisor
      |> Task.Supervisor.async_stream_nolink(webhooks, deliver_fun,
        max_concurrency: delivery_concurrency(),
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()
    end)
  end

  defp delivery_concurrency do
    Application.get_env(:barkpark, :webhook_delivery_concurrency, 100)
  end

  @doc """
  Builds the JSON-serialisable payload map.

  `opts` may carry `:workspace_id` / `:project_id`; their slugs are resolved
  via `Tenancy.resolve_scope_slugs/2` to form the workspace/project-scoped
  sync-tags `bp:ws:<ws>:p:<project>:ds:<dataset>:*`. The legacy `bp:ds:*`
  tags are retained for back-compat. The resolved slugs are also surfaced
  on the payload as `workspace`/`project` (and the raw ids when given).
  """
  def build_payload(event, type, doc_id, document, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    {ws_slug, project_slug} = Tenancy.resolve_scope_slugs(workspace_id, project_id)

    scoped = "bp:ws:#{ws_slug}:p:#{project_slug}:ds:#{dataset}"

    %{
      event: event,
      type: type,
      doc_id: doc_id,
      document: document,
      dataset: dataset,
      workspace: ws_slug,
      project: project_slug,
      workspace_id: workspace_id,
      project_id: project_id,
      sync_tags: [
        "#{scoped}:doc:#{doc_id}",
        "#{scoped}:type:#{type}",
        # Legacy dataset-only tags retained for back-compat.
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
    sig = strip_ts_prefix(signature_header)

    Enum.any?(secrets, fn s ->
      expected = sign_payload(body, timestamp, s)
      Plug.Crypto.secure_compare(expected, sig)
    end)
  end

  # Accept both the raw `v1=<hex>` and the combined `t=<unix>,v1=<hex>` header
  # forms, returning the `v1=<hex>` portion `sign_payload/3` produces.
  defp strip_ts_prefix(header) when is_binary(header) do
    case String.split(header, ",", parts: 2) do
      ["t=" <> _ts, "v1=" <> _ = v1] -> v1
      _ -> header
    end
  end

  defp strip_ts_prefix(header), do: header

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
      # Combined Stripe-style signature: the timestamp is embedded so the SDK
      # handler verifies + freshness-checks from one header (`t=<unix>,v1=<hex>`).
      # x-barkpark-timestamp is kept as a redundant convenience for non-SDK
      # consumers that read it directly.
      {"x-barkpark-signature", "t=#{timestamp},#{sig}"},
      {"x-barkpark-timestamp", Integer.to_string(timestamp)}
    ]

    headers =
      if event_id,
        do: [
          # x-barkpark-delivery-id is what the SDK handler dedups on; x-barkpark-event-id
          # is kept (same value) for back-compat with existing consumers.
          {"x-barkpark-delivery-id", Integer.to_string(event_id)},
          {"x-barkpark-event-id", Integer.to_string(event_id)} | base_headers
        ],
        else: base_headers

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

      # SSRF guard refusal is terminal — the target is a blocked internal host,
      # not a transient failure. Record the give-up reason; never retry.
      {:error, {:ssrf_blocked, ssrf_reason}} ->
        reason = "ssrf_blocked: #{inspect(ssrf_reason)}"
        if delivery, do: Webhooks.mark_giveup(delivery, nil, reason, n)
        Logger.warning("Webhook #{webhook.name} blocked by SSRF guard: #{reason}")
        {:error, :ssrf_blocked, n}

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

  @doc """
  Performs an HTTP POST through the swappable webhook adapter
  (`:webhook_http_adapter`, default `ReqAdapter`). Returns `{:ok, status}`
  or `{:error, reason}`.

  Exposed so media's outbound calls (lifecycle webhooks + CDN invalidation)
  route through the SAME seam as document webhooks — any policy applied there
  (timeouts, SSRF guard) then covers them too, instead of a bypassing
  `Req.post`.
  """
  def http_post(url, body, headers) do
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
      # Routed through the shared SSRF guard: it resolves + classifies the host,
      # refuses internal targets ({:error, {:ssrf_blocked, _}}), and forces
      # redirect: false so a 302-to-internal cannot smuggle the destination.
      case Barkpark.Net.SafeOutbound.post(url,
             body: body,
             headers: headers,
             receive_timeout: 10_000
           ) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
