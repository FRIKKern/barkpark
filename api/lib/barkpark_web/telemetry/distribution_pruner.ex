defmodule BarkparkWeb.Telemetry.DistributionPruner do
  @moduledoc """
  Keeps the Prometheus distribution table bounded on instances nobody scrapes.

  `TelemetryMetricsPrometheus.Core` stores every observation of a
  `Telemetry.Metrics.Distribution` as an individual ETS row, and folds those rows
  into histogram buckets — deleting them — only when the aggregator is scraped.
  That is correct for a pull-based exporter with a puller attached. Barkpark
  registers distributions on `barkpark.repo.query.{total_time,queue_time}`, which
  fire on EVERY Ecto query, and `GET /v1/instance/metrics` is the only thing that
  scrapes. An instance with no Prometheus pointed at it therefore accumulates one
  ETS row per database query, forever.

  Measured on a self-hosted instance: 960_168 rows / 164 MB after twenty minutes
  of uptime, and `beam.smp` killed by the kernel OOM killer four days running at
  ~2.7 GB RSS. A single scrape took the table to 8 rows and `:erlang.memory()[:ets]`
  from 186 MB to 14 MB.

  There is an irony worth naming: the aggregator was added so prod could answer
  "is VM memory climbing?" — see the comment in `BarkparkWeb.Telemetry.init/1`,
  which calls that question "a real OOM scar". Unscraped, the answer-machine
  became the cause.

  ## Why this owns every scrape

  Core folds raw distribution rows into cumulative histogram buckets, so an
  internal scrape does not steal already-counted samples from Prometheus. The
  fold itself is not serialized, though: overlapping scrapes can both read an
  old aggregate and then overwrite one another's update. This process therefore
  owns both external and timer-driven scrapes. A tick runs only if the endpoint
  has been unused for `:idle_after`, avoiding redundant exposition work when a
  real Prometheus is attached while keeping an unscraped instance flat.
  """

  use GenServer
  require Logger

  @aggregator :barkpark_metrics
  # A minute between ticks: fine-grained enough that an idle instance never holds
  # more than a minute of queries, cheap enough to be invisible.
  @tick :timer.minutes(1)
  # Five minutes of silence before we call the endpoint unused. Comfortably longer
  # than any sane Prometheus scrape interval (15–60s), so a real scraper going
  # briefly missing doesn't hand its samples to us.
  @idle_after :timer.minutes(5)

  def start_link(opts) do
    # `:name` is overridable so a test can run an isolated pruner alongside the
    # one in the supervision tree — `last_scrape` is per-process state, and a
    # test that mutated the real one would leak into everything after it.
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Serializes an external scrape with timer-driven distribution pruning.

  Falls back to Core when the pruner is absent. Some focused test setups start
  the aggregator without the full telemetry supervision tree; with no pruner
  running, there is no timer scrape to race.
  """
  def scrape(server \\ __MODULE__) do
    GenServer.call(server, :scrape, :infinity)
  catch
    :exit, _ -> TelemetryMetricsPrometheus.Core.scrape(@aggregator)
  end

  @impl true
  def init(opts) do
    state = %{
      aggregator: Keyword.get(opts, :aggregator, @aggregator),
      scrape_fun: Keyword.get(opts, :scrape_fun, &TelemetryMetricsPrometheus.Core.scrape/1),
      tick: Keyword.get(opts, :tick, @tick),
      idle_after: Keyword.get(opts, :idle_after, @idle_after),
      # `nil` = nobody has ever scraped. The common case, and the one this
      # process exists for.
      last_scrape: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:scrape, _from, state) do
    metrics = scrape_metrics(state)
    {:reply, metrics, %{state | last_scrape: now_ms()}}
  end

  # Exposed for the test: lets it drive a tick without waiting a minute.
  def handle_call(:prune_now, _from, state) do
    pruned? = idle?(state)
    if pruned?, do: prune(state)
    {:reply, pruned?, state}
  end

  @impl true
  def handle_info(:prune, state) do
    if idle?(state), do: prune(state)
    {:noreply, schedule(state)}
  end

  defp idle?(%{last_scrape: nil}), do: true
  defp idle?(%{last_scrape: at, idle_after: idle_after}), do: now_ms() - at >= idle_after

  defp prune(state) do
    # The return value is the whole exposition text and is deliberately dropped —
    # we want the side effect (aggregate + delete), not the numbers.
    _ = scrape_metrics(state)
    :ok
  rescue
    error ->
      # Never take the supervisor down over housekeeping: a missing aggregator is
      # a misconfiguration to report, not a reason to restart the tree.
      Logger.warning("distribution prune failed: #{Exception.message(error)}")
      :error
  end

  defp scrape_metrics(%{aggregator: aggregator, scrape_fun: scrape_fun}) do
    scrape_fun.(aggregator)
  end

  defp schedule(state) do
    Process.send_after(self(), :prune, state.tick)
    state
  end

  # Monotonic: this measures an elapsed interval, and a clock adjustment must not
  # make the endpoint look freshly scraped (or ancient).
  defp now_ms, do: System.monotonic_time(:millisecond)
end
