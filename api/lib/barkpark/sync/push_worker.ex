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
    PushCursor.bootstrap_if_absent(source, dataset)
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

    {results, _cursor} = Pusher.drain(events, state.ctx, funs)

    {attempt, delay} =
      if halted?(results) do
        {state.attempt + 1, state.backoff_fun.(state.attempt)}
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

  defp schedule(state, delay), do: state.tick_fun.(self(), delay)

  defp default_tick(pid, delay), do: Process.send_after(pid, :drain_tick, delay)
end
