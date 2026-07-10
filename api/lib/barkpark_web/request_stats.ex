defmodule BarkparkWeb.RequestStats do
  @moduledoc """
  Rolling per-request throughput + latency aggregator for the Phoenix instance.

  Phoenix's `Plug.Telemetry` (endpoint.ex:75) emits `[:phoenix, :endpoint, :stop]`
  with a `%{duration: native}` measurement on every request, but nothing on the
  instance consumed it — the `Telemetry.Metrics.ConsoleReporter` is commented out
  and `LiveDashboard` is dev-only. This module is the missing aggregator: a
  supervised process that attaches to that event, keeps a bounded ~60s rolling
  window of durations in an ETS ring, and derives:

    * `req_per_s` — request count over the window divided by the *elapsed* window
      (`min(uptime, window)`), so a box that booted 5s ago reports an honest rate
      instead of dividing by a full 60s it has not lived through yet.
    * `p95_ms`   — the 95th-percentile request duration (nearest-rank) in ms, or
      `nil` when the window is empty. Zero samples is **not** `0ms` — a fabricated
      floor would be a lie (charter D48 honest-meters law). It is the honest `null`.

  The write path (the telemetry handler) inserts straight into a public ETS
  table so high request rates never serialize through the process mailbox; the
  read path (`stats/1`) is a `GenServer.call` because reads are rare (the on-box
  agent polls the exposed route on its beat, sibling slice
  `cloud-console-w5-agent-reqstats-beat`). A timer prunes expired rows so memory
  stays bounded to roughly one window's worth of samples.

  The read shape is pinned by charter OC24 so the agent slice builds against it
  in parallel: `%{req_per_s: float, p95_ms: integer | nil, window_s: integer}`.
  """

  use GenServer

  @window_ms 60_000
  @prune_every_ms 10_000
  @default_table :barkpark_request_stats

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Current window stats: `%{req_per_s: float, p95_ms: integer | nil, window_s: integer}`.

  Falls back to an honest empty window (`req_per_s: 0.0`, `p95_ms: nil`) if the
  aggregator process is not running, so the exposed route degrades to the truth
  rather than 500-ing.
  """
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  catch
    :exit, _ ->
      now = now_ms()
      compute([], now, now, @window_ms)
  end

  @doc "The rolling window length in seconds (contract field `window_s`)."
  def window_s, do: div(@window_ms, 1000)

  # ── Telemetry handler (write path — runs in the request process) ──────────

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, _meta, %{table: table}) do
    duration_ms = System.convert_time_unit(duration, :native, :microsecond) / 1000
    key = {System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}
    :ets.insert(table, {key, duration_ms})
    :ok
  rescue
    # A telemetry handler must NEVER take down the request it is measuring — a
    # missing table (process restarting) or any surprise degrades to a no-op.
    _ -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # ── Pure math (unit-tested directly; no process needed) ───────────────────

  @doc """
  Derive the window stats from raw `{time_ms, duration_ms}` samples.

  `elapsed = min(now - started, window)` — a fresh boot reports over the time it
  has actually lived, never a fabricated full window. Empty window ⇒
  `req_per_s: 0.0` (true) and `p95_ms: nil` (no samples is not 0ms).
  """
  def compute(samples, now_ms, started_ms, window_ms) do
    cutoff = now_ms - window_ms
    in_window = for {t, d} <- samples, t >= cutoff, do: d
    count = length(in_window)

    uptime_ms = max(now_ms - started_ms, 0)
    # Clamp to >= 1ms so the very first millisecond of uptime cannot divide by
    # zero; min(uptime, window) keeps a young box honest.
    elapsed_ms = uptime_ms |> min(window_ms) |> max(1)

    req_per_s =
      if count == 0 do
        0.0
      else
        Float.round(count * 1000 / elapsed_ms, 2)
      end

    p95_ms =
      case in_window do
        [] -> nil
        durations -> durations |> Enum.sort() |> percentile(95) |> round()
      end

    %{req_per_s: req_per_s, p95_ms: p95_ms, window_s: div(window_ms, 1000)}
  end

  @doc """
  Nearest-rank percentile over an already-sorted (ascending) list of numbers.

  `rank = ceil(p/100 * n)`, clamped to `1..n`; returns the value at that rank.
  `[]` ⇒ `nil`.
  """
  def percentile([], _p), do: nil

  def percentile(sorted, p) when is_list(sorted) do
    n = length(sorted)
    rank = (p / 100 * n) |> Float.ceil() |> round() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    :ets.new(table, [:ordered_set, :public, :named_table, {:write_concurrency, true}])

    handler_id = "barkpark-request-stats-" <> inspect(table)

    :telemetry.attach(
      handler_id,
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_event/4,
      %{table: table}
    )

    schedule_prune()

    {:ok,
     %{
       table: table,
       handler_id: handler_id,
       started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    samples =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {{t, _uniq}, d} -> {t, d} end)

    reply = compute(samples, now_ms(), state.started_at, @window_ms)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now_ms() - @window_ms
    # ordered_set keyed by {time_ms, unique}: drop every row whose time is older
    # than the window. Bounds memory to ~one window (+ one prune interval).
    :ets.select_delete(state.table, [{{{:"$1", :_}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
