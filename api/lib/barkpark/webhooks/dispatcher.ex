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

  # Replay-defense window for `verify_signature/5`: an inbound signature whose
  # signed timestamp is more than this many seconds from local "now" (either
  # direction) is rejected. Kept byte-for-byte in sync with the JS twin's
  # default (`toleranceSeconds ?? 300`, `js/packages/core/src/webhook.ts`).
  @signature_tolerance_seconds 300

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
  Verifies an inbound webhook signature against the list of currently-effective
  secrets (primary + unexpired previous), rejecting stale deliveries so a
  captured request cannot be replayed. Constant-time comparison.

  Mirrors the JS twin — `@barkpark/core`'s `verifyWebhookSignature`
  (`js/packages/core/src/webhook.ts`) — byte-for-byte:

    * signed material is `"<timestamp>.<body>"`, HMAC-SHA256, lower-hex `v1=`
      (via `sign_payload/3`);
    * freshness: reject unless the SIGNED `timestamp` is within
      `@signature_tolerance_seconds` (#{@signature_tolerance_seconds}s, ±5 min)
      of `now` — the twin's `Math.abs(now - t) > tolerance` gate;
    * compare is constant-time (`Plug.Crypto.secure_compare/2`);
    * any/all effective secrets may match (secret-rotation window).

  `timestamp` MUST be the timestamp the signature commits to — the `t=` in the
  `x-barkpark-signature` header (or the redundant `x-barkpark-timestamp`).
  Because that value is bound into the HMAC, an attacker cannot forge a fresh
  one without the secret; as a fail-closed cross-check, when the header carries
  its own `t=<unix>` it must equal `timestamp` or verification returns `false`.
  `now` defaults to wall-clock unix seconds and is injectable for deterministic
  tests. Malformed/blank signatures return `false` (never raise).

  NOTE: currently CALLER-LESS — Barkpark does not yet verify inbound webhooks
  anywhere in the tree (`grep` confirms only tests call it). It exists so a
  future epic (e.g. the tickets/console inbound-hook work) inherits this SAFE,
  replay-checked version rather than wiring a freshness-blind one. If either
  side changes, keep it in parity with the JS twin cited above (there is a
  cross-twin parity test in `dispatcher_test.exs`).
  """
  def verify_signature(
        body,
        timestamp,
        signature_header,
        secrets,
        now \\ System.system_time(:second)
      )

  def verify_signature(body, timestamp, signature_header, secrets, now)
      when is_list(secrets) and is_integer(timestamp) and is_integer(now) do
    {header_t, sig} = parse_signature(signature_header)

    fresh? = abs(now - timestamp) <= @signature_tolerance_seconds
    header_consistent? = is_nil(header_t) or header_t == timestamp

    fresh? and header_consistent? and
      Enum.any?(secrets, fn s ->
        expected = sign_payload(body, timestamp, s)
        Plug.Crypto.secure_compare(expected, sig)
      end)
  end

  # Split an incoming signature header into `{signed_timestamp | nil, "v1=<hex>"}`.
  # Accepts both the raw `v1=<hex>` form (returns `{nil, header}`) and the
  # combined `t=<unix>,v1=<hex>` form the dispatcher emits (returns the parsed
  # unix `t`, so the caller-supplied `timestamp` can be cross-checked against it).
  defp parse_signature(header) when is_binary(header) do
    case String.split(header, ",", parts: 2) do
      ["t=" <> ts, "v1=" <> _ = v1] ->
        case Integer.parse(ts) do
          {t, ""} -> {t, v1}
          # A non-integer `t=` is treated as absent: freshness still gates on
          # the caller's `timestamp`, and the HMAC over that value must match.
          _ -> {nil, v1}
        end

      _ ->
        {nil, header}
    end
  end

  defp parse_signature(header), do: {nil, header}

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

  @doc """
  Re-run delivery for an EXISTING, already-claimed `webhook_deliveries` row —
  the crash-recovery entry point used by `Webhooks.StuckDeliverySweeper`.

  Unlike `deliver/3` this does NOT call `claim_delivery/2`: the row already
  exists (it was claimed before the dispatcher that owned it crashed), so we
  resume straight into the signed HTTP attempt loop against the SAME row. The
  terminal `mark_delivered/3` / `mark_giveup/4` write flips it out of `pending`,
  so a recovered delivery reaches a terminal state exactly like a first-time one.
  Re-using the row (never re-inserting) is what keeps the
  UNIQUE(endpoint_id, event_id) invariant intact.
  """
  def redeliver(webhook, body, event_id, %Barkpark.Webhooks.Delivery{} = delivery)
      when is_integer(event_id) do
    attempt(webhook, body, event_id, delivery, 1)
  end

  defp deliver_without_dedup(webhook, body) do
    attempt(webhook, body, nil, nil, 1)
  end

  @doc """
  Replay a single delivery against an existing (or freshly-claimed) delivery
  row: ONE synchronous attempt, no retry loop, `attempts` bumped by one and
  `status`/`last_status_code`/`last_latency_ms`/`last_error_text` overwritten
  with this attempt's verdict. Used by the operator-console replay route to
  re-send a stored event to THIS webhook. Returns `{:ok, delivery}` with the
  refreshed row so the caller can report the verdict.
  """
  def replay_delivery(webhook, body, event_id) when is_integer(event_id) do
    delivery =
      case Webhooks.get_delivery(webhook.id, event_id) do
        nil ->
          case Webhooks.claim_delivery(webhook.id, event_id) do
            {:ok, d} -> d
            # A concurrent claim beat us to the row (negligible for a synchronous
            # admin replay, but never crash on the race) — re-fetch and reuse it.
            {:error, :already_delivered} -> Webhooks.get_delivery(webhook.id, event_id)
          end

        d ->
          d
      end

    {_timestamp, headers} = build_request(webhook, body, event_id)
    {latency_ms, result} = timed_post(webhook.url, body, headers)
    n = delivery.attempts + 1

    case result do
      {:ok, status} when status in 200..299 ->
        Webhooks.mark_delivered(delivery, status, n, latency_ms)

      {:ok, status} ->
        Webhooks.mark_giveup(delivery, status, "http #{status}", n, latency_ms)

      {:error, {:ssrf_blocked, ssrf_reason}} ->
        Webhooks.mark_giveup(delivery, nil, "ssrf_blocked: #{inspect(ssrf_reason)}", n, latency_ms)

      {:error, reason} ->
        Webhooks.mark_giveup(delivery, nil, inspect(reason), n, latency_ms)
    end
  end

  # Build the signed request headers for a delivery attempt. Returns
  # `{timestamp, headers}` so the timestamp embedded in the signature is
  # available to callers that need it.
  defp build_request(webhook, body, event_id) do
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

    {timestamp, headers}
  end

  # Time the HTTP POST in wall-clock milliseconds so each delivery row records
  # how long the endpoint took to respond (or fail).
  defp timed_post(url, body, headers) do
    {elapsed_us, result} = :timer.tc(fn -> http_post(url, body, headers) end)
    {System.convert_time_unit(elapsed_us, :microsecond, :millisecond), result}
  end

  defp attempt(webhook, body, event_id, delivery, n) do
    {_timestamp, headers} = build_request(webhook, body, event_id)
    {latency_ms, result} = timed_post(webhook.url, body, headers)

    case result do
      {:ok, status} when status in 200..299 ->
        if delivery, do: Webhooks.mark_delivered(delivery, status, n, latency_ms)
        Logger.info("Webhook #{webhook.name} delivered (#{status}) on attempt #{n}")
        {:ok, status, n}

      {:ok, status} when status in 400..499 ->
        reason = "http #{status}"
        if delivery, do: Webhooks.mark_giveup(delivery, status, reason, n, latency_ms)
        Logger.warning("Webhook #{webhook.name} gave up: 4xx (#{status})")
        {:error, :giveup_4xx, n}

      {:ok, status} ->
        maybe_retry(webhook, body, event_id, delivery, n, status, "http #{status}", latency_ms)

      # SSRF guard refusal is terminal — the target is a blocked internal host,
      # not a transient failure. Record the give-up reason; never retry.
      {:error, {:ssrf_blocked, ssrf_reason}} ->
        reason = "ssrf_blocked: #{inspect(ssrf_reason)}"
        if delivery, do: Webhooks.mark_giveup(delivery, nil, reason, n, latency_ms)
        Logger.warning("Webhook #{webhook.name} blocked by SSRF guard: #{reason}")
        {:error, :ssrf_blocked, n}

      {:error, reason} ->
        maybe_retry(webhook, body, event_id, delivery, n, nil, inspect(reason), latency_ms)
    end
  end

  defp maybe_retry(webhook, body, event_id, delivery, n, last_status, reason_text, last_latency_ms) do
    if n < max_attempts() do
      delay = Enum.at(retry_delays(), n - 1) || List.last(retry_delays())
      Process.sleep(delay)
      attempt(webhook, body, event_id, delivery, n + 1)
    else
      if delivery, do: Webhooks.mark_giveup(delivery, last_status, reason_text, n, last_latency_ms)
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
