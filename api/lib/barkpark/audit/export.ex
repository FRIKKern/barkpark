defmodule Barkpark.Audit.Export do
  @moduledoc """
  Streams the append-only audit log to configured SIEM/webhook endpoints
  (`Barkpark.Audit.ExportSink`).

  **Cursor-based tail-shipping.** Each sink carries a `last_exported_id`
  high-water mark into `audit_events`; `flush/0` reads the events past it and
  POSTs them, advancing the cursor only on success. This decouples export from
  the emit path entirely (no per-mutation overhead, no in-transaction HTTP), and
  makes retry inherent — a failed flush simply doesn't advance the cursor, so
  the same events are re-attempted next tick.

  Delivery **reuses the webhook substrate**: the swappable HTTP adapter
  (`Barkpark.Webhooks.Dispatcher.http_post_resp/3`, SSRF-guarded via
  `SafeOutbound`), HMAC-SHA256 request signing
  (`Dispatcher.signature_headers/3`), and the consecutive-failure auto-disable
  discipline.

  ## Export schema (stable, documented)

  A flush POSTs a JSON body:

      {
        "source": "barkpark.audit",
        "format": "generic",
        "events": [
          {
            "id": 42,
            "category": "content_mutation",
            "action": "document.create",
            "subject": "<doc_id>",
            "actor": {"type": "user", "id": "<user_id>"},
            "workspace_id": "<uuid|null>",
            "occurred_at": "<iso8601>",
            "hash": "<sha256-hex>",
            "metadata": { ... }
          }
        ]
      }
  """
  import Ecto.Query, warn: false
  require Logger

  alias Barkpark.Repo
  alias Barkpark.Audit.{Event, ExportSink}
  alias Barkpark.Webhooks.Dispatcher

  @batch_size 500
  # Mirrors the webhook auto-disable streak threshold.
  @max_consecutive_failures 15

  # Half-open retry. An auto-disabled sink is NOT dead: after a cooldown it
  # rejoins the flush candidate set for one probe. Entry AND exit are both
  # automatic, so a transient receiver outage cannot permanently end a
  # customer's audit-trail ingestion. The cooldown grows with the streak past
  # the latch threshold (60s, 120s, 240s ... capped) so a receiver that is down
  # for a week is probed ~24x/day rather than 1440x/day.
  @retry_base_seconds 60
  @retry_max_seconds 3600
  # Bounds the exponent so `2 ** over` can never build a giant integer on a
  # sink whose streak ran into the thousands.
  @retry_max_doublings 8

  # Stable, greppable log codes for the two latch transitions. An operator
  # alerting on `audit_export_sink_auto_disabled` learns the SIEM went dark;
  # `audit_export_sink_recovered` closes the incident.
  @disabled_code "audit_export_sink_auto_disabled"
  @recovered_code "audit_export_sink_recovered"
  @probe_failed_code "audit_export_sink_probe_failed"

  # ── Sink config ──────────────────────────────────────────────────────────

  @doc "Create a SIEM export sink."
  @spec create_sink(map()) :: {:ok, ExportSink.t()} | {:error, Ecto.Changeset.t()}
  def create_sink(attrs) do
    %ExportSink{} |> ExportSink.changeset(attrs) |> Repo.insert()
  end

  @doc "List all sinks."
  @spec list_sinks() :: [ExportSink.t()]
  def list_sinks, do: Repo.all(from s in ExportSink, order_by: [asc: s.name])

  @doc "List active (non-disabled) sinks."
  @spec list_active_sinks() :: [ExportSink.t()]
  def list_active_sinks, do: Repo.all(from s in ExportSink, where: s.active == true)

  @doc """
  The sinks this tick should attempt: every active sink, PLUS every
  AUTO-disabled sink whose backoff cooldown has elapsed — a half-open probe.

  A sink that was disabled by a person (`active: false` with no
  `auto_disabled_at` stamp) is never probed: only the automatic latch has an
  automatic exit.
  """
  @spec list_flush_candidates(DateTime.t()) :: [ExportSink.t()]
  def list_flush_candidates(now \\ DateTime.utc_now()) do
    # SQL prefilters on the SHORTEST possible cooldown; the exact per-row
    # cooldown depends on that row's streak, so it is refined in Elixir over
    # the (small) disabled set rather than encoded as a SQL expression.
    earliest = DateTime.add(now, -@retry_base_seconds, :second)

    from(s in ExportSink,
      where:
        s.active == true or
          (not is_nil(s.auto_disabled_at) and s.auto_disabled_at <= ^earliest),
      order_by: [asc: s.name]
    )
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
  end

  @doc """
  Re-enable a disabled sink directly and restore it to a clean shippable state:
  `active: true`, `consecutive_failures: 0`, and the `auto_disabled_at` /
  `disable_reason` stamps cleared. Mirrors `Barkpark.Webhooks.reenable_webhook/1`.

  Idempotent for an already-active sink (it also clears an in-progress streak).
  This is the MANUAL exit; the automatic one is `list_flush_candidates/1`.
  """
  @spec reenable_sink(ExportSink.t()) :: {:ok, ExportSink.t()} | {:error, Ecto.Changeset.t()}
  def reenable_sink(%ExportSink{} = sink) do
    sink
    |> Ecto.Changeset.change(%{
      active: true,
      consecutive_failures: 0,
      auto_disabled_at: nil,
      disable_reason: nil
    })
    |> Repo.update()
  end

  @doc """
  Person-facing health of every sink — the queryable surface that makes a dark
  SIEM VISIBLE instead of silent. `:dark_for_seconds` is how long this sink has
  been shipping nothing; `:next_retry_at` is when the half-open probe fires.
  """
  @spec sink_health(DateTime.t()) :: [map()]
  def sink_health(now \\ DateTime.utc_now()) do
    Enum.map(list_sinks(), fn sink ->
      %{
        id: sink.id,
        name: sink.name,
        workspace_id: sink.workspace_id,
        status: status(sink),
        consecutive_failures: sink.consecutive_failures,
        auto_disabled_at: sink.auto_disabled_at,
        disable_reason: sink.disable_reason,
        next_retry_at: next_retry_at(sink),
        dark_for_seconds: dark_for_seconds(sink, now)
      }
    end)
  end

  defp status(%ExportSink{active: false, auto_disabled_at: nil}), do: :disabled
  defp status(%ExportSink{active: false}), do: :auto_disabled
  defp status(%ExportSink{consecutive_failures: n}) when n > 0, do: :degraded
  defp status(%ExportSink{}), do: :healthy

  defp next_retry_at(%ExportSink{active: true}), do: nil
  defp next_retry_at(%ExportSink{auto_disabled_at: nil}), do: nil

  defp next_retry_at(%ExportSink{} = sink),
    do: DateTime.add(sink.auto_disabled_at, cooldown_seconds(sink.consecutive_failures), :second)

  defp dark_for_seconds(%ExportSink{auto_disabled_at: nil}, _now), do: nil
  defp dark_for_seconds(%ExportSink{active: true}, _now), do: nil

  defp dark_for_seconds(%ExportSink{auto_disabled_at: at}, now),
    do: DateTime.diff(now, at, :second)

  defp due?(%ExportSink{active: true}, _now), do: true
  defp due?(%ExportSink{auto_disabled_at: nil}, _now), do: false

  defp due?(%ExportSink{} = sink, now) do
    DateTime.compare(next_retry_at(sink), now) != :gt
  end

  # 60s, 120s, 240s ... capped at @retry_max_seconds, keyed off how far the
  # streak has run PAST the latch threshold (i.e. how many probes have failed).
  defp cooldown_seconds(failures) do
    doublings =
      failures |> Kernel.-(@max_consecutive_failures) |> max(0) |> min(@retry_max_doublings)

    min(@retry_base_seconds * Integer.pow(2, doublings), @retry_max_seconds)
  end

  # ── Flush ──────────────────────────────────────────────────────────────

  @doc """
  Flush every candidate sink (active sinks plus auto-disabled sinks whose
  cooldown elapsed). Returns the per-sink results.
  """
  @spec flush() :: [term()]
  def flush, do: Enum.map(list_flush_candidates(), &flush_sink/1)

  @doc """
  Ship the events past this sink's cursor. Advances the cursor (and resets the
  failure streak) on success; on a delivery failure records the failure (and
  auto-disables at the threshold) WITHOUT advancing, so the batch retries.
  """
  @spec flush_sink(ExportSink.t()) :: {:ok, term()} | {:error, term()}
  def flush_sink(%ExportSink{} = sink) do
    batch =
      Repo.all(
        from e in Event,
          where: e.id > ^sink.last_exported_id,
          order_by: [asc: e.id],
          limit: @batch_size
      )

    case batch do
      [] ->
        {:ok, :nothing_new}

      events ->
        max_id = events |> List.last() |> Map.fetch!(:id)
        to_ship = filter_for_sink(events, sink)

        case deliver(sink, to_ship) do
          :ok ->
            advance(sink, max_id)
            {:ok, {:shipped, length(to_ship)}}

          {:error, reason} ->
            record_failure(sink, reason)
            {:error, reason}
        end
    end
  end

  # A global sink (nil workspace) ships every event; a scoped sink only its own.
  defp filter_for_sink(events, %ExportSink{workspace_id: nil}), do: events

  defp filter_for_sink(events, %ExportSink{workspace_id: ws}),
    do: Enum.filter(events, &(&1.workspace_id == ws))

  # ── Delivery (reuses the webhook adapter + HMAC) ──────────────────────────

  # Nothing matched this sink in the batch — advance the cursor, no HTTP.
  defp deliver(_sink, []), do: :ok

  defp deliver(%ExportSink{} = sink, events) do
    body =
      Jason.encode!(%{
        source: "barkpark.audit",
        format: sink.format,
        events: Enum.map(events, &format_event(&1, sink.format))
      })

    timestamp = System.system_time(:second)

    headers =
      [{"content-type", "application/json"} | signature_headers(sink.secret, body, timestamp)]

    case Dispatcher.http_post_resp(sink.url, body, headers) do
      {:ok, status, _resp} when status in 200..299 -> :ok
      {:ok, status, _resp} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signature_headers(nil, _body, _ts), do: []
  defp signature_headers("", _body, _ts), do: []
  defp signature_headers(secret, body, ts), do: Dispatcher.signature_headers(body, ts, secret)

  @doc "Render one audit event to the stable export shape."
  @spec format_event(Event.t(), String.t()) :: map()
  def format_event(%Event{} = e, _format) do
    %{
      id: e.id,
      category: e.category,
      action: e.action,
      subject: e.subject,
      actor: %{type: e.actor_type, id: e.actor_id},
      workspace_id: e.workspace_id,
      occurred_at: e.occurred_at,
      hash: e.hash,
      metadata: e.metadata
    }
  end

  # ── Cursor + auto-disable ────────────────────────────────────────────────

  # A successful ship CLEARS the latch as well as advancing the cursor: if this
  # was a half-open probe, the sink is live again with a clean streak. This is
  # the automatic EXIT that the auto-disable previously had none of.
  defp advance(%ExportSink{} = sink, max_id) do
    now = DateTime.utc_now()

    # Returns the row count rather than a bare `:ok`: a sink deleted mid-flush
    # updates 0 rows, and destroying that outcome one frame below the caller
    # would make the miss unreportable (pds-bl-sentinel-ok-returner-population).
    {updated, _} =
      from(s in ExportSink, where: s.id == ^sink.id)
      |> Repo.update_all(
        set: [
          consecutive_failures: 0,
          last_exported_id: max_id,
          active: true,
          auto_disabled_at: nil,
          disable_reason: nil,
          updated_at: now
        ]
      )

    if not sink.active do
      Logger.warning(
        "[#{@recovered_code}] audit export sink #{sink.id} (#{sink.name}) recovered " <>
          "after #{dark_for_seconds(sink, now)}s disabled; shipping resumed"
      )
    end

    {:ok, updated}
  end

  # Atomic increment (single UPDATE ... RETURNING) so concurrent flushes of the
  # same sink cannot lose a count the way `sink.consecutive_failures + 1` did.
  defp record_failure(%ExportSink{} = sink, reason) do
    {_, rows} =
      from(s in ExportSink, where: s.id == ^sink.id, select: s.consecutive_failures)
      |> Repo.update_all(inc: [consecutive_failures: 1])

    case rows do
      [count] when is_integer(count) ->
        if count >= @max_consecutive_failures, do: latch(sink, count, reason)
        {:ok, count}

      _ ->
        # Row is gone (sink deleted mid-flight) — nothing to count against.
        {:ok, 0}
    end
  end

  # Flip the sink inactive and stamp the latch metadata. The `active == true`
  # guard makes the FIRST crossing the only one that logs: a later failure (a
  # half-open probe that failed again) matches zero rows here and falls through
  # to `restart_cooldown/3`, so the operator gets ONE line per dark interval,
  # not one per failed tick.
  defp latch(%ExportSink{} = sink, count, reason) do
    now = DateTime.utc_now()
    detail = build_disable_reason(count, reason)

    {flipped, _} =
      from(s in ExportSink, where: s.id == ^sink.id and s.active == true)
      |> Repo.update_all(
        set: [active: false, auto_disabled_at: now, disable_reason: detail, updated_at: now]
      )

    if flipped == 1 do
      Logger.error(
        "[#{@disabled_code}] audit export sink #{sink.id} (#{sink.name}) auto-disabled: " <>
          "#{detail}. Audit events are NOT reaching this SIEM. A half-open probe retries " <>
          "in #{cooldown_seconds(count)}s; Barkpark.Audit.Export.sink_health/1 reports status."
      )

      {:ok, :latched}
    else
      restart_cooldown(sink, count, detail, now)
    end
  end

  # The half-open probe failed. Push `auto_disabled_at` forward so the NEXT
  # probe waits out a longer cooldown — without this the stamp stays old, every
  # tick reads as due, and the "backoff" would retry once a minute forever.
  defp restart_cooldown(%ExportSink{} = sink, count, detail, now) do
    {restamped, _} =
      from(s in ExportSink, where: s.id == ^sink.id and s.active == false)
      |> Repo.update_all(set: [auto_disabled_at: now, disable_reason: detail, updated_at: now])

    Logger.info(
      "[#{@probe_failed_code}] audit export sink #{sink.id} (#{sink.name}) probe failed; " <>
        "next retry in #{cooldown_seconds(count)}s"
    )

    {:ok, restamped}
  end

  # Bounded so a long transport error can't overflow the `disable_reason` column.
  defp build_disable_reason(count, reason) do
    detail = reason |> inspect() |> String.slice(0, 180)
    "auto-disabled after #{count} consecutive failures: #{detail}"
  end
end
