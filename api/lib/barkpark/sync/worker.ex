defmodule Barkpark.Sync.Worker do
  @moduledoc """
  Long-lived puller GenServer for the one-way sync subsystem.

  Opens a STREAMING `Req.get` (`into: fn` — never buffered mode, which would
  never return for an endless SSE GET) to the remote
  `GET /v1/data/listen/:dataset`, resuming from the persisted cursor via
  `Last-Event-ID`. Each `{:data, chunk}` is forwarded to this process, appended
  to a `buf` accumulator that survives across chunks (SSE frames do NOT align
  to TCP/HTTP chunk boundaries), and drained through `Barkpark.Sync.apply_frames/2`.

  The streaming `Req.get` BLOCKS for the connection's lifetime, so it runs in a
  separate monitored process; on stream end/error this Worker schedules a
  reconnect with capped exponential backoff + jitter (floor 1s, cap 30s). The
  `:one_for_one` supervisor restarts the Worker on a crash; the in-process
  backoff handles connection recovery.

  `receive_timeout` is set ABOVE the producer's 30s keepalive interval so a
  half-open TCP connection (no FIN/RST) times out, ends the callback, and
  triggers a reconnect rather than hanging forever.

  Uses a DEDICATED Finch pool (`Barkpark.Sync.Finch`) so the endless stream
  connection cannot starve the webhook dispatcher's shared pool.
  """

  use GenServer

  require Logger

  alias Barkpark.Sync
  alias Barkpark.Sync.Cursor

  @finch Barkpark.Sync.Finch

  # Capped exponential backoff parameters.
  @floor_ms 1_000
  @cap_ms 30_000

  # Above the producer's 30s keepalive so a dead stream times out and reconnects.
  @receive_timeout 60_000

  # An unresolvable workspace is a CONFIG error, not a flaky link: re-probe on a
  # long fixed delay (self-heals once the workspace is created — no operator
  # action) instead of storming the connection at ~1Hz.
  @unresolved_backoff_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Capped exponential backoff with jitter for reconnect attempt `n` (0-based).
  Pure — extracted so reconnect timing is unit-testable without sleeps.
  """
  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    base = min(@cap_ms, @floor_ms * Integer.pow(2, min(attempt, 16)))
    base + :rand.uniform(div(base, 4) + 1)
  end

  @impl true
  def init(opts) do
    state = %{
      settings: Keyword.get(opts, :settings, Sync.config()),
      stream_fun: Keyword.get(opts, :stream_fun, &__MODULE__.stream/4),
      backoff_fun: Keyword.get(opts, :backoff_fun, &backoff_ms/1),
      unresolved_backoff_fun:
        Keyword.get(opts, :unresolved_backoff_fun, fn -> @unresolved_backoff_ms end),
      ctx: nil,
      buf: "",
      attempt: 0,
      stream: nil,
      connected_at: nil,
      last_event_at: nil,
      halted_reason: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, do_connect(state)}

  @impl true
  def handle_info(:connect, state), do: {:noreply, do_connect(state)}

  # Live chunk from the current stream.
  def handle_info({:sse_chunk, ref, chunk}, %{stream: %{ref: ref}} = state) do
    buf = state.buf <> chunk
    {results, rest} = Sync.apply_frames(buf, state.ctx)

    case first_error(results) do
      nil ->
        # Reset the backoff floor only when we actually APPLIED a real event —
        # not on welcome/keepalive/empty drains. Otherwise the producer's
        # per-reconnect `welcome` frame would reset `attempt` every cycle and a
        # persistently-failing event would reconnect-spin at the floor forever
        # instead of backing off to the cap.
        attempt = if applied_any?(results), do: 0, else: state.attempt
        {:noreply, %{state | buf: rest, attempt: attempt, last_event_at: now()}}

      {event_id, reason} ->
        # The drain halted at this event (see Sync.apply_frames). Tear the
        # stream down and reconnect: the cursor is still at the last success,
        # so the producer replays `id > cursor` from the failed event. Keep the
        # current `attempt` so a persistently-failing event backs off.
        Logger.warning(
          "[Sync] apply failed at event #{inspect(event_id)} (#{inspect(reason)}); " <>
            "halting drain, reconnecting from cursor " <>
            "#{Cursor.get(state.settings.source, state.settings.dataset)}"
        )

        {:noreply,
         state
         |> Map.put(:halted_reason, reason)
         |> stop_stream()
         |> schedule_reconnect(reason)}
    end
  end

  # Stale chunk from a previous stream — ignore.
  def handle_info({:sse_chunk, _ref, _chunk}, state), do: {:noreply, state}

  def handle_info({:sse_closed, ref, reason}, %{stream: %{ref: ref}} = state) do
    Logger.debug("[Sync] stream closed (#{inspect(reason)}); scheduling reconnect")
    {:noreply, schedule_reconnect(%{state | stream: nil})}
  end

  def handle_info({:sse_closed, _ref, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{stream: %{monitor: mref}} = state) do
    {:noreply, schedule_reconnect(%{state | stream: nil})}
  end

  def handle_info({:DOWN, _mref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ──────────────────────────────────────────────────────────────

  defp do_connect(state) do
    settings = state.settings
    ctx = Sync.context(settings)
    since = Cursor.get(settings.source, settings.dataset)

    parent = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> state.stream_fun.(parent, ref, settings, since) end)

    %{
      state
      | ctx: ctx,
        buf: "",
        stream: %{pid: pid, ref: ref, monitor: monitor},
        connected_at: now(),
        halted_reason: nil
    }
  end

  # An unresolved workspace is a config error: re-probe on the long fixed delay
  # WITHOUT bumping `attempt` (it is not a flaky link). `do_connect/1` re-runs
  # `Sync.context/1` each `:connect`, so the next re-probe self-heals once the
  # workspace resolves — no manual recovery seam needed.
  defp schedule_reconnect(state, :unresolved_workspace) do
    delay = state.unresolved_backoff_fun.()

    Logger.error(
      "[Sync] workspace unresolved — hard-backoff #{delay}ms before re-probe " <>
        "(NOT a ~1Hz storm). Fix BARKPARK_SYNC_WORKSPACE; the next re-probe self-heals once it resolves."
    )

    Process.send_after(self(), :connect, delay)
    # attempt is deliberately NOT bumped.
    %{state | buf: ""}
  end

  defp schedule_reconnect(state, _reason), do: schedule_reconnect(state)

  defp schedule_reconnect(state) do
    delay = state.backoff_fun.(state.attempt)
    Process.send_after(self(), :connect, delay)
    %{state | attempt: state.attempt + 1, buf: ""}
  end

  # Tear down the current stream child WITHOUT triggering its monitor/closed
  # path (we flush the monitor so no spurious {:DOWN}/reconnect double-fires).
  defp stop_stream(%{stream: %{pid: pid, monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
    %{state | stream: nil}
  end

  defp stop_stream(state), do: state

  # First `{:error, reason}` in a drain's results, as `{event_id, reason}`.
  defp first_error(results) do
    Enum.find_value(results, fn
      {event_id, {:error, reason}} -> {event_id, reason}
      _ -> nil
    end)
  end

  # True when a drain applied at least one real event (not just welcome /
  # keepalive / skipped) — the only signal that justifies resetting backoff.
  defp applied_any?(results) do
    Enum.any?(results, &match?({_id, {:ok, :applied}}, &1))
  end

  # Runs in a monitored child process: the streaming GET blocks here for the
  # connection's lifetime, forwarding each chunk to `parent` and reporting
  # closure when it returns/raises.
  @doc false
  def stream(parent, ref, settings, since) do
    headers =
      [{"accept", "text/event-stream"}, {"authorization", "Bearer #{settings.token}"}]
      |> maybe_last_event_id(since)

    reason =
      try do
        Req.get!(listen_url(settings),
          headers: headers,
          finch: @finch,
          receive_timeout: @receive_timeout,
          retry: false,
          into: fn {:data, data}, acc ->
            send(parent, {:sse_chunk, ref, data})
            {:cont, acc}
          end
        )

        :closed
      rescue
        e -> {:error, e}
      catch
        kind, e -> {kind, e}
      end

    send(parent, {:sse_closed, ref, reason})
  end

  defp listen_url(settings) do
    base = String.trim_trailing(settings.url, "/")
    "#{base}/v1/data/listen/#{settings.dataset}"
  end

  defp maybe_last_event_id(headers, since) when is_integer(since) and since > 0,
    do: [{"last-event-id", Integer.to_string(since)} | headers]

  defp maybe_last_event_id(headers, _since), do: headers

  defp now, do: System.monotonic_time(:millisecond)
end
