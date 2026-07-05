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

  alias Barkpark.Repo
  alias Barkpark.Audit.{Event, ExportSink}
  alias Barkpark.Webhooks.Dispatcher

  @batch_size 500
  # Mirrors the webhook auto-disable streak threshold.
  @max_consecutive_failures 15

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

  # ── Flush ──────────────────────────────────────────────────────────────

  @doc "Flush every active sink. Returns the per-sink results."
  @spec flush() :: [term()]
  def flush, do: Enum.map(list_active_sinks(), &flush_sink/1)

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

  defp advance(%ExportSink{id: id}, max_id) do
    from(s in ExportSink, where: s.id == ^id)
    |> Repo.update_all(set: [consecutive_failures: 0, last_exported_id: max_id])
  end

  defp record_failure(%ExportSink{} = sink, reason) do
    failures = sink.consecutive_failures + 1

    if failures >= @max_consecutive_failures do
      from(s in ExportSink, where: s.id == ^sink.id)
      |> Repo.update_all(
        set: [
          consecutive_failures: failures,
          active: false,
          auto_disabled_at: DateTime.utc_now(),
          disable_reason:
            "auto-disabled after #{failures} consecutive failures: #{inspect(reason)}"
        ]
      )
    else
      from(s in ExportSink, where: s.id == ^sink.id)
      |> Repo.update_all(set: [consecutive_failures: failures])
    end
  end
end
