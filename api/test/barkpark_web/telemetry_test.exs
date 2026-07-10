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
