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

  ## Why this doesn't steal samples from a real scraper

  The naive fix — aggregate on a timer, unconditionally — would prune rows out
  from under an external Prometheus between its scrapes, quietly lowering the
  sample counts it sees. So this only acts when the endpoint looks UNUSED:
  `BarkparkWeb.MetricsController` reports each external scrape via
  `note_scrape/0`, and a tick prunes only if none has arrived within
  `:idle_after`. An instance with Prometheus attached never sees this process do
  anything; an instance without one stays flat.
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
  Records that an external scraper just read the endpoint.

  A cast, not a call: a scrape must never block on, or fail because of, this
  bookkeeping. Tolerates the pruner not running at all — some test setups start
  the aggregator on its own.
  """
  def note_scrape(server \\ __MODULE__) do
    GenServer.cast(server, :external_scrape)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      aggregator: Keyword.get(opts, :aggregator, @aggregator),
      tick: Keyword.get(opts, :tick, @tick),
      idle_after: Keyword.get(opts, :idle_after, @idle_after),
      # `nil` = nobody has ever scraped. The common case, and the one this
      # process exists for.
      last_scrape: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_cast(:external_scrape, state) do
    {:noreply, %{state | last_scrape: now_ms()}}
  end

  @impl true
  def handle_info(:prune, state) do
    if idle?(state), do: prune(state)
    {:noreply, schedule(state)}
  end

  # Exposed for the test: lets it drive a tick without waiting a minute.
  @impl true
  def handle_call(:prune_now, _from, state) do
    pruned? = idle?(state)
    if pruned?, do: prune(state)
    {:reply, pruned?, state}
  end

  defp idle?(%{last_scrape: nil}), do: true
  defp idle?(%{last_scrape: at, idle_after: idle_after}), do: now_ms() - at >= idle_after

  defp prune(%{aggregator: aggregator}) do
    # The return value is the whole exposition text and is deliberately dropped —
    # we want the side effect (aggregate + delete), not the numbers.
    _ = TelemetryMetricsPrometheus.Core.scrape(aggregator)
    :ok
  rescue
    error ->
      # Never take the supervisor down over housekeeping: a missing aggregator is
      # a misconfiguration to report, not a reason to restart the tree.
      Logger.warning("distribution prune failed: #{Exception.message(error)}")
      :error
  end

  defp schedule(state) do
    Process.send_after(self(), :prune, state.tick)
    state
  end

  # Monotonic: this measures an elapsed interval, and a clock adjustment must not
  # make the endpoint look freshly scraped (or ancient).
  defp now_ms, do: System.monotonic_time(:millisecond)
end
