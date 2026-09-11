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

  # `shutdown: 20_000`: `terminate/2` below flushes the buffered billable cost
  # through a real Postgres write, and the supervisor's shutdown timeout is the
  # hard bound on that flush — a `terminate/2` that has not returned when the
  # timeout expires is brutally killed and the buffer is lost exactly as if no
  # `terminate/2` existed. The default 5_000 from `use GenServer` is SHORTER
  # than Ecto's own default 15_000 query timeout, so a stalled/checkout-starved
  # Repo would hit the supervisor's axe BEFORE the query gave up and the rescue
  # below could run. 20_000 leaves the query room to time out and be swallowed.
  # Same reasoning as the in-tree sibling `Plugins.Sheets.Session`
  # (`shutdown: 30_000` for its debounced upsert).
  use GenServer, shutdown: 20_000

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

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts) do
    # The whole point of `terminate/2` below. Without this flag the supervisor's
    # shutdown `exit(:shutdown)` kills this process outright and `terminate/2`
    # is never called, so every graceful stop discards the buffered cost.
    Process.flag(:trap_exit, true)

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

  @impl true
  def terminate(_reason, state) do
    # DURABILITY SEAM. Compute cost accrues into `cost_pending_nanos` and only
    # reaches the durable meter once a minute (see `do_sample/1`), while
    # `init/1` re-seeds `cost_total_nanos` from that meter. Without this flush a
    # stop discards up to 60 s of billable cost SILENTLY: the total simply
    # resumes from the last flushed value, so `eur_total` steps backwards on the
    # storm dashboard after every deploy and the meter under-counts forever.
    # This box auto-deploys on merge, so that is not a rare crash path — it is
    # the normal one.
    #
    # Reached only on a GRACEFUL stop with `trap_exit` set (see `init/1`): a
    # `Supervisor`/`Application` shutdown, `GenServer.stop/1`, or the VM's
    # SIGTERM handler running `init:stop()`. A `:brutal_kill`, a SIGKILL, or an
    # overrun of the `shutdown: 20_000` budget above still loses the buffer —
    # nothing in OTP can promise otherwise.
    #
    # Fully guarded: the Repo may already be down or unreachable at shutdown,
    # and a `terminate/2` that raises would log a crash report on every single
    # clean stop. Losing the flush is exactly the pre-existing behaviour; an
    # exception here would be a new one.
    case state do
      %{cost_pending_nanos: pending} when is_integer(pending) and pending > 0 ->
        try do
          Barkpark.Pulse.add_cost_nanos(pending)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    :ok
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

    # FLUSH WINDOW. `ticks` starts at 0, so the old `rem(state.ticks, 30) == 0`
    # fired on the VERY FIRST tick — a durable meter write 2 s after boot, then
    # every 60 s. `rem(state.ticks, 30) == 0` is the same once-a-minute
    # cadence with the first flush at the first FULL minute, which is what the
    # comment above and the moduledoc have always claimed. The up-to-60 s buffer
    # this leaves exposed is no longer a loss: `terminate/2` flushes it on every
    # graceful stop.
    cost_pending =
      if cost_pending > 0 and rem(state.ticks + 1, 30) == 0 do
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

    # storage is a DB read — refresh once a minute, keep the cached value between.
    # DELIBERATELY still `rem(state.ticks, 30) == 0`, i.e. it DOES fire on the
    # first tick 2 s after boot: this is a cached READ that only feeds the
    # dashboard's bytes/rows figures, and warming it immediately is the point —
    # the alternative is a storm dashboard reporting 0 bytes / 0 rows for the
    # first minute after every restart. Unlike the cost flush above, nothing is
    # buffered and nothing can be lost, so the first-tick firing is a feature.
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
