defmodule Barkpark.HostVitals.Sampler do
  @moduledoc """
  Always-on Linux-host vitals sampler for the Studio bottom bar.

  A single supervised process samples the **OS host** (not the BEAM VM) every
  `@tick_ms` and both (a) stashes the snapshot in `:persistent_term` for free
  reads and (b) broadcasts it on the shared `"server_vitals"` PubSub topic so
  every Studio socket updates from ONE clock instead of each socket sampling.

  Sources (all via OTP's `:os_mon`, started by `:os_mon` in `extra_applications`):

    * CPU util %   — `:cpu_sup.util/0` (interval util since this process's
      previous call; a single caller keeps the interval well-defined).
    * Load average — `:cpu_sup.avg1/5/15` (raw is load×256 → /256).
    * Memory       — `:memsup.get_system_memory_data/0` (total/free/available).
    * Disk         — `:disksup.get_disk_data/0`, the `/` mount (fallback: the
      largest mount).
    * Host uptime  — first float of `/proc/uptime` (the *host*, distinct from
      `Barkpark.Status.node_uptime_seconds/0` which is BEAM wall-clock).

  Honest-meters law (charter D48/OC24): a metric that can't be read degrades to
  `nil`, NEVER a fabricated `0`. Each probe is wrapped so one failing source
  can't crash the tick, and `snapshot/0` degrades to an all-`nil` frame when the
  sampler hasn't ticked yet (or isn't running).
  """

  use GenServer

  @snapshot_key {__MODULE__, :snapshot}
  @topic "server_vitals"
  @event "tick"
  @tick_ms 3_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The shared PubSub topic Studio sockets subscribe to for live frames."
  def topic, do: @topic

  @doc """
  Latest sampled host snapshot. Reads are `:persistent_term` — free, no message.

  Before the first tick (or with the sampler down) returns an honest all-`nil`
  frame with `sampled_at: nil`, so callers can render `—` rather than a lie.
  """
  def snapshot do
    :persistent_term.get(@snapshot_key, empty_snapshot())
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if enabled?() do
      # Prime :cpu_sup.util/0 so the first real reading measures an interval
      # rather than since-boot. Wrapped: :os_mon may lag boot on some hosts.
      _ = safe(fn -> :cpu_sup.util() end)
      {:ok, %{timer: Process.send_after(self(), :tick, @tick_ms)}}
    else
      {:ok, %{timer: nil}}
    end
  end

  # DORMANT IN TEST (task-31dc7c0068696546). Every Studio LiveView embeds the
  # sticky `BarkparkWeb.ServerVitalsLive`, which re-renders on each tick of THIS
  # process with the MACHINE's CPU %, RAM, disk, load and uptime. Boot-started
  # under `mix test`, the tick lands inside any test that compares two renders
  # of the same page, and the page differs by bytes nothing in the test did:
  # `BoardLiveTest` "the seen-set drops a repeated event" reddened main run
  # 36554218282 and PR run 36747193823 that way, and reproduced locally 1 in 30
  # with the diff `CPU 97% -> 94%, load 10.18 -> 9.68`. The shares-panel test
  # (task-f0ad13818246990c) was narrowed for the same bytes; ~100 other
  # whole-page compares carry the same coin flip. Gated OFF in config/test.exs,
  # so the bar renders the honest all-nil frame (`—`); `sample/0` and
  # `snapshot/0` stay callable and are tested directly. Defaults ON — dev and
  # prod are unchanged. Same shape as the `BlockedSweeper` gate.
  defp enabled? do
    :barkpark |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end

  @impl true
  def handle_info(:tick, state) do
    snap = sample()
    :persistent_term.put(@snapshot_key, snap)
    # The tick must never take down the sampler: if PubSub/Endpoint isn't up
    # yet (early boot) or is tearing down, the broadcast degrades to a no-op —
    # persistent_term is already updated, so snapshot/0 reads stay correct.
    safe(fn -> BarkparkWeb.Endpoint.broadcast(@topic, @event, snap) end)
    {:noreply, %{state | timer: Process.send_after(self(), :tick, @tick_ms)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Sampling (each probe independently crash-safe → nil) ───────────────────

  @doc false
  def sample do
    mem = mem_data()
    {disk_pct, disk_total_gb} = disk_data()

    %{
      cpu_pct: cpu_util(),
      load1: load_avg(&:cpu_sup.avg1/0),
      load5: load_avg(&:cpu_sup.avg5/0),
      load15: load_avg(&:cpu_sup.avg15/0),
      mem_used_mb: mem.used_mb,
      mem_total_mb: mem.total_mb,
      mem_pct: mem.pct,
      disk_pct: disk_pct,
      disk_total_gb: disk_total_gb,
      host_uptime_s: host_uptime_s(),
      sampled_at: System.system_time(:second)
    }
  end

  # :cpu_sup.util/0 → busy percent since the previous call (0.0..100.0).
  defp cpu_util do
    safe(fn ->
      case :cpu_sup.util() do
        util when is_number(util) -> Float.round(util / 1, 1)
        _ -> nil
      end
    end)
  end

  # Raw avg* is the load average × 256; nil on failure (never a fake 0.0).
  defp load_avg(fun) do
    safe(fn ->
      case fun.() do
        v when is_integer(v) -> Float.round(v / 256, 2)
        _ -> nil
      end
    end)
  end

  defp mem_data do
    safe(fn ->
      data = :memsup.get_system_memory_data()
      total = data[:total_memory] || data[:system_total_memory]
      # Prefer :available_memory (accounts for reclaimable cache) when present,
      # else fall back to :free_memory. Nil-safe: if we can't derive "used",
      # every field stays nil.
      avail = data[:available_memory] || data[:free_memory]

      if is_integer(total) and total > 0 and is_integer(avail) do
        used = max(total - avail, 0)

        %{
          used_mb: round(used / 1_048_576),
          total_mb: round(total / 1_048_576),
          pct: Float.round(used / total * 100, 1)
        }
      else
        %{used_mb: nil, total_mb: nil, pct: nil}
      end
    end) || %{used_mb: nil, total_mb: nil, pct: nil}
  end

  # :disksup.get_disk_data/0 → [{mount_charlist, total_kb, percent_used_int}].
  # Prefer "/"; fall back to the largest mount by capacity.
  defp disk_data do
    safe(fn ->
      case :disksup.get_disk_data() do
        [{~c"none", _, _}] -> {nil, nil}
        [] -> {nil, nil}
        disks when is_list(disks) -> pick_disk(disks)
        _ -> {nil, nil}
      end
    end) || {nil, nil}
  end

  defp pick_disk(disks) do
    root = Enum.find(disks, fn {mount, _kb, _pct} -> mount == ~c"/" end)
    {mount, total_kb, pct} = root || Enum.max_by(disks, fn {_m, kb, _p} -> kb end)
    _ = mount
    {pct, Float.round(total_kb / 1_048_576, 1)}
  end

  # First float of /proc/uptime = seconds since host boot. nil off-Linux.
  defp host_uptime_s do
    safe(fn ->
      case File.read("/proc/uptime") do
        {:ok, contents} ->
          contents
          |> String.split()
          |> List.first()
          |> case do
            nil ->
              nil

            field ->
              field
              |> Float.parse()
              |> case do
                {secs, _} -> round(secs)
                :error -> nil
              end
          end

        _ ->
          nil
      end
    end)
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp empty_snapshot do
    %{
      cpu_pct: nil,
      load1: nil,
      load5: nil,
      load15: nil,
      mem_used_mb: nil,
      mem_total_mb: nil,
      mem_pct: nil,
      disk_pct: nil,
      disk_total_gb: nil,
      host_uptime_s: nil,
      sampled_at: nil
    }
  end

  # Any probe failure (missing :os_mon module, odd mount, unreadable /proc)
  # degrades to nil — a metric is never fabricated.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
