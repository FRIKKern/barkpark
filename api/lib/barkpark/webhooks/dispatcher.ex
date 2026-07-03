defmodule Barkpark.Webhooks.Dispatcher do
  @moduledoc """
  Delivers webhook payloads with HMAC signing, retries, and per-event dedup.

  Wire format (Stripe-inspired):

    X-Barkpark-Timestamp: <unix-seconds>
    X-Barkpark-Signature: v1=<hex HMAC-SHA256(secret, "timestamp.body")>
    X-Barkpark-Event-ID:  <mutation_events.id>

  Retries follow a JITTERED backoff (base `[1s, 5s, 30s]`, equal-jitter around
  each tier, ceiling-bounded so a spike of queued deliveries doesn't re-align on
  the same wall-clock offsets and stampede a recovering endpoint) with
  `@max_attempts` attempts total on 5xx, transport error, or a RETRYABLE 4xx
  (`408`, `425`, `429`) — honoring a `Retry-After` header (seconds or HTTP-date,
  clamped to a sane max) as the next delay when present. Every OTHER 4xx
  (`400/401/403/404/410/422`, …) stays terminal (no retry).
  Delivery is deduped via UNIQUE(endpoint_id, event_id) in `webhook_deliveries`.

  ## Retries are SCHEDULED, not slept in-task

  A retryable failure on the dedup path does NOT `Process.sleep` inside the
  bounded `WebhookDeliverySupervisor` async_stream task. That would park one of
  `webhook_delivery_concurrency` (default 100) slots for the whole backoff, so a
  retry storm saturated the pool with SLEEPING tasks and head-of-line-blocked
  deliveries to healthy endpoints. Instead the delivery task persists its
  next-attempt intent (`Webhooks.schedule_retry/3`) + enqueues a scheduled
  one-shot `Webhooks.RetryWorker` job `delay` out, then RETURNS — freeing the
  slot immediately. The scheduled job resumes the SAME durable row via
  `redeliver/5`, fenced on `updated_at` so it can never double-fire with the
  `StuckDeliverySweeper`. The dedup-LESS back-compat path (no row to resume from)
  keeps the in-task sleep.
  """

  require Logger
  alias Barkpark.Webhooks
  alias Barkpark.Tenancy

  @default_retry_delays_ms [1_000, 5_000, 30_000]
  @default_max_attempts 3

  # 4xx statuses that are TRANSIENT and should be retried rather than dropped:
  # 429 Too Many Requests, 408 Request Timeout, 425 Too Early. Dropping these
  # loses a cache-revalidation / lifecycle event forever. Every OTHER 4xx is a
  # genuine, permanent client error and stays terminal.
  @retryable_4xx [408, 425, 429]

  # Upper bounds (ms), both overridable via app env. `@retry_after_max_ms`
  # clamps a server-supplied `Retry-After` so a hostile/absurd value can't park
  # a delivery for hours; `@jitter_ceiling_ms` caps a jittered table delay so
  # jitter can widen a tier but never blow past a sane maximum.
  @retry_after_max_ms 300_000
  @jitter_ceiling_ms 60_000

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
  Delivery with retries and dedup. Used by `dispatch_async/6` and directly in
  tests. The FIRST attempt runs synchronously; a retry is SCHEDULED (not slept
  in-task), so the call returns as soon as the first attempt settles. Returns:

    * `{:ok, status, attempts}` — delivered on the first attempt;
    * `{:error, reason, attempts}` — terminal on the first attempt (permanent
      4xx, SSRF block, or exhaustion when `max_attempts` is 1);
    * `{:scheduled, delivery_id, next_attempt}` — first attempt failed retryably;
      a scheduled `RetryWorker` job now owns the remaining attempts;
    * `{:superseded, delivery_id}` — a concurrent writer (crash-sweep) claimed the
      row before the retry could be scheduled;
    * `{:skipped, :already_delivered}` — the (endpoint, event) pair is already
      recorded.
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
      when is_integer(event_id) or is_nil(event_id) do
    attempt(webhook, body, event_id, delivery, 1)
  end

  @doc """
  Resume delivery for an existing claimed row at a SPECIFIC attempt number — the
  scheduled-retry entry point used by `Barkpark.Webhooks.RetryWorker`.

  Same durable resume as `redeliver/4` (re-uses the row, writes the terminal
  status) but picks up at `attempt_n` instead of restarting at 1, so the
  `max_attempts` bound is honoured across scheduled retry hops rather than being
  reset on each hop.
  """
  def redeliver(webhook, body, event_id, %Barkpark.Webhooks.Delivery{} = delivery, attempt_n)
      when (is_integer(event_id) or is_nil(event_id)) and is_integer(attempt_n) and
             attempt_n >= 1 do
    attempt(webhook, body, event_id, delivery, attempt_n)
  end

  @doc """
  First-attempt entry point for a MEDIA lifecycle delivery, converged onto the
  SAME durable-row state machine as document webhooks.

  `delivery` is a freshly-inserted `source_kind: "media"` row (see
  `Webhooks.create_media_delivery/1`); `webhook` is a TRANSIENT (unpersisted)
  `%Webhook{}` carrying the config endpoint's url/secret (id nil — so the terminal
  `mark_*` writes count against no `webhooks` row, correct for a config endpoint).
  Runs the first signed attempt synchronously in the calling
  `WebhookDeliverySupervisor` slot, then — exactly like a document delivery — on a
  retryable failure SCHEDULES the next attempt (`schedule_retry` → `RetryWorker`)
  and RETURNS, freeing the slot instead of parking it in `Process.sleep` (the old
  head-of-line-blocking twin). `event_id` is nil (media has no `mutation_events`
  row); the delivery-id headers are simply omitted, matching the media wire
  format. Same return contract as `deliver/3`.
  """
  def deliver_media(webhook, body, %Barkpark.Webhooks.Delivery{} = delivery) do
    attempt(webhook, body, nil, delivery, 1)
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
      {:ok, status, _resp_headers} when status in 200..299 ->
        Webhooks.mark_delivered(delivery, status, n, latency_ms)

      {:ok, status, _resp_headers} ->
        Webhooks.mark_giveup(delivery, status, "http #{status}", n, latency_ms)

      {:error, {:ssrf_blocked, ssrf_reason}} ->
        Webhooks.mark_giveup(
          delivery,
          nil,
          "ssrf_blocked: #{inspect(ssrf_reason)}",
          n,
          latency_ms
        )

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
  # how long the endpoint took to respond (or fail). Times the header-returning
  # sibling so the retry loop can still honor Retry-After.
  defp timed_post(url, body, headers) do
    {elapsed_us, result} = :timer.tc(fn -> http_post_resp(url, body, headers) end)
    {System.convert_time_unit(elapsed_us, :microsecond, :millisecond), result}
  end

  defp attempt(webhook, body, event_id, delivery, n) do
    {_timestamp, headers} = build_request(webhook, body, event_id)
    {latency_ms, result} = timed_post(webhook.url, body, headers)

    case result do
      {:ok, status, _resp_headers} when status in 200..299 ->
        if delivery, do: Webhooks.mark_delivered(delivery, status, n, latency_ms)
        Logger.info("Webhook #{webhook.name} delivered (#{status}) on attempt #{n}")
        {:ok, status, n}

      # Transient 4xx (429/408/425): retry instead of dropping the delivery.
      # Honor a `Retry-After` header (clamped) as the next delay when present.
      {:ok, status, resp_headers} when status in @retryable_4xx ->
        maybe_retry(
          webhook,
          body,
          event_id,
          delivery,
          n,
          status,
          "http #{status}",
          latency_ms,
          parse_retry_after(resp_headers)
        )

      {:ok, status, _resp_headers} when status in 400..499 ->
        reason = "http #{status}"
        if delivery, do: Webhooks.mark_giveup(delivery, status, reason, n, latency_ms)
        Logger.warning("Webhook #{webhook.name} gave up: 4xx (#{status})")
        {:error, :giveup_4xx, n}

      {:ok, status, _resp_headers} ->
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

  # `override_delay_ms` (when non-nil) is a server-directed `Retry-After` — honor
  # it verbatim (already clamped). Otherwise use the jittered backoff tier so a
  # burst of retries de-synchronizes instead of stampeding in lockstep.
  # `last_latency_ms` rides along so a terminal give-up records how long the
  # final attempt took (C5 delivery-log truth).
  defp maybe_retry(
         webhook,
         body,
         event_id,
         delivery,
         n,
         last_status,
         reason_text,
         last_latency_ms,
         override_delay_ms \\ nil
       ) do
    if n < max_attempts() do
      reschedule_retry(webhook, body, event_id, delivery, n, retry_delay(n, override_delay_ms))
    else
      if delivery,
        do: Webhooks.mark_giveup(delivery, last_status, reason_text, n, last_latency_ms)

      Logger.warning("Webhook #{webhook.name} gave up after #{n} attempts: #{reason_text}")
      {:error, :exhausted, n}
    end
  end

  # `override_delay_ms` (non-nil) is a server-directed `Retry-After` — honor it
  # verbatim (already clamped). Otherwise use the jittered backoff tier so a burst
  # of retries de-synchronizes instead of stampeding in lockstep.
  defp retry_delay(_n, override_delay_ms) when is_integer(override_delay_ms),
    do: override_delay_ms

  defp retry_delay(n, nil) do
    base = Enum.at(retry_delays(), n - 1) || List.last(retry_delays())
    jittered_delay(base, jitter_ceiling_ms())
  end

  # Dedup path (a durable `webhook_deliveries` row exists): SCHEDULE the next
  # attempt and return so the bounded async_stream slot is freed NOW instead of
  # being parked in `Process.sleep` for the backoff window. The scheduled job
  # resumes the same row (fenced on updated_at) via redeliver/5.
  defp reschedule_retry(
         webhook,
         body,
         event_id,
         %Barkpark.Webhooks.Delivery{} = delivery,
         n,
         delay
       ) do
    case Webhooks.schedule_retry(delivery, n, delay) do
      {:ok, _job} ->
        {:scheduled, delivery.id, n + 1}

      {:error, :superseded} ->
        # A crash-sweep claimed the row between our attempt and the fence CAS —
        # it now owns the retry. Yield without double-scheduling.
        {:superseded, delivery.id}

      {:error, reason} ->
        # Enqueue failed (Oban/DB hiccup). Don't strand the delivery: fall back
        # to the in-task retry so it still reaches a terminal state. Rare path.
        Logger.warning(
          "Webhook #{webhook.name} retry enqueue failed " <>
            "(#{inspect(reason)}); falling back to in-task retry"
        )

        Process.sleep(delay)
        attempt(webhook, body, event_id, delivery, n + 1)
    end
  end

  # Dedup-LESS back-compat path (no durable row a scheduled job could rebuild the
  # delivery from): keep the in-task sleep. Legacy callers only.
  defp reschedule_retry(webhook, body, event_id, nil, n, delay) do
    Process.sleep(delay)
    attempt(webhook, body, event_id, nil, n + 1)
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
    case http_post_resp(url, body, headers) do
      {:ok, status, _resp_headers} -> {:ok, status}
      {:error, _} = err -> err
    end
  end

  @doc """
  Header-returning sibling of `http_post/3`: `{:ok, status, resp_headers}` /
  `{:error, reason}`. Used by the retry loop (here and in media's delivery
  mirror) so a `Retry-After` on a 429/408/425 can drive the next delay.

  Normalizes the swappable adapter's return: a legacy `{:ok, status}` (the test
  fake / any 2-tuple adapter) is widened to `{:ok, status, []}`, so both wire
  forms are accepted.
  """
  def http_post_resp(url, body, headers) do
    adapter = Application.get_env(:barkpark, :webhook_http_adapter, __MODULE__.ReqAdapter)

    case adapter.post(url, body, headers) do
      {:ok, status, resp_headers} -> {:ok, status, resp_headers}
      {:ok, status} -> {:ok, status, []}
      {:error, _} = err -> err
      other -> other
    end
  end

  @doc """
  `true` for the 4xx statuses that are TRANSIENT and worth retrying
  (`408`, `425`, `429`). Single source of truth shared by media's delivery
  mirror so both delivery paths classify give-up-vs-retry identically.
  """
  def retryable_4xx?(status) when is_integer(status), do: status in @retryable_4xx

  @doc """
  Parses a `Retry-After` header into a clamped delay in **milliseconds**, or
  `nil` when absent/unparseable. Accepts both forms per RFC 9110: an integer
  number of seconds, or an HTTP-date (the delay is then `date - now`, floored at
  0). The result is clamped to `@retry_after_max_ms` so a hostile/absurd value
  can't park a delivery for hours. `headers` is a list of `{name, value}` (value
  may itself be a `[binary]` list, as Req returns); lookup is case-insensitive.
  """
  def parse_retry_after(headers, now \\ System.system_time(:second)) when is_list(headers) do
    case find_header(headers, "retry-after") do
      nil ->
        nil

      raw ->
        case retry_after_seconds(String.trim(raw), now) do
          nil -> nil
          secs -> min(secs * 1000, retry_after_max_ms())
        end
    end
  end

  # Integer seconds (floored at 0), else an HTTP-date resolved against `now`.
  defp retry_after_seconds(value, now) do
    case Integer.parse(value) do
      {n, ""} -> max(n, 0)
      _ -> retry_after_from_date(value, now)
    end
  end

  defp retry_after_from_date(value, now) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_y, _mo, _d}, {_h, _mi, _s}} = datetime ->
        epoch = :calendar.datetime_to_gregorian_seconds(datetime) - 62_167_219_200
        max(epoch - now, 0)

      _ ->
        nil
    end
  end

  defp find_header(headers, name) do
    target = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == target, do: header_value(v), else: nil
      _ -> nil
    end)
  end

  defp header_value([v | _]), do: to_string(v)
  defp header_value(v) when is_binary(v), do: v
  defp header_value(v), do: to_string(v)

  @doc """
  Equal-jitter around `base_ms`: a uniformly random delay in
  `[base_ms/2, base_ms*1.5]`, clamped to `ceiling_ms`. The `base_ms/2` floor
  keeps it from collapsing toward 0 (no busy-spin) while the spread
  de-synchronizes a burst of retries so they don't stampede a recovering
  endpoint in lockstep. Shared with media's delivery mirror.
  """
  def jittered_delay(base_ms, ceiling_ms)
      when is_integer(base_ms) and base_ms >= 0 and is_integer(ceiling_ms) and ceiling_ms >= 0 do
    half = div(base_ms, 2)
    # :rand.uniform(base_ms + 1) → 1..base_ms+1; minus 1 → 0..base_ms.
    spread = :rand.uniform(base_ms + 1) - 1
    min(half + spread, ceiling_ms)
  end

  defp retry_delays do
    Application.get_env(:barkpark, :webhook_retry_delays_ms, @default_retry_delays_ms)
  end

  defp max_attempts do
    Application.get_env(:barkpark, :webhook_max_attempts, @default_max_attempts)
  end

  defp retry_after_max_ms do
    Application.get_env(:barkpark, :webhook_retry_after_max_ms, @retry_after_max_ms)
  end

  def jitter_ceiling_ms do
    Application.get_env(:barkpark, :webhook_retry_ceiling_ms, @jitter_ceiling_ms)
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
        {:ok, %{status: status} = resp} -> {:ok, status, Map.to_list(resp.headers || %{})}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
