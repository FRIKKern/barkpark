defmodule Barkpark.Sync.PushWorker do
  @moduledoc """
  Drain-tick GenServer for the PUSH-sync subsystem (the push mirror of
  `Barkpark.Sync.Worker`, but a POLL/drain loop, not an endless stream).

  Each `:drain_tick` reads the push cursor, fetches the next un-pushed,
  non-sync-originated batch from `Barkpark.Sync.Outbox`, and runs it through the
  pure `Barkpark.Sync.Pusher.drain/3` seam. The transport
  (`push_fun`/`claim_fun`/`close_fun`), the tick scheduler (`tick_fun`), and the
  backoff (`backoff_fun`) are ALL injected seams (mirroring `Worker`'s
  `stream_fun`/`backoff_fun`); the defaults do real work, tests inject fakes
  (invariant #7) — no network, no sleeps.

  ## Advance discipline (invariant #3)

  The cursor only ever advances INSIDE `Pusher.drain` — after a `{:ok}` ack OR a
  durable `PushConflict.record` (write-then-advance). A transient `{:error, _}`
  HALTS the batch at that event's id; the cursor stays at the last success and
  the next tick replays `id > cursor` from the failed event. After a halt the
  next tick is scheduled on `backoff_fun(attempt)`; after a clean drain it is
  scheduled on the idle `push_interval_ms`.

  `draining?` guards against reentrant ticks (the `Worker` stale-ref lesson).

  DEFAULT-OFF (invariant #2): this worker is only spliced into the supervision
  tree when `Settings.push_active?/1` is true (full creds + the separate push
  flag). A fresh install never starts it.
  """

  use GenServer

  require Logger

  alias Barkpark.Sync
  alias Barkpark.Sync.{Outbox, PushCursor, Pusher}

  @floor_ms 1_000
  @cap_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Capped exponential backoff for drain-halt retry attempt `n` (0-based). Pure —
  extracted so retry timing is testable without sleeps.
  """
  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    min(@cap_ms, @floor_ms * Integer.pow(2, min(attempt, 16)))
  end

  @impl true
  def init(opts) do
    settings = Keyword.get(opts, :settings, Sync.config())

    state = %{
      settings: settings,
      ctx: Keyword.get(opts, :ctx, Sync.push_context(settings)),
      push_fun: Keyword.get(opts, :push_fun, &Pusher.push/3),
      claim_fun: Keyword.get(opts, :claim_fun, &Pusher.claim/3),
      close_fun: Keyword.get(opts, :close_fun, &Pusher.close/3),
      tick_fun: Keyword.get(opts, :tick_fun, &default_tick/2),
      backoff_fun: Keyword.get(opts, :backoff_fun, &backoff_ms/1),
      attempt: 0,
      draining?: false
    }

    {:ok, state, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    %{source: source, dataset: dataset} = state.ctx
    PushCursor.bootstrap_if_absent(Map.get(state.ctx, :workspace_id), source, dataset)
    schedule(state, 0)
    {:noreply, state}
  end

  @impl true
  # Reentrancy guard (defensive; handle_info is sequential so this is belt-and-
  # suspenders against a doubly-scheduled tick).
  def handle_info(:drain_tick, %{draining?: true} = state), do: {:noreply, state}

  def handle_info(:drain_tick, state) do
    state = %{state | draining?: true}
    %{source: source, dataset: dataset} = state.ctx

    since = PushCursor.get(source, dataset)
    events = Outbox.fetch(dataset, since, state.settings.push_batch_size)

    funs = %{
      push_fun: state.push_fun,
      claim_fun: state.claim_fun,
      close_fun: state.close_fun
    }

    {results, cursor} = Pusher.drain(events, state.ctx, funs)

    {attempt, delay} =
      if halted?(results) do
        # `state.attempt` (pre-increment) still drives `backoff_fun` exactly as
        # before this change — only the NEW value is reused as the
        # consecutive-halt count for visibility, no extra state field.
        new_attempt = state.attempt + 1
        report_halt(state.ctx, results, cursor, new_attempt)
        {new_attempt, state.backoff_fun.(state.attempt)}
      else
        {0, state.settings.push_interval_ms}
      end

    schedule(state, delay)
    {:noreply, %{state | attempt: attempt, draining?: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp halted?(results) do
    Enum.any?(results, &match?({_id, {:error, :transient}}, &1))
  end

  # Drain-halt visibility (the PUSH side of this subsystem was previously
  # completely dark — no log, telemetry, or dead-letter; the PULL side has had
  # a `Logger.warning` at the equivalent site since `Worker` was written).
  #
  # The warning is rate-limited to a cadence that widens WITH the backoff
  # itself: fired on the 1st halt, then only when `consecutive_halts` is a
  # power of two (1, 2, 4, 8, 16, 32, ...). A remote that is wedged for good
  # still gets a trickle of warnings forever (never silence), but a transient
  # blip that clears in a few ticks logs once, not once per ~30s forever.
  # Telemetry is NOT rate-limited — it fires on every halt, because a counter
  # losing samples to a log-noise budget defeats the point of a counter; the
  # log is the noise-bounded surface, the telemetry event is the complete one.
  #
  # `reason` is logged exactly as `Pusher.drain/3` returns it today (always
  # `:transient` — pusher.ex collapses every non-whitelisted failure before it
  # gets here). Threading the pre-coercion underlying reason out of Pusher is
  # deferred (backlog: wb-bl-sync-pusher-reason-preservation) and explicitly
  # OUT of this task's fence; reporting `:transient` honestly beats fabricating
  # a cause this worker does not actually have.
  defp report_halt(ctx, results, cursor, consecutive_halts) do
    {halted_id, reason} = halted_entry(results)

    metadata = %{
      source: ctx.source,
      dataset: ctx.dataset,
      url: Map.get(ctx, :url),
      event_id: halted_id,
      cursor: cursor,
      reason: reason,
      consecutive_halts: consecutive_halts
    }

    if log_halt?(consecutive_halts) do
      Logger.warning(
        "[Sync] push drain halted at event #{inspect(halted_id)} " <>
          "(#{inspect(reason)}) pushing #{inspect(ctx.dataset)} to " <>
          "#{inspect(Map.get(ctx, :url))}; cursor frozen at #{cursor}, " <>
          "consecutive halts: #{consecutive_halts}"
      )
    end

    :telemetry.execute(
      [:barkpark, :sync, :push, :halt],
      %{consecutive_halts: consecutive_halts, cursor: cursor},
      metadata
    )

    :ok
  end

  defp halted_entry(results) do
    case Enum.find(results, &match?({_id, {:error, :transient}}, &1)) do
      {id, {:error, reason}} -> {id, reason}
      nil -> {nil, :transient}
    end
  end

  defp log_halt?(1), do: true
  defp log_halt?(n) when n > 1, do: power_of_two?(n)
  defp log_halt?(_), do: false

  defp power_of_two?(n) when n <= 0, do: false
  defp power_of_two?(1), do: true
  defp power_of_two?(n) when rem(n, 2) == 0, do: power_of_two?(div(n, 2))
  defp power_of_two?(_), do: false

  defp schedule(state, delay), do: state.tick_fun.(self(), delay)

  defp default_tick(pid, delay), do: Process.send_after(pid, :drain_tick, delay)
end
