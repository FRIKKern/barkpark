defmodule Barkpark.Plugins.Github.DrainWorker do
  @moduledoc """
  Drain-tick GenServer for the OUTBOUND Barkpark→GitHub mirror — the level-
  triggered pump that turns durable `mutation_events` into debounced per-task
  `MirrorJob`s (epic D1/D2). Structural copy of `Barkpark.Sync.PushWorker`: a
  poll/drain loop (NOT an endless stream, NOT cron), with injected transport/
  scheduler seams so the whole engine tests without Oban, network, or sleeps.

  Each `:drain_tick`, for EVERY whitelisted dataset:

    1. `Cursor.bootstrap_if_absent/1` (idempotent) — a first-seen dataset seeds
       its cursor to head so a newly-whitelisted dataset skips its pre-enable
       backlog (D1), never mass-mirroring history. A no-op once a row exists.
    2. `since = Cursor.get(ds)`; `events = Outbox.fetch(ds, since, batch)` — the
       next `id > since`, non-`source="github"` (loop-cut #2, D4) TASK events.
    3. For each event, enqueue a debounced `MirrorJob` (`unique` on
       `{doc_id, dataset}`, `schedule_in: 30`) — a burst coalesces into ONE
       write that reconciles the task's CURRENT state (D2).

  ## Advance discipline — write-then-advance (D1)

  The cursor advances to `max_enqueued_id` ONLY after every enqueue in the batch
  succeeded. On an enqueue error the batch HALTS at that event's id: the cursor
  stops at the last successfully-enqueued id (never past an un-enqueued event),
  the tick backs off (`backoff_ms/1`), and the next tick replays `id > cursor`
  from the failed event. `Cursor.put/2` is a monotonic upsert, so advancing to
  the pre-drain `since` on an immediate failure is a safe no-op.

  ## Idle gate (default-off preserved)

  When `Settings.active?/0` is false the tick does ZERO work and reschedules at
  the idle interval — a whitelisted-but-dark plugin (creds absent/incomplete)
  never touches a cursor or GitHub. Claims, epochs, fencing, rail_rev NEVER
  leave Barkpark; this worker only ever READS the outbox and enqueues.

  ## Loop immunity BY CONSTRUCTION

  A mirror's own bookkeeping write (`Link.put(source: :github)`) lands in
  `mutation_events` stamped `source="github"`, which `Outbox.fetch/3` EXCLUDES —
  so re-draining after a mirror yields zero new rows and enqueues zero jobs. The
  loop is broken structurally, not by timing (D4 cut #2).

  ## Injected seams (invariant: no Oban, no network, no sleeps in tests)

    * `enqueue_fun`  — default `&MirrorJob.enqueue/1`; `%{doc_id, dataset}` in,
      `:ok` / `{:ok, _}` = success, anything else = halt-this-batch.
    * `tick_fun`     — default `Process.send_after/3`; `(pid, delay_ms)`.
    * `datasets_fun` — default `&Settings.datasets/0`; the whitelisted datasets.
    * `active_fun`   — default `&Settings.active?/0`; the idle gate.
    * `backoff_fun`  — default `&backoff_ms/1`; halt-retry timing.
    * `batch_size` / `idle_ms` — drain window + idle poll cadence.

  ## Lifecycle

  Supervised by the plugin's `register_workers/1` (alongside `Github.Auth`) — so
  it starts ONLY when `github` is whitelisted, preserving off-by-default. It is a
  supervised GenServer, NOT an `oban_crontab` entry (the `PushWorker` precedent);
  `Github.oban_crontab/0` stays empty.
  """

  use GenServer

  alias Barkpark.Plugins.Github.{Cursor, MirrorJob, Outbox, Settings}

  # Halt-retry backoff bounds (mirrors PushWorker): 1 s floor, 30 s cap.
  @floor_ms 1_000
  @cap_ms 30_000

  # Drain window per dataset per tick. The unique-coalescing MirrorJob absorbs
  # bursts downstream, so a generous batch just moves the cursor faster.
  @default_batch_size 100

  # Idle poll cadence. The mirror's user-visible latency budget is ~30 s and the
  # MirrorJob itself debounces `schedule_in: 30`, so a sub-30 s poll keeps the
  # cursor fresh without hammering the outbox query.
  @default_idle_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
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
    state = %{
      enqueue_fun: Keyword.get(opts, :enqueue_fun, &default_enqueue/1),
      tick_fun: Keyword.get(opts, :tick_fun, &default_tick/2),
      datasets_fun: Keyword.get(opts, :datasets_fun, &default_datasets/0),
      active_fun: Keyword.get(opts, :active_fun, &default_active?/0),
      backoff_fun: Keyword.get(opts, :backoff_fun, &backoff_ms/1),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      attempt: 0,
      draining?: false
    }

    {:ok, state, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    # Seed every currently-whitelisted dataset's cursor to head so first enable
    # skips ALL pre-enable backlog (D1). Idempotent — safe on every boot.
    Enum.each(state.datasets_fun.(), &Cursor.bootstrap_if_absent/1)
    schedule(state, 0)
    {:noreply, state}
  end

  @impl true
  # Reentrancy guard (defensive; handle_info is sequential, so this is belt-and-
  # suspenders against a doubly-scheduled tick — the PushWorker stale-ref lesson).
  def handle_info(:drain_tick, %{draining?: true} = state), do: {:noreply, state}

  def handle_info(:drain_tick, state) do
    state = %{state | draining?: true}

    if state.active_fun.() do
      halted? =
        Enum.reduce(state.datasets_fun.(), false, fn dataset, acc ->
          drain_dataset(dataset, state) or acc
        end)

      {attempt, delay} =
        if halted? do
          {state.attempt + 1, state.backoff_fun.(state.attempt)}
        else
          {0, state.idle_ms}
        end

      schedule(state, delay)
      {:noreply, %{state | attempt: attempt, draining?: false}}
    else
      # Dark-but-whitelisted: no creds resolved yet → do no work, poll again.
      schedule(state, state.idle_ms)
      {:noreply, %{state | draining?: false}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Drain one dataset. Returns true when the batch HALTED on an enqueue error
  # (so the tick backs off), false on a clean (possibly empty) drain.
  defp drain_dataset(dataset, state) do
    # A dataset that appeared AFTER boot (creds provisioned later) has no cursor
    # row yet; seed it to head so it too skips its pre-enable backlog (D1). A
    # no-op for datasets already bootstrapped in handle_continue.
    Cursor.bootstrap_if_absent(dataset)

    since = Cursor.get(dataset)
    events = Outbox.fetch(dataset, since, state.batch_size)

    {last_ok_id, halted?} = enqueue_batch(events, dataset, since, state.enqueue_fun)

    # Write-then-advance: park the cursor at the last successfully-enqueued id
    # (never past an un-enqueued event). Monotonic put makes `since` a no-op.
    Cursor.put(dataset, last_ok_id)
    halted?
  end

  # Enqueue events in strict id order, halting at the first failure. Returns
  # `{last_ok_id, halted?}` where `last_ok_id` is the highest id whose enqueue
  # (and every prior enqueue) succeeded — or `since` if the very first failed.
  defp enqueue_batch(events, dataset, since, enqueue_fun) do
    Enum.reduce_while(events, {since, false}, fn event, {last_ok, _halted} ->
      case enqueue_fun.(%{doc_id: event.doc_id, dataset: dataset}) do
        :ok -> {:cont, {event.id, false}}
        {:ok, _} -> {:cont, {event.id, false}}
        _error -> {:halt, {last_ok, true}}
      end
    end)
  end

  defp schedule(state, delay), do: state.tick_fun.(self(), delay)

  defp default_tick(pid, delay), do: Process.send_after(pid, :drain_tick, delay)

  # ---------------------------------------------------------------------------
  # Default seams — resolved against the sibling `Settings`/`MirrorJob` modules.
  #
  # The plugin's `register_workers/1` folds this worker into the boot supervision
  # tree via the plugin disk-walk on EVERY boot (like `Bokbasen.Auth`), even when
  # `github` is dark/unconfigured — and, during the wave-2 sequencing window,
  # even before `Github.Settings`/`Github.MirrorJob` are present. So the defaults
  # MUST NOT crash a dark install: an absent resolver reads as "no datasets,
  # inactive", exactly the harmless-dark posture `Auth`'s lazy init gives. Once
  # `Settings` is loaded these delegate straight through. `MirrorJob.enqueue` is
  # only ever reached on an ACTIVE drain, so a dark install never touches it.
  # ---------------------------------------------------------------------------

  defp default_datasets do
    if Code.ensure_loaded?(Settings), do: apply(Settings, :datasets, []), else: []
  end

  defp default_active? do
    Code.ensure_loaded?(Settings) and apply(Settings, :active?, [])
  end

  defp default_enqueue(args), do: apply(MirrorJob, :enqueue, [args])
end
