defmodule BarkparkWeb.RequestStatsTest do
  use ExUnit.Case, async: false

  alias BarkparkWeb.RequestStats

  describe "compute/4 — window math" do
    test "empty window: req_per_s 0.0, p95_ms nil, err_5xx_per_s nil (never fake zeros)" do
      now = 100_000

      assert %{req_per_s: +0.0, p95_ms: nil, err_5xx_per_s: nil, window_s: 60} =
               RequestStats.compute([], now, now - 60_000, 60_000)
    end

    test "count / elapsed over a full window" do
      now = 1_000_000
      started = now - 120_000
      # 120 samples spread across the last 60s -> 120 / 60 = 2.0 req/s.
      samples = for i <- 0..119, do: {now - i * 500, 5.0, 200}
      assert %{req_per_s: 2.0, p95_ms: 5} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "fresh boot divides by elapsed uptime, not the full window" do
      now = 5_000
      started = now - 5_000
      # 10 requests, box only alive 5s -> 10 / 5 = 2.0, not 10 / 60.
      samples = for i <- 0..9, do: {now - i * 100, 3.0, 200}
      assert %{req_per_s: 2.0} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "samples older than the window are excluded from rate and p95" do
      now = 1_000_000
      started = now - 300_000
      in_window = for i <- 0..59, do: {now - i * 1000, 10.0, 200}
      # 1000 stale samples with a huge duration must not leak into either meter.
      stale = for i <- 0..999, do: {now - 90_000 - i, 9999.0, 500}

      %{req_per_s: rps, p95_ms: p95, err_5xx_per_s: err5xx} =
        RequestStats.compute(in_window ++ stale, now, started, 60_000)

      # 60 in-window samples over a full 60s window -> 1.0 req/s.
      assert rps == 1.0
      # p95 reflects only the in-window 10ms samples, not the 9999ms stale ones.
      assert p95 == 10
      # The 1000 stale samples are ALL 500s. None of them may leak into the error
      # rate: an outage that ended two minutes ago is not happening now.
      assert err5xx == +0.0
    end

    test "p95_ms rounds the nearest-rank percentile to an integer" do
      now = 1_000_000
      started = now - 120_000
      # Durations 1..100 ms; nearest-rank p95 of 100 sorted values is the 95th.
      samples = for d <- 1..100, do: {now - 1000, d / 1.0, 200}
      assert %{p95_ms: 95} = RequestStats.compute(samples, now, started, 60_000)
    end
  end

  describe "compute/4 — err_5xx_per_s (D48 honest meter, D75 widening)" do
    test "an EMPTY window is nil, never 0.0 — 'no samples' is not 'no errors'" do
      now = 100_000
      assert %{err_5xx_per_s: nil} = RequestStats.compute([], now, now - 60_000, 60_000)
    end

    test "a mixed 2xx/5xx window reports the 5xx rate over the same elapsed seconds" do
      now = 1_000_000
      started = now - 300_000
      # 60s window, 600 requests (10 req/s) of which 12 are 500s -> 0.2 5xx/s.
      ok = for i <- 0..587, do: {now - rem(i, 60) * 1000, 5.0, 200}
      errs = for i <- 0..11, do: {now - i * 5000, 50.0, 500}

      assert %{req_per_s: 10.0, err_5xx_per_s: 0.2} =
               RequestStats.compute(ok ++ errs, now, started, 60_000)
    end

    test "a measured window with zero 5xx is a real 0.0, distinct from the empty nil" do
      now = 1_000_000
      started = now - 300_000
      samples = for i <- 0..59, do: {now - i * 1000, 5.0, 200}

      assert %{err_5xx_per_s: +0.0} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "only 500..599 counts: 4xx, 3xx and an unknown nil status are not errors here" do
      now = 1_000_000
      started = now - 300_000

      samples = [
        {now - 1000, 5.0, 200},
        {now - 1000, 5.0, 301},
        {now - 1000, 5.0, 404},
        {now - 1000, 5.0, 422},
        {now - 1000, 5.0, nil},
        {now - 1000, 5.0, 499},
        {now - 1000, 5.0, 600},
        {now - 1000, 5.0, 503}
      ]

      # Exactly one of the eight is a 5xx, over a full 60s elapsed window.
      assert %{err_5xx_per_s: 0.017} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "a fresh boot divides 5xx by lived uptime, not a window it has not lived" do
      now = 5_000
      started = now - 5_000
      # 5 requests in 5s, all 500 -> 1.0 5xx/s, not 5/60.
      samples = for i <- 0..4, do: {now - i * 100, 5.0, 500}

      assert %{err_5xx_per_s: 1.0} = RequestStats.compute(samples, now, started, 60_000)
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
      assert %{req_per_s: +0.0, p95_ms: nil, err_5xx_per_s: nil, window_s: 60} =
               RequestStats.stats(name)
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

    test "the conn's status rides the SAME event into the 5xx rate", %{
      name: name,
      table: table
    } do
      # Phoenix hands the handler the conn as metadata; this is exactly the shape
      # the endpoint emits, and the status is what the old handler discarded.
      for status <- [200, 200, 200, 500, 503] do
        native = System.convert_time_unit(10, :millisecond, :native)

        RequestStats.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: native},
          %{conn: %Plug.Conn{status: status}},
          %{table: table}
        )
      end

      %{req_per_s: rps, err_5xx_per_s: err5xx} = RequestStats.stats(name)
      assert rps > 0.0
      # 2 of the 5 samples are 5xx; the rate is over lived uptime, so assert the
      # ratio rather than a wall-clock-dependent absolute.
      assert err5xx > 0.0
      assert_in_delta err5xx / rps, 0.4, 0.001
    end

    test "a metadata shape without a conn never counts as an error", %{
      name: name,
      table: table
    } do
      native = System.convert_time_unit(10, :millisecond, :native)

      RequestStats.handle_event([:phoenix, :endpoint, :stop], %{duration: native}, %{}, %{
        table: table
      })

      %{err_5xx_per_s: err5xx} = RequestStats.stats(name)
      # Measured window, unknown status: a real 0.0 (not an error, not a nil).
      assert err5xx == +0.0
    end

    test "the served route body carries err_5xx_per_s as a real JSON key", %{name: name} do
      # The controller is `json(conn, RequestStats.stats())` — encoding the map is
      # the route's whole body, so encoding it here pins the wire contract the Go
      # agent decodes (and pins that an empty window serialises as `null`).
      body = Jason.encode!(RequestStats.stats(name))

      assert body =~ ~s("err_5xx_per_s":null)
      assert body =~ ~s("req_per_s")
      assert body =~ ~s("p95_ms":null)
      assert body =~ ~s("window_s":60)

      decoded = Jason.decode!(body)
      assert Map.has_key?(decoded, "err_5xx_per_s")
      assert decoded["err_5xx_per_s"] == nil
    end
  end
end
