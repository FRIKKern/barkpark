defmodule Barkpark.Search.CrystalPeriodKeyTest do
  @moduledoc """
  The reader's `period_start` must be the key the WRITER wrote.

  `Crystal` / `MergePattern` rows are looked up with `period_start == ^date`.
  A reader that spells that date differently from the crystallizer does not
  crash and does not warn — the query simply matches nothing and the caller
  answers 200 with an empty result. `Search.Synonyms` spelled the week key
  `Date.add(Date.utc_today(), -7)`, which coincides with the Monday-anchored key
  only ON MONDAYS.

  Note what that means for a test. A check that seeds at the writer's key and
  asks whether the DEFAULT finds it passes on broken code one day in seven — and
  the day that counts is the UTC one, since every key here comes from
  `Date.utc_today/0`. So the coverage is layered deliberately:

    * `period_start_for/2` is swept over a FIXED calendar week, which pins the
      divergence on all seven weekdays regardless of when the suite runs;
    * the evidence test drives an EXPLICIT window, so it reds every day;
    * the default-window test is the honest end-to-end one and is the only
      weekday-sensitive assertion here. It is marked as such below.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Search.{Crystal, Crystallizer, MergePattern, Synonyms}
  alias Barkpark.Repo

  @surface "documents"
  @scope "crystal-period-key"

  describe "period_start_for/2" do
    # A full calendar week. `crystallize_due/1` derives its week target as the
    # current week's Monday minus 7 (crystallizer.ex), and runs only when
    # day_of_week <= @backfill_days — but the KEY it writes is defined for every
    # day, which is exactly what a reader has to reproduce.
    test "the week key is the previous Monday on every day of the week" do
      # 2026-08-24 is a Monday; sweep it and the six days after it.
      monday = ~D[2026-08-24]
      expected = ~D[2026-08-17]

      for offset <- 0..6 do
        today = Date.add(monday, offset)

        assert Crystallizer.period_start_for("week", today) == expected,
               "week key drifted on #{Date.day_of_week(today)} " <>
                 "(#{today}): got #{Crystallizer.period_start_for("week", today)}"
      end
    end

    test "the naive `today - 7` spelling agrees with it on Mondays and NOWHERE else" do
      monday = ~D[2026-08-24]

      agreements =
        for offset <- 0..6,
            today = Date.add(monday, offset),
            Date.add(today, -7) == Crystallizer.period_start_for("week", today),
            do: Date.day_of_week(today)

      assert agreements == [1],
             "this is the whole defect: `Date.add(today, -7)` is the week key on " <>
               "Monday only, so a reader spelling it that way reads zero rows six " <>
               "days in seven — silently, at HTTP 200"
    end

    test "day and month keys, and the fallback for an unknown period" do
      today = ~D[2026-08-24]

      assert Crystallizer.period_start_for("day", today) == ~D[2026-08-23]
      assert Crystallizer.period_start_for(:day, today) == ~D[2026-08-23]
      assert Crystallizer.period_start_for("month", today) == ~D[2026-07-01]
      assert Crystallizer.period_start_for(:month, today) == ~D[2026-07-01]

      # Readers default `period` to "week", and an unrecognised period must land
      # on the same key rather than on a date nothing was ever written at.
      assert Crystallizer.period_start_for("fortnight", today) ==
               Crystallizer.period_start_for("week", today)
    end
  end

  describe "Synonyms.candidates/3" do
    defp merge_pattern!(period_start) do
      %MergePattern{}
      |> Ecto.Changeset.change(%{
        surface: @surface,
        scope: @scope,
        period: "week",
        period_start: period_start,
        from_fingerprint: "q:hero",
        to_fingerprint: "q:phoenix",
        pattern_type: "zero_to_hit",
        transition_count: 8,
        success_count: 6
      })
      |> Repo.insert!()
    end

    defp crystal!(period_start, query, attrs) do
      %Crystal{}
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            surface: @surface,
            scope: @scope,
            period: "week",
            period_start: period_start,
            query_normalized: query,
            filter_fingerprint: ""
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    # WEEKDAY-SENSITIVE BY CONSTRUCTION, and worth stating rather than hiding:
    # on a UTC Monday the old `Date.add(today, -7)` spelling IS the week key, so
    # this test would pass against the unfixed reader. The two tests above are
    # what make the proof day-independent; this one is the end-to-end check that
    # the default window actually reaches a written row.
    test "the default period_start is the crystallizer's key, not seven days ago" do
      merge_pattern!(Crystallizer.period_start_for(:week))

      assert [candidate | _] = Synonyms.candidates(@surface, @scope),
             "candidates/3 with no explicit window found nothing at the key the " <>
               "crystallizer writes — the default is not the writer's key"

      assert candidate.from == "hero"
      assert candidate.to == "phoenix"
    end

    # This one is day-independent: it hands `candidates/3` an EXPLICIT window and
    # checks that the crystal-backed evidence honours it. `crystal_stats/3` used
    # to hardcode `period: "week", period_start: Date.add(today, -7)` and ignore
    # the caller's window entirely, so the evidence read 0.0 even when the merge
    # pattern itself was found.
    test "the evidence reads the crystal for the window the caller asked for" do
      window = ~D[2026-01-05]
      merge_pattern!(window)

      crystal!(window, "hero", %{search_count: 100, zero_hit_count: 80, ctr: 0.1})
      crystal!(window, "phoenix", %{search_count: 100, zero_hit_count: 2, ctr: 0.9})

      assert [candidate] =
               Synonyms.candidates(@surface, @scope, period: "week", period_start: window)

      assert candidate.evidence.fromZeroHitRate == 0.8,
             "fromZeroHitRate read #{candidate.evidence.fromZeroHitRate} — the evidence " <>
               "looked up a DIFFERENT window than the merge pattern it annotates"

      assert candidate.evidence.toCtr == 0.9,
             "toCtr read #{candidate.evidence.toCtr} — same divergence, and it silently " <>
               "collapses every confidence score to the transition term alone"

      # transitions 8 -> min(0.8, 1.0) * 0.5 = 0.4, plus toCtr 0.9 * 0.5 = 0.45.
      assert candidate.evidence.confidence == 0.85
    end
  end
end
