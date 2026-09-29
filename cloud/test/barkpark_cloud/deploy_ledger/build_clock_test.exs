defmodule BarkparkCloud.DeployLedger.BuildClockTest do
  @moduledoc """
  The build clock's reader — deploy-reliability W12, charter D180.

  Two things are on trial, and the second is the whole point:

    * the reader reports build duration off console stage timestamps and SAYS
      which of the two intervals it measured (`:measured`, `:reading`); and
    * the naive `BUILD started → done` interval and the un-overlapped one
      DIFFER on a contended fixture, with both numbers asserted — so the 4.2x
      queue-wait trap cannot come back silently. Delete the `max(s, earliest)`
      in `BuildClock.unoverlap/2` and `"the two intervals differ on a contended
      box"` reds.

  The discrimination runs BOTH ways. A reader that always shrank its input
  would pass the contended arm and mean nothing, so `"an uncontended box shows
  no difference"` pins the two series EQUAL when no build ever waits. The
  difference has to come from contention or the instrument is measuring itself.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.DeployLedger.BuildClock
  alias BarkparkCloud.Registry

  @t0 ~U[2026-08-07 00:00:00Z]

  defp at(seconds), do: @t0 |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()

  # One deployment's console: a BUILD that opened at `from` and closed at `to`.
  defp console(from, to) do
    [
      %{"stage" => "PLAN", "status" => "started", "at" => at(from - 1)},
      %{"stage" => "PLAN", "status" => "done", "at" => at(from)},
      %{"stage" => "BUILD", "status" => "started", "at" => at(from)},
      %{"stage" => "BUILD", "status" => "done", "at" => at(to)}
    ]
  end

  # THE CONTENDED FIXTURE — one box, BUILD_GATE_SLOTS=1, three overlapping
  # console BUILD spans. They cannot have compiled concurrently; the overlap IS
  # the queue wait.
  #
  #   A  0 ──────────── 30      compile 30s, wait  0s
  #   B     5 ───────────────── 65      compile 35s, wait 25s (behind A)
  #   C        10 ───────────────────── 100     compile 35s, wait 55s (behind B)
  defp contended, do: [console(0, 30), console(5, 65), console(10, 100)]

  describe "c0 — the reader names the interval it measured" do
    test "report/2 measures compile EXCLUDING the queue wait and says so" do
      report = BuildClock.report(contended())

      assert report.measured == :compile_excluding_queue_wait
      assert report.stage == "BUILD"
      assert report.slots == 1
      assert report.deployments == 3

      # The sentence a human reads names BOTH intervals and the reason they
      # differ, so a number lifted out of this map cannot lose its identity.
      assert report.reading =~ "compile_excluding_queue_wait"
      assert report.reading =~ "console_interval_ms"
      assert report.reading =~ "build_gate_acquire"
    end

    test "the report carries both series plus the wait itself, never a bare 'build duration'" do
      report = BuildClock.report(contended())

      assert Map.has_key?(report, :compile_ms)
      assert Map.has_key?(report, :console_interval_ms)
      assert Map.has_key?(report, :queue_wait_ms)
      refute Enum.any?(Map.keys(report), &(&1 == :build_duration_ms))
    end

    test "every row splits its span into exactly compile + wait" do
      rows = contended() |> BuildClock.build_intervals() |> BuildClock.unoverlap(1)

      assert length(rows) == 3

      for row <- rows do
        assert row.compile_ms + row.queue_wait_ms == row.end_ms - row.start_ms
        assert row.compile_ms >= 0
        assert row.queue_wait_ms >= 0
      end
    end
  end

  describe "c1 — the naive and un-overlapped intervals differ, with both numbers pinned" do
    test "the two intervals differ on a contended box" do
      report = BuildClock.report(contended(), slots: 1)

      # Naive: 30s, 60s, 90s. p50 = 60s. This is the trap's number.
      assert report.console_interval_ms == %{n: 3, p50: 60_000, p95: 90_000, max: 90_000}

      # Un-overlapped: 30s, 35s, 35s. p50 = 35s.
      assert report.compile_ms == %{n: 3, p50: 35_000, p95: 35_000, max: 35_000}

      # THE ASSERTION THE TRAP HAS TO GET PAST.
      refute report.compile_ms.p50 == report.console_interval_ms.p50
      assert report.compile_ms.p50 < report.console_interval_ms.p50
      assert report.inflation == 1.71

      # The removed part is not discarded — it is the slot queue-depth signal.
      assert report.queue_wait_ms == %{n: 3, p50: 25_000, p95: 55_000, max: 55_000}
    end

    test "un-overlapped compile totals the union of the spans — the box was busy 0→100s, not 180s" do
      rows = contended() |> BuildClock.build_intervals() |> BuildClock.unoverlap(1)

      assert rows |> Enum.map(& &1.compile_ms) |> Enum.sum() == 100_000
      assert rows |> Enum.map(&(&1.end_ms - &1.start_ms)) |> Enum.sum() == 180_000
    end

    test "an uncontended box shows no difference — the gap comes from contention, not the reader" do
      # CONTROL. Same three durations (30s/60s/90s), never overlapping.
      uncontended = [console(0, 30), console(100, 160), console(200, 290)]
      report = BuildClock.report(uncontended, slots: 1)

      assert report.compile_ms == report.console_interval_ms
      assert report.queue_wait_ms == %{n: 3, p50: 0, p95: 0, max: 0}
      assert report.inflation == 1.0
    end

    test "a second slot absorbs one of the two waits — the model tracks BUILD_GATE_SLOTS" do
      report = BuildClock.report(contended(), slots: 2)

      # A and B now compile side by side (B waits 0); C still queues behind A,
      # which frees first at 30s.
      rows = contended() |> BuildClock.build_intervals() |> BuildClock.unoverlap(2)
      assert Enum.map(rows, & &1.queue_wait_ms) == [0, 0, 20_000]
      assert report.queue_wait_ms.max == 20_000
    end
  end

  describe "pairing — the same contract as the registry fold it was copied from" do
    test "a failed BUILD discards its open attempt; a re-open supersedes it" do
      console = [
        %{"stage" => "BUILD", "status" => "started", "at" => at(0)},
        %{"stage" => "BUILD", "status" => "failed", "at" => at(10)},
        %{"stage" => "BUILD", "status" => "started", "at" => at(20)},
        %{"stage" => "BUILD", "status" => "started", "at" => at(25)},
        %{"stage" => "BUILD", "status" => "done", "at" => at(55)}
      ]

      assert BuildClock.build_intervals([console]) == [
               %{start_ms: unix_ms(25), end_ms: unix_ms(55)}
             ]
    end

    test "a negative pair is dropped, never clamped, and other stages are ignored" do
      console = [
        %{"stage" => "BUILD", "status" => "started", "at" => at(60)},
        %{"stage" => "BUILD", "status" => "done", "at" => at(10)},
        %{"stage" => "HEALTH", "status" => "started", "at" => at(70)},
        %{"stage" => "HEALTH", "status" => "done", "at" => at(80)}
      ]

      assert BuildClock.build_intervals([console]) == []
      assert BuildClock.report([console]).compile_ms == %{n: 0, p50: nil, p95: nil, max: nil}
      assert BuildClock.report([console]).inflation == nil
    end

    test "atom keys and a DateTime `at` parse identically to string keys and an iso8601 `at`" do
      atom_keyed = [
        %{stage: "BUILD", status: "started", at: DateTime.add(@t0, 0, :second)},
        %{stage: "BUILD", status: "done", at: DateTime.add(@t0, 30, :second)}
      ]

      assert BuildClock.build_intervals([atom_keyed]) ==
               BuildClock.build_intervals([console(0, 30)])
    end

    test "agrees with Registry.deploy_stage_estimates_from_consoles/1 on the same fixture" do
      # The parse is a COPY of that function's private fold (registry.ex has two
      # open PRs against it, so it was copied rather than exported). This pins
      # the copy to its source: same consoles in, same BUILD sample count and
      # same median out. Uniform 30s spans so neither reader's percentile or
      # trim policy can be what makes them agree.
      consoles =
        for i <- 0..39 do
          from = i * 120
          console(from, from + 30)
        end ++
          [
            [
              %{stage: "BUILD", status: "started", at: DateTime.add(@t0, 9_000, :second)},
              %{stage: "BUILD", status: "done", at: DateTime.add(@t0, 9_030, :second)}
            ]
          ]

      registry = Registry.deploy_stage_estimates_from_consoles(consoles)
      mine = BuildClock.report(consoles)

      assert registry.meta.samples["BUILD"] == 41
      assert mine.console_interval_ms.n == 41

      assert registry.deploy["BUILD"] == 30_000
      assert mine.console_interval_ms.p50 == 30_000

      # And with no contention in this fixture, the reader's own number matches
      # too — the two readers disagree only where a queue wait exists.
      assert mine.compile_ms.p50 == 30_000
    end
  end

  defp unix_ms(seconds),
    do: @t0 |> DateTime.add(seconds, :second) |> DateTime.to_unix(:millisecond)
end
