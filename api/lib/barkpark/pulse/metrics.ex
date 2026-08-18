defmodule Barkpark.Pulse.Metrics do
  @moduledoc """
  Live cost telemetry for the Pulse channels (Shared Storm) — TRUE dynamics,
  not vanity numbers. Every reading is measured on this node:

    * **CPU** — real BEAM scheduler utilization (`:scheduler_wall_time`
      deltas between ticks), the honest "what does the storm cost the box"
      number. It climbs when visitors join and wiggle cursors, and falls
      back when they leave.
    * **Memory / run queue** — `:erlang.memory(:total)` and
      `:erlang.statistics(:total_run_queue_lengths)`.
    * **Rates** — cursor frames relayed and strikes recorded per interval,
      bumped from the hot paths via lock-free `:counters` (fetched through
      `:persistent_term`, so with the plugin off the bump is a no-op and the
      hot path pays nothing).

  A 2 s tick computes deltas and stores an immutable snapshot in
  `:persistent_term`; readers (`snapshot/0` — the dashboard) never touch the
  GenServer, so a busy dashboard can't back-pressure the sampler.

  Every tick the snapshot is ALSO broadcast as a `"vitals"` event on each
  configured channel's topic — the public storm clients render the live cost
  as part of the demo ("this is what the storm costs right now"). The payload
  is deliberately coarse/rounded; storage sizing is re-read from Postgres only
  once a minute and cached.

  Started via the pulse plugin's `register_workers/1` — plugin off = no
  process, no `:scheduler_wall_time` flag flip, nothing.
  """

  use GenServer

  @tick_ms 2_000
  @month_seconds 2_592_000
  @counters_key {__MODULE__, :counters}
  @snapshot_key {__MODULE__, :snapshot}

  # counter slots
  @slot_cursor 1
  @slot_strike 2

  # ── hot-path bumps (safe no-ops when the sampler isn't running) ───────

  def bump(:cursor), do: add(@slot_cursor)
  def bump(:strike), do: add(@slot_strike)

  defp add(slot) do
    case :persistent_term.get(@counters_key, nil) do
      nil -> :ok
      ref -> :counters.add(ref, slot, 1)
    end
  end

  @doc """
  Test-only: synchronously run one sample (atomically snapshot + drain the
  counters, publish, broadcast) and return the resulting snapshot, WITHOUT
  re-arming the autonomous timer. It also cancels any pending autonomous
  `:tick`, so once a test calls this the 2 s sampler can no longer fire and
  drain the counters between a bump loop and its assertion. Prod never calls
  this — the `:tick` handler's cadence is unchanged.
  """
  def sample_now, do: GenServer.call(__MODULE__, :sample_now)

  @doc """
  The latest sampled snapshot (or a zeroed one before the first tick /
  with the sampler off). Reads are `:persistent_term` — free.
  """
  def snapshot do
    :persistent_term.get(@snapshot_key, %{
      cpu_util: 0.0,
      mem_mb: 0.0,
      run_queue: 0,
      cursor_per_s: 0.0,
      strikes_per_min: 0.0,
      cost_eur_total: 0.0,
      sampled: false
    })
  end

  # ── sampler ───────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :erlang.system_flag(:scheduler_wall_time, true)
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put(@counters_key, ref)

    cost0 =
      try do
        Barkpark.Pulse.cost_nanos()
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    state = %{
      ref: ref,
      swt: :erlang.statistics(:scheduler_wall_time),
      last_ms: now_ms(),
      ticks: 0,
      storage: %{bytes: 0, rows: 0},
      cost_total_nanos: cost0,
      cost_pending_nanos: 0,
      tref: nil
    }

    tref = Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{state | tref: tref}}
  end

  @impl true
  def handle_info(:tick, state) do
    {_snap, state} = do_sample(state)

    tref = Process.send_after(self(), :tick, @tick_ms)

    {:noreply, %{state | tref: tref}}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    # test-only: cancel the pending autonomous tick and do not re-arm, so the
    # 2 s sampler can no longer drain the counters mid-test; sample synchronously
    # so the caller observes exactly this interval's rates.
    if is_reference(state.tref), do: Process.cancel_timer(state.tref)
    {snap, state} = do_sample(state)
    {:reply, snap, %{state | tref: nil}}
  end

  # One sampling pass: snapshot + atomically drain the counters, integrate cost,
  # publish to :persistent_term, broadcast vitals. Returns {snap, new_state}.
  # Does NOT touch the timer — the caller owns cadence (handle_info re-arms the
  # 2 s prod loop; sample_now deliberately does not).
  defp do_sample(%{ref: ref, swt: swt0, last_ms: last_ms} = state) do
    swt1 = :erlang.statistics(:scheduler_wall_time)
    elapsed_s = max(0.001, (now_ms() - last_ms) / 1000)

    cursor = :counters.get(ref, @slot_cursor)
    strike = :counters.get(ref, @slot_strike)
    :counters.put(ref, @slot_cursor, 0)
    :counters.put(ref, @slot_strike, 0)

    snap = %{
      cpu_util: scheduler_util(swt0, swt1),
      mem_mb: :erlang.memory(:total) / 1_048_576,
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      cursor_per_s: cursor / elapsed_s,
      strikes_per_min: strike / elapsed_s * 60,
      sampled: true
    }

    # integrate this interval's compute cost (nano-euros) into the running
    # total; flush the pending sum to the durable meter about once a minute.
    price = host_eur_month()
    tick_nanos = round(snap.cpu_util * price / @month_seconds * elapsed_s * 1_000_000_000)
    cost_total = state.cost_total_nanos + tick_nanos
    cost_pending = state.cost_pending_nanos + tick_nanos

    cost_pending =
      if cost_pending > 0 and rem(state.ticks, 30) == 0 do
        try do
          Barkpark.Pulse.add_cost_nanos(cost_pending)
          0
        rescue
          _ -> cost_pending
        catch
          :exit, _ -> cost_pending
        end
      else
        cost_pending
      end

    snap = Map.put(snap, :cost_eur_total, cost_total / 1_000_000_000)
    :persistent_term.put(@snapshot_key, snap)

    # storage is a DB read — refresh once a minute, keep the cached value between
    storage =
      if rem(state.ticks, 30) == 0 do
        try do
          st = Barkpark.Pulse.storage()
          %{bytes: st.events_bytes + st.counters_bytes, rows: st.event_rows}
        rescue
          _ -> state.storage
        catch
          :exit, _ -> state.storage
        end
      else
        state.storage
      end

    broadcast_vitals(snap, storage)

    {snap,
     %{
       state
       | swt: swt1,
         last_ms: now_ms(),
         ticks: state.ticks + 1,
         storage: storage,
         cost_total_nanos: cost_total,
         cost_pending_nanos: cost_pending
     }}
  end

  defp host_eur_month do
    case Application.get_env(:barkpark, :pulse_host_eur_month, 4.51) do
      n when is_number(n) -> n * 1.0
      _ -> 4.51
    end
  end

  # the public face of the cost: pushed on every configured channel topic so
  # the storm clients render it live. Coarse + rounded on purpose. MUST go
  # through `Endpoint.broadcast` (not a raw `PubSub.broadcast` of a
  # `%Broadcast{}`): the endpoint's channel dispatcher FASTLANES a
  # non-intercepted event straight to the transport, exactly like "strike". A
  # raw PubSub broadcast instead lands in each joined channel's `handle_info`
  # and calls `handle_out/3`, which PulseChannel doesn't define → the channel
  # crashes. Guarded because the Endpoint may not be up on the very first tick.
  defp broadcast_vitals(snap, storage) do
    price = host_eur_month()

    for name <- Map.keys(Barkpark.Pulse.channels()) do
      topic = "pulse:" <> name

      online =
        try do
          map_size(BarkparkWeb.Presence.list(topic))
        rescue
          _ -> 0
        catch
          :exit, _ -> 0
        end

      payload = %{
        cpu: Float.round(snap.cpu_util, 4),
        mem: Float.round(snap.mem_mb, 1),
        cps: Float.round(snap.cursor_per_s, 1),
        spm: Float.round(snap.strikes_per_min, 1),
        online: online,
        eur: Float.round(snap.cpu_util * price, 5),
        eur_total: Float.round(Map.get(snap, :cost_eur_total, 0.0), 9),
        host_eur: price,
        bytes: storage.bytes,
        rows: storage.rows
      }

      try do
        BarkparkWeb.Endpoint.broadcast(topic, "vitals", payload)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # weighted utilization across all schedulers: Σ active-delta / Σ total-delta
  defp scheduler_util(swt0, swt1) when is_list(swt0) and is_list(swt1) do
    base = Map.new(swt0, fn {id, a, t} -> {id, {a, t}} end)

    {da, dt} =
      Enum.reduce(swt1, {0, 0}, fn {id, a1, t1}, {da, dt} ->
        case base do
          %{^id => {a0, t0}} -> {da + (a1 - a0), dt + (t1 - t0)}
          _ -> {da, dt}
        end
      end)

    if dt > 0, do: min(1.0, da / dt), else: 0.0
  end

  defp scheduler_util(_, _), do: 0.0

  defp now_ms, do: System.monotonic_time(:millisecond)
end
