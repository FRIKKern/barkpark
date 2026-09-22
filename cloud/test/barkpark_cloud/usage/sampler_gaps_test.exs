defmodule BarkparkCloud.Usage.SamplerGapsTest do
  @moduledoc """
  dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick — the missed-tick reporter.

  The defect: `Oban.Plugins.Cron` (OSS) inserts only for a minute a RUNNING node
  observes and never backfills, so a control-plane cutover crossing a cron
  boundary eats the tick and leaves NO row anywhere — the loss is visible only
  as a hole in `usage_samples`, and a hole reads exactly like a STOPPED worker.

  These arms prove the MECHANISM (there is no way to run a real cron tick in a
  test): the expected instants are derived from the live crontab, the coverage
  rule is exact at both ends, and the report fires on a hole while staying
  silent on a complete series, an empty fleet and an unscheduled worker.

  Every window here sits in 2019 — a fixed, long-dead era no other suite writes
  into — and every read is bounded by it, so nothing in this file can see or be
  confused by another agent's rows in the shared test database.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Usage.{Sample, SamplerGaps}
  alias BarkparkCloud.Workers.UsageSamplerWorker

  # The incident's own shape, moved into the dead era: the 15-minute series
  # 23:22 / 23:37 / [NOTHING] / 00:07 — one eaten tick at 23:52.
  @window_start ~U[2019-03-04 23:15:00.000000Z]
  @window_end ~U[2019-03-05 00:10:00.000000Z]

  defp instance_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Gaps #{n}", slug: "gaps-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "gapbp-#{n}"})
    bp
  end

  defp sample_at(bp, %DateTime{} = at) do
    %Sample{}
    |> Sample.changeset(%{barkpark_id: bp.id, envelope: %{meters: %{}}, measured_at: at})
    |> Repo.insert!()
  end

  describe "cron_minutes/1 — DERIVED, never re-spelled" do
    test "reads the sampler's minutes out of the live Oban crontab" do
      # The anti-drift arm. If the crontab cadence changes and this module kept
      # a hardcoded 7,22,37,52, it would manufacture false holes on every tick —
      # the exact failure mode the row is about. Asserting against the CONFIG
      # (not a literal) is what makes that impossible.
      configured =
        :barkpark_cloud
        |> Application.get_env(Oban, [])
        |> Keyword.get(:plugins, [])
        |> Enum.flat_map(fn
          {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
          _ -> []
        end)
        |> Enum.find(fn
          {_expr, UsageSamplerWorker} -> true
          {_expr, UsageSamplerWorker, _opts} -> true
          _ -> false
        end)

      assert {expr, UsageSamplerWorker} = configured
      assert {:ok, minutes} = SamplerGaps.cron_minutes()
      assert minutes == SamplerGaps.parse_minutes(expr)
      # Non-vacuity: the derivation actually produced a cadence, not [].
      assert length(minutes) >= 1
    end

    test "CONTROL — a worker with no crontab entry is :unscheduled, never a hole" do
      assert {:error, :unscheduled} = SamplerGaps.cron_minutes(__MODULE__)
    end
  end

  describe "parse_minutes/1" do
    test "comma list, step, range and wildcard" do
      assert SamplerGaps.parse_minutes("7,22,37,52 * * * *") == [7, 22, 37, 52]
      assert SamplerGaps.parse_minutes("*/15 * * * *") == [0, 15, 30, 45]
      assert SamplerGaps.parse_minutes("5-8 * * * *") == [5, 6, 7, 8]
      assert SamplerGaps.parse_minutes("0-59/20 * * * *") == [0, 20, 40]
      assert SamplerGaps.parse_minutes("* * * * *") == Enum.to_list(0..59)
    end

    test "CONTROL — an unparsable expression expands to [], so it cannot invent ticks" do
      assert SamplerGaps.parse_minutes("@daily") == []
      assert SamplerGaps.parse_minutes("nonsense") == []
      assert SamplerGaps.parse_minutes("*/0 * * * *") == []
      assert SamplerGaps.parse_minutes(nil) == []
    end
  end

  describe "expected_ticks/2" do
    test "reconstructs every crontab instant in the half-open window" do
      assert {:ok, ticks} = SamplerGaps.expected_ticks(@window_start, @window_end)

      assert Enum.map(ticks, &{&1.hour, &1.minute}) == [
               {23, 22},
               {23, 37},
               {23, 52},
               {0, 7}
             ]

      # Half-open on the right: the window_end minute is never included.
      assert {:ok, exclusive} =
               SamplerGaps.expected_ticks(@window_start, ~U[2019-03-04 23:37:00.000000Z])

      assert Enum.map(exclusive, & &1.minute) == [22]
    end
  end

  describe "missed/2 — the RED arm" do
    test "names the eaten tick and nothing else" do
      bp = instance_fixture()

      for at <- [
            ~U[2019-03-04 23:22:01.000000Z],
            ~U[2019-03-04 23:37:02.000000Z],
            # 23:52 eaten by the cutover — no row at all, the whole point
            ~U[2019-03-05 00:07:03.000000Z]
          ] do
        sample_at(bp, at)
      end

      assert {:ok, [missed]} = SamplerGaps.missed(@window_start, @window_end)
      assert {missed.hour, missed.minute} == {23, 52}
    end

    test "CONTROL — a complete series has no holes" do
      bp = instance_fixture()

      for at <- [
            ~U[2019-03-04 23:22:01.000000Z],
            ~U[2019-03-04 23:37:02.000000Z],
            ~U[2019-03-04 23:52:04.000000Z],
            ~U[2019-03-05 00:07:03.000000Z]
          ] do
        sample_at(bp, at)
      end

      assert {:ok, []} = SamplerGaps.missed(@window_start, @window_end)
    end

    test "a sample from a LATER interval does not launder an earlier eaten tick" do
      # The upper-bound arm, and the reason coverage is [T, next_tick) rather
      # than "any sample at or after T". Drop the 23:37 row entirely; the next
      # sample is 23:52:30, which belongs to the 23:52 interval. Under a naive
      # at-or-after rule 23:37 would read as COVERED by that row and `missed`
      # would come back [] — the hole would vanish into its successor.
      bp = instance_fixture()
      sample_at(bp, ~U[2019-03-04 23:22:01.000000Z])
      sample_at(bp, ~U[2019-03-04 23:52:30.000000Z])
      sample_at(bp, ~U[2019-03-05 00:07:03.000000Z])

      assert {:ok, missed} = SamplerGaps.missed(@window_start, @window_end)
      assert Enum.map(missed, &{&1.hour, &1.minute}) == [{23, 37}]

      # Non-vacuity: the 23:52 row really is there and really does cover 23:52.
      refute Enum.any?(missed, &(&1.minute == 52))
    end

    test "a sample for ANY instance covers the tick — this is a series question, not a per-box one" do
      a = instance_fixture()
      b = instance_fixture()
      sample_at(a, ~U[2019-03-04 23:22:01.000000Z])
      sample_at(b, ~U[2019-03-04 23:37:02.000000Z])
      sample_at(a, ~U[2019-03-04 23:52:01.000000Z])
      sample_at(b, ~U[2019-03-05 00:07:01.000000Z])

      assert {:ok, []} = SamplerGaps.missed(@window_start, @window_end)
    end
  end

  describe "report/2" do
    test "logs one attributable warning per eaten tick" do
      bp = instance_fixture()
      sample_at(bp, ~U[2019-03-04 23:22:01.000000Z])
      sample_at(bp, ~U[2019-03-04 23:37:02.000000Z])
      sample_at(bp, ~U[2019-03-05 00:07:03.000000Z])

      # report/2's window is [now - lookback, now); 00:10 with the 31-minute
      # lookback opens it at 23:39 — which would cut 23:22/23:37 out, so drive
      # the same accounting through the seam report/2 itself uses and assert the
      # log on a `now` whose own window holds the hole.
      log =
        capture_log(fn ->
          assert %{reported: true, reason: nil, expected: expected, missed: [tick]} =
                   SamplerGaps.report(~U[2019-03-05 00:10:00.000000Z], swept: 2)

          assert expected >= 2
          assert {tick.hour, tick.minute} == {23, 52}
        end)

      assert log =~ "usage_sampler_missed_tick"
      assert log =~ "at=2019-03-04T23:52:00"
      assert log =~ "cause=no_node_observed_the_cron_minute"
    end

    test "CONTROL — a normal tick is SILENT" do
      bp = instance_fixture()
      # Fill every expected instant inside report/2's own 31-minute window.
      now = ~U[2019-03-05 00:10:00.000000Z]
      {:ok, ticks} = SamplerGaps.expected_ticks(DateTime.add(now, -31 * 60, :second), now)
      assert ticks != []
      for t <- ticks, do: sample_at(bp, DateTime.add(t, 1, :second))

      log =
        capture_log(fn ->
          assert %{reported: true, missed: []} = SamplerGaps.report(now, swept: 1)
        end)

      refute log =~ "usage_sampler_missed_tick"
    end

    test "CONTROL — an empty checkable fleet is SILENT, not a wall of holes" do
      log =
        capture_log(fn ->
          assert %{reported: false, reason: :no_checkable_instances, missed: []} =
                   SamplerGaps.report(~U[2019-03-05 00:10:00.000000Z], swept: 0)
        end)

      refute log =~ "usage_sampler_missed_tick"
    end
  end
end
