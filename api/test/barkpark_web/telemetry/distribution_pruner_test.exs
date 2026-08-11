defmodule BarkparkWeb.Telemetry.DistributionPrunerTest do
  # async: false — drives the app-wide `:barkpark_metrics` aggregator and its
  # ETS table, same reason as BarkparkWeb.TelemetryTest.
  use ExUnit.Case, async: false

  alias BarkparkWeb.Telemetry.DistributionPruner

  @aggregator :barkpark_metrics
  # Core names the distribution table `<aggregator>_dist`. This is the table the
  # whole module exists to bound; if the naming ever changes upstream, this test
  # goes red rather than the pruner going quietly useless.
  @dist_table :barkpark_metrics_dist

  setup do
    # Start an ISOLATED pruner rather than leaning on the one in the supervision
    # tree: `last_scrape` is per-process state, and a test that mutated the real
    # one would leak into every test that ran after it.
    pid =
      start_supervised!(
        {DistributionPruner,
         [
           name: :pruner_under_test,
           aggregator: @aggregator,
           # Long enough that no timer fires during the test — every prune here
           # is driven explicitly through :prune_now.
           tick: :timer.hours(1),
           idle_after: :timer.minutes(5)
         ]},
        id: :pruner_under_test
      )

    # The supervision tree's own pruner registers under the module name, so the
    # isolated one has to be addressed by pid.
    {:ok, pruner: pid}
  end

  defp emit_queries(n) do
    for _ <- 1..n do
      :telemetry.execute(
        [:barkpark, :repo, :query],
        %{
          total_time: System.convert_time_unit(12, :millisecond, :native),
          queue_time: System.convert_time_unit(1, :millisecond, :native),
          query_time: System.convert_time_unit(10, :millisecond, :native),
          decode_time: System.convert_time_unit(1, :millisecond, :native),
          idle_time: System.convert_time_unit(3, :millisecond, :native)
        },
        %{}
      )
    end
  end

  defp rows, do: :ets.info(@dist_table, :size)

  describe "an unscraped instance stays bounded" do
    test "a tick folds the accumulated samples away", %{pruner: pruner} do
      # Clear whatever earlier tests left behind, so the assertion is about the
      # rows THIS test created.
      _ = TelemetryMetricsPrometheus.Core.scrape(@aggregator)

      emit_queries(500)
      before = rows()

      assert before >= 500,
             "expected the distribution table to hold a row per observation, saw #{before}"

      assert GenServer.call(pruner, :prune_now),
             "pruner declined to prune an instance nobody has ever scraped"

      after_prune = rows()

      assert after_prune < before,
             "table did not shrink: #{before} -> #{after_prune}"
    end
  end

  describe "an instance WITH a Prometheus attached is left alone" do
    test "a recent external scrape suppresses the tick", %{pruner: pruner} do
      _ = TelemetryMetricsPrometheus.Core.scrape(@aggregator)

      # MetricsController.scrape/2 routes every real request through this call.
      assert is_binary(DistributionPruner.scrape(pruner))

      emit_queries(500)
      before = rows()

      refute GenServer.call(pruner, :prune_now),
             "pruner ran despite an external scrape having just completed"

      assert rows() == before,
             "table changed despite the prune being suppressed"
    end
  end

  describe "scrape serialization" do
    test "a timer tick cannot overlap an external scrape" do
      test_pid = self()

      scrape_fun = fn _aggregator ->
        send(test_pid, {:scrape_started, self()})

        receive do
          :finish_scrape -> "serialized metrics"
        end
      end

      pruner =
        start_supervised!(
          {DistributionPruner,
           [
             name: :serial_pruner_under_test,
             aggregator: @aggregator,
             scrape_fun: scrape_fun,
             tick: :timer.hours(1),
             idle_after: :timer.minutes(5)
           ]},
          id: :serial_pruner_under_test
        )

      external = Task.async(fn -> DistributionPruner.scrape(pruner) end)
      assert_receive {:scrape_started, ^pruner}

      send(pruner, :prune)
      refute_receive {:scrape_started, ^pruner}, 50

      send(pruner, :finish_scrape)
      assert Task.await(external) == "serialized metrics"

      # The queued timer runs only after the external scrape records its fresh
      # timestamp, so it is suppressed instead of starting a second Core fold.
      refute_receive {:scrape_started, ^pruner}, 50
    end
  end
end
