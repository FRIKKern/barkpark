defmodule BarkparkCloud.DeployLedger.ClassContinuity do
  @moduledoc """
  A cause class whose count goes to zero while its COHORT total holds is a
  rename, not a quiet fleet — deploy-reliability W12, charter D179.

  ## The event this exists for

  On **2026-08-06 22:19:52Z** guerrilla took `ef77af274` (#9827, the typed
  `box_at_capacity` door) and 9m35s later the deferral cause class silently
  swapped: `BOX_BUSY_DEFERRED` → `BOX_AT_CAPACITY_DEFERRED`
  (`DeployLedger.classify_deferred/2`). Both classes live INSIDE the deferred
  cohort, so `failure_rate` — which is keyed on the cohort, not the class —
  never twitched. Nothing anywhere went red. But every instrument, alert and
  dashboard keyed on the CAUSE CLASS lost its entire population in one box
  restart, with no signal at all.

  That is the wave's own thesis one level below where it was scoped: not a
  status swap, a CLASS swap. The signature is cheap: a class's count falls to
  zero across two windows while the cohort it sits in keeps its rows.

  ## The discrimination, both ways

  A check that only tests the firing half is a tautology dressed as coverage.
  The whole value here is the second arm, so the rule is written as a
  SUBTRACTION rather than as a threshold on the cohort total:

      cohort_drop = cohort_before - cohort_after
      retained    = count_before - cohort_drop

  `retained` is the part of the vanished class's population the cohort still
  holds. It answers "where did those rows GO?" with the only two possible
  answers:

    * `retained` ≈ 0 — the cohort shed exactly that class's rows. The class went
      QUIET. Silent. (This is also the whole-cohort drain: a cohort that empties
      sheds every class's population, so `retained` is ≤ 0 for all of them.)
    * `retained` > 0 — the cohort kept rows the class used to own. Those rows
      are still being written; something else is wearing their name now. FIRE.

  Reading the cohort total alone cannot tell those apart, which is precisely how
  2026-08-06 got through: an operator watching `failure_rate` saw a number that
  HELD, and a held number is what a rename looks like from above.

  ## What it does NOT claim

  A finding is "this class lost its population to a sibling", never "the code was
  renamed". A genuine cause change — the fleet really did stop being busy and
  started being at capacity — produces the identical signature, and SHOULD: the
  instrument keyed on the old class is just as blind either way, and that is the
  harm being detected. `:absorbed_by` names the suspects by gain so the reader
  can settle which it was in one look.

  ## Shape

  Consumes `DeployLedger.census/3`'s own class rows verbatim —
  `census.deferred` (the deferred cohort) and `census.classes` (the failure
  cohort) are both lists of `%{class: _, count: _}` — so no second, drifting
  definition of "a class row" lives here. `check_census/4` takes the two censuses
  and names the cohort key.

  Counts only. Nothing in this module reads `share`, so it is unaffected by the
  vocabulary-boundary ratio refusals (D9: counts stay, ratios go), and it is
  therefore usable across exactly the windows a rate cannot be computed over —
  which is where a vocabulary swap lives.
  """

  # A class with a handful of rows going to zero is noise: a quiet weekend on a
  # small cohort produces it constantly. The floor is on the VANISHED class's
  # own before-count, never on the cohort — a cohort floor would mute a small
  # class inside a large cohort, which is the exact 2026-08-06 shape at a
  # smaller scale.
  @min_count 10

  # How much of the vanished population the cohort may shed before "it went
  # quiet" stops being the honest reading. Rows do not arrive in round numbers;
  # 10% keeps a cohort that shed 690 of a 698-row class silent.
  @tolerance 0.10

  # How many suspects `:absorbed_by` carries. Enough to see the successor and
  # that it is the successor; not a dump of every class that moved a row.
  @suspects 3

  @type class_row :: %{required(:class) => String.t(), required(:count) => non_neg_integer()}
  @type verdict :: :renamed | :went_quiet | :cohort_drained | :below_floor

  @typedoc "One class's continuity reading across the two windows."
  @type finding :: %{
          class: String.t(),
          verdict: verdict(),
          count_before: non_neg_integer(),
          count_after: non_neg_integer(),
          cohort_before: non_neg_integer(),
          cohort_after: non_neg_integer(),
          cohort_drop: integer(),
          retained: integer(),
          absorbed_by: [%{class: String.t(), gain: pos_integer()}]
        }

  @doc """
  The findings that FIRE — every class whose population the cohort kept under
  another name.

  Options: `:min_count` (default #{@min_count}), `:tolerance` (default
  #{@tolerance}).
  """
  @spec check([class_row()], [class_row()], keyword()) :: [finding()]
  def check(before_rows, after_rows, opts \\ []) do
    before_rows
    |> verdicts(after_rows, opts)
    |> Enum.filter(&(&1.verdict == :renamed))
  end

  @doc """
  Every candidate's reading, firing or not — so SILENCE is inspectable and
  testable rather than an absence a test can only assert vacuously.

  A candidate is a class that carried rows in the before window and carries none
  in the after window. A class still present is not a continuity question and
  gets no row here.
  """
  @spec verdicts([class_row()], [class_row()], keyword()) :: [finding()]
  def verdicts(before_rows, after_rows, opts \\ []) do
    min_count = Keyword.get(opts, :min_count, @min_count)
    tolerance = Keyword.get(opts, :tolerance, @tolerance)

    before = counts(before_rows)
    after_ = counts(after_rows)

    cohort_before = total(before)
    cohort_after = total(after_)
    cohort_drop = cohort_before - cohort_after

    before
    |> Enum.filter(fn {class, count} -> count > 0 and Map.get(after_, class, 0) == 0 end)
    |> Enum.map(fn {class, count} ->
      %{
        class: class,
        verdict: verdict(count, cohort_after, cohort_drop, min_count, tolerance),
        count_before: count,
        count_after: 0,
        cohort_before: cohort_before,
        cohort_after: cohort_after,
        cohort_drop: cohort_drop,
        retained: count - cohort_drop,
        absorbed_by: absorbed_by(before, after_)
      }
    end)
    |> Enum.sort_by(& &1.count_before, :desc)
  end

  # ORDER IS THE POINT, and the arms are not interchangeable.
  #
  # `:below_floor` first: a class of 3 rows produces every other verdict by
  # accident, so it never earns one of them.
  #
  # `:cohort_drained` before `:went_quiet`: an emptied cohort satisfies the
  # quiet arm arithmetically for every class in it, and reporting six classes as
  # independently "quiet" hides the one fact that explains all six.
  defp verdict(count, cohort_after, _cohort_drop, min_count, _tolerance)
       when count < min_count or cohort_after == 0 do
    if count < min_count, do: :below_floor, else: :cohort_drained
  end

  defp verdict(count, _cohort_after, cohort_drop, _min_count, tolerance) do
    # The cohort shed (near enough) this class's whole population: those rows
    # stopped being written, they were not relabelled.
    if cohort_drop >= count * (1 - tolerance), do: :went_quiet, else: :renamed
  end

  # The siblings that GREW, biggest gain first. Named, not accused: a reader
  # settles a real cause change from a rename by looking at whether one sibling
  # gained about what the vanished class lost.
  defp absorbed_by(before, after_) do
    after_
    |> Enum.map(fn {class, count} -> %{class: class, gain: count - Map.get(before, class, 0)} end)
    |> Enum.filter(&(&1.gain > 0))
    |> Enum.sort_by(& &1.gain, :desc)
    |> Enum.take(@suspects)
  end

  # Accepts census class rows (maps carrying `:class` and `:count`) or a plain
  # `%{class => count}` map, and sums duplicates rather than letting the last one
  # win — a caller that concatenated two cohorts' rows must not silently lose the
  # first one's counts.
  defp counts(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, fn %{class: class, count: count}, acc ->
      Map.update(acc, class, count, &(&1 + count))
    end)
  end

  defp counts(rows) when is_map(rows), do: rows

  defp total(counts), do: counts |> Map.values() |> Enum.sum()

  @doc """
  `check/3` over two `DeployLedger.census/3` results and one cohort key —
  `:deferred` (the deferral cohort, where 2026-08-06 happened) or `:classes`
  (the failure cohort).
  """
  @spec check_census(map(), map(), :deferred | :classes, keyword()) :: [finding()]
  def check_census(before_census, after_census, cohort, opts \\ [])
      when cohort in [:deferred, :classes] do
    check(Map.fetch!(before_census, cohort), Map.fetch!(after_census, cohort), opts)
  end
end
