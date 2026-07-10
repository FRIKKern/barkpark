defmodule BarkparkWeb.RequestStatsTest do
  use ExUnit.Case, async: false

  alias BarkparkWeb.RequestStats

  describe "compute/4 — window math" do
    test "empty window: req_per_s 0.0 and p95_ms nil (never a fake 0ms)" do
      now = 100_000

      assert %{req_per_s: +0.0, p95_ms: nil, window_s: 60} =
               RequestStats.compute([], now, now - 60_000, 60_000)
    end

    test "count / elapsed over a full window" do
      now = 1_000_000
      started = now - 120_000
      # 120 samples spread across the last 60s -> 120 / 60 = 2.0 req/s.
      samples = for i <- 0..119, do: {now - i * 500, 5.0}
      assert %{req_per_s: 2.0, p95_ms: 5} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "fresh boot divides by elapsed uptime, not the full window" do
      now = 5_000
      started = now - 5_000
      # 10 requests, box only alive 5s -> 10 / 5 = 2.0, not 10 / 60.
      samples = for i <- 0..9, do: {now - i * 100, 3.0}
      assert %{req_per_s: 2.0} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "samples older than the window are excluded from rate and p95" do
      now = 1_000_000
      started = now - 300_000
      in_window = for i <- 0..59, do: {now - i * 1000, 10.0}
      # 1000 stale samples with a huge duration must not leak into either meter.
      stale = for i <- 0..999, do: {now - 90_000 - i, 9999.0}

      %{req_per_s: rps, p95_ms: p95} =
        RequestStats.compute(in_window ++ stale, now, started, 60_000)

      # 60 in-window samples over a full 60s window -> 1.0 req/s.
      assert rps == 1.0
      # p95 reflects only the in-window 10ms samples, not the 9999ms stale ones.
      assert p95 == 10
    end

    test "p95_ms rounds the nearest-rank percentile to an integer" do
      now = 1_000_000
      started = now - 120_000
      # Durations 1..100 ms; nearest-rank p95 of 100 sorted values is the 95th.
      samples = for d <- 1..100, do: {now - 1000, d / 1.0}
      assert %{p95_ms: 95} = RequestStats.compute(samples, now, started, 60_000)
    end
  end

  describe "percentile/2 — nearest rank" do
    test "empty list is nil" do
      assert RequestStats.percentile([], 95) == nil
    end

    test "single sample is its own p95" do
      assert RequestStats.percentile([42.0], 95) == 42.0
    end

    test "p95 of 1..100 is the 95th value" do
      assert RequestStats.percentile(Enum.map(1..100, &(&1 * 1.0)), 95) == 95.0
    end

    test "p95 of a short list clamps to the top rank" do
      # ceil(0.95 * 10) = 10 -> the max element.
      assert RequestStats.percentile([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0], 95) ==
               10.0
    end
  end

  describe "end-to-end: telemetry event -> ETS -> stats/1" do
    setup do
      table = :"req_stats_test_#{System.unique_integer([:positive])}"
      name = :"req_stats_proc_#{System.unique_integer([:positive])}"
      pid = start_supervised!({RequestStats, name: name, table: table})
      %{name: name, table: table, pid: pid}
    end

    test "a fresh aggregator reports the honest empty window", %{name: name} do
      assert %{req_per_s: +0.0, p95_ms: nil, window_s: 60} = RequestStats.stats(name)
    end

    test "emitted [:phoenix, :endpoint, :stop] events feed the window", %{
      name: name,
      table: table
    } do
      # Emit known durations (ms -> native) straight through the handler this
      # instance attached; assert both meters move off empty.
      for ms <- [10, 20, 30, 40, 50] do
        native = System.convert_time_unit(ms, :millisecond, :native)

        RequestStats.handle_event([:phoenix, :endpoint, :stop], %{duration: native}, %{}, %{
          table: table
        })
      end

      %{req_per_s: rps, p95_ms: p95, window_s: 60} = RequestStats.stats(name)
      assert rps > 0.0
      # p95 of [10,20,30,40,50] nearest-rank (ceil(0.95*5)=5) -> 50ms.
      assert p95 == 50
    end
  end
end
