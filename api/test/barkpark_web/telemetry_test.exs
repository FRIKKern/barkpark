defmodule BarkparkWeb.TelemetryTest do
  # async: false — asserts against the process-global telemetry handler table
  # and the app-wide `:barkpark_metrics` Prometheus aggregator.
  use ExUnit.Case, async: false

  alias BarkparkWeb.Telemetry

  @aggregator :barkpark_metrics

  describe "prometheus_metrics/0 — the prod-reachable subset" do
    test "answers each NAMED production question: p95 Ecto query + VM memory are present" do
      events = Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name)

      # "what is p95 Ecto query time?" — the repo query event MUST be consumed.
      assert [:barkpark, :repo, :query] in events,
             "prometheus_metrics/0 dropped the Ecto query metric — p95 query time goes blind"

      # "is VM memory climbing?" — the documented OOM scar. MUST be consumed.
      assert [:vm, :memory] in events,
             "prometheus_metrics/0 dropped vm.memory — a leak is invisible until OOM"
    end
  end

  describe "reporter is attached to [:barkpark, :repo, :query] (regression guard)" do
    test "a Prometheus handler is attached to the repo query event, not dev-gated" do
      # The reporter is a child of BarkparkWeb.Telemetry's supervisor with NO
      # dev_routes gate (unlike LiveDashboard). If a future change moves it
      # behind dev_routes — the exact hole this task fixed — no handler is
      # attached in prod and this assertion fails.
      handlers = :telemetry.list_handlers([:barkpark, :repo, :query])

      assert Enum.any?(handlers, fn h ->
               inspect(h.id) =~ "barkpark_metrics" or inspect(h.config) =~ "barkpark_metrics"
             end),
             "no :barkpark_metrics handler on [:barkpark, :repo, :query] — the Prometheus reporter is not attached"
    end
  end

  describe "metrics leave the floor (measurement)" do
    test "emitting a repo query + vm.memory yields non-zero p95 basis and a memory reading" do
      before = Telemetry |> scrape() |> query_count()

      # A synthetic 42ms Ecto query and a VM-memory reading, straight into the
      # live aggregator via the same events prometheus_metrics/0 subscribes to.
      forty_two_ms = System.convert_time_unit(42, :millisecond, :native)

      :telemetry.execute(
        [:barkpark, :repo, :query],
        %{
          total_time: forty_two_ms,
          queue_time: System.convert_time_unit(3, :millisecond, :native)
        },
        %{}
      )

      :telemetry.execute([:vm, :memory], %{total: 20_000_000}, %{})

      scraped = scrape(Telemetry)

      # p95 basis: the total_time histogram count strictly increased — the value
      # left the floor (Prometheus derives p95 via histogram_quantile over these
      # buckets; a populated histogram is the non-null p95 basis).
      assert query_count(scraped) > before,
             "repo.query histogram did not record the emitted sample"

      assert scraped =~ "barkpark_repo_query_total_time_bucket"

      # VM memory reading is present and non-zero (not the honest floor).
      # (Core scales by unit but keeps the event-derived name — no _kilobytes suffix.)
      assert scraped =~ "vm_memory_total"

      assert Regex.match?(~r/vm_memory_total(?:\{[^}]*\})?\s+[1-9]/, scraped),
             "vm_memory_total gauge is missing or zero — no memory reading"
    end
  end

  describe "vm.memory breakdown — WHICH subsystem grows" do
    test "each per-subsystem gauge renders under its expected NAME, present and non-zero" do
      # The total answers "is memory climbing?"; these answer "climbing WHERE?".
      # telemetry_poller already emits the full :erlang.memory/0 map on
      # [:vm, :memory] every 10s — this asserts we actually SUBSCRIBE to the
      # breakdown keys, and that the dot->underscore rendering is what we think
      # it is (asserted, never assumed: Core derives the exposed name from the
      # event + measurement, and the unit scaling adds NO suffix).
      :telemetry.execute(
        [:vm, :memory],
        %{
          total: 20_000_000,
          processes: 8_000_000,
          binary: 3_000_000,
          ets: 2_000_000,
          code: 5_000_000
        },
        %{}
      )

      scraped = scrape(Telemetry)

      for name <- ~w(vm_memory_processes vm_memory_binary vm_memory_ets vm_memory_code) do
        assert scraped =~ name,
               "#{name} is not exposed — the memory breakdown cannot name the growing subsystem"

        assert Regex.match?(~r/#{name}(?:\{[^}]*\})?\s+[1-9]/, scraped),
               "#{name} gauge is zero or unparsable — no reading for that subsystem"
      end
    end

    test "every BEAM memory gauge shares vm.memory.total's kilobyte unit (D64 unit discipline)" do
      # Core scales by :unit but keeps the event-derived name, so NONE of these
      # carry a _bytes/_kilobytes suffix on the wire. A byte-valued gauge beside
      # a kilobyte-valued one — both unsuffixed — is a 1024x error that reads as
      # a memory leak. Either all share the unit, or a gauge names its own.
      for metric <- Telemetry.prometheus_metrics(),
          metric.event_name == [:vm, :memory] do
        rendered = Enum.map_join(metric.name, "_", &Atom.to_string/1)

        # Telemetry.Metrics normalises `unit: {:byte, :kilobyte}` down to the
        # TARGET unit (:kilobyte) and folds the ratio into :measurement.
        assert metric.unit == :kilobyte or String.ends_with?(rendered, "_bytes"),
               "#{rendered} is a BEAM memory gauge with neither the kilobyte unit of its " <>
                 "neighbours nor an explicit _bytes suffix — a 1024x unit trap"
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp scrape(_), do: TelemetryMetricsPrometheus.Core.scrape(@aggregator)

  # Sum of the repo.query total_time histogram `_count` samples in a scrape.
  defp query_count(scraped) do
    ~r/barkpark_repo_query_total_time_count(?:\{[^}]*\})?\s+(\d+)/
    |> Regex.scan(scraped)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    |> Enum.sum()
  end
end
