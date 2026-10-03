defmodule Barkpark.Tasks.MergeGateBirthFlagTest do
  @moduledoc """
  The merge-gate BIRTH FLAG (task-0ed428e843b83382): a criterion that OPENS
  with the MERGE-GATED marker and carries no `merge_gate` key is born with
  `merge_gate: true`. A buried marker is left alone, and declared intent is
  never overridden.

  Both columns are walked from the LIVE ledger
  (`test/support/fixtures/merge_gate_birth_flag.json`, generated 2026-10-03
  from every published task on guerrilla). Every leading-marker criterion must
  be flagged, and every buried-marker criterion must NOT be. The buried column
  includes the two verbatim criteria that assert the opposite of what a flag
  would make them mean. The narrowing is mutation-proved: swap in the wide
  wording predicate and the buried-column check reds, naming cases.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Criteria

  @fixture Path.join(__DIR__, "../../support/fixtures/merge_gate_birth_flag.json")

  @self_refuting [
    "The four lead-gated rows are adjudicated `open`",
    "Every machine-checkable merge gate is verified with `gh pr view"
  ]

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp entry(text), do: %{"criterion" => text, "met" => false}

  # The check the buried column must pass, parameterised by the flagger so a
  # MUTANT flagger can be run through the very same assertion.
  defp assert_buried_untouched!(flagger, cases) do
    flagged =
      for %{"criterion" => text, "doc" => doc} <- cases,
          match?({_, [0]}, flagger.([entry(text)])),
          do: doc

    assert flagged == [],
           "NARROWING DROPPED: #{length(flagged)} buried-marker criteria were flagged, e.g. #{Enum.take(flagged, 3) |> Enum.join(", ")}"
  end

  describe "both columns, from the live ledger" do
    test "the fixture carries both populations and the measured counts" do
      f = fixture()

      assert length(f["must_flag"]) >= 500,
             "the leading column is the whole deduplicated population"

      assert length(f["must_not_flag"]) >= 90, "the buried column is every buried case"
      assert f["counts"]["leading_merge_gated"]["true"] > 1000
      assert length(f["gate_spelling_opening"]) >= 50

      # The two self-refuting examples ride in the buried column, verbatim.
      for prefix <- @self_refuting do
        assert Enum.any?(f["must_not_flag"], &String.starts_with?(&1["criterion"], prefix)),
               "the buried column lost the verbatim example: #{prefix}"
      end
    end

    test "every leading-marker criterion with no key is flagged" do
      for %{"criterion" => text, "doc" => doc} <- fixture()["must_flag"] do
        {[flagged], idx} = Criteria.flag_leading_merge_gates([entry(text)])

        assert idx == [0] and flagged["merge_gate"] == true,
               "expected the birth flag on #{doc}: #{String.slice(text, 0, 90)}"
      end
    end

    test "every buried-marker criterion is left alone, the two self-refuting examples included" do
      assert_buried_untouched!(&Criteria.flag_leading_merge_gates/1, fixture()["must_not_flag"])
    end

    test "an opening in the \"MERGE GATE\" spelling (no -D) is left alone, on purpose" do
      assert_buried_untouched!(
        &Criteria.flag_leading_merge_gates/1,
        fixture()["gate_spelling_opening"]
      )
    end

    test "MUTATION: widen the predicate to the wording anywhere and the buried check reds" do
      wide = fn [e] ->
        if Criteria.merge_gated?(e), do: {[Map.put(e, "merge_gate", true)], [0]}, else: {[e], []}
      end

      cases = fixture()["must_not_flag"]

      # The mutant is alive: it really does flag the self-refuting examples.
      for prefix <- @self_refuting do
        %{"criterion" => text} = Enum.find(cases, &String.starts_with?(&1["criterion"], prefix))
        assert {_, [0]} = wide.([entry(text)])
      end

      err = assert_raise ExUnit.AssertionError, fn -> assert_buried_untouched!(wide, cases) end
      assert err.message =~ "NARROWING DROPPED"
    end
  end

  describe "declared intent always beats the detector" do
    test "an explicit merge_gate: false on a leading marker is never overridden (live cases)" do
      for %{"criterion" => text, "doc" => doc} <- fixture()["explicit_false_leading"] do
        e = Map.put(entry(text), "merge_gate", false)

        assert {[^e], []} = Criteria.flag_leading_merge_gates([e]),
               "overrode #{doc}'s explicit false"
      end
    end

    test "an explicit merge_gate: true is left exactly as written, and so is a non-boolean value" do
      for value <- [true, nil, "yes"] do
        e = Map.put(entry("MERGE-GATED: PR merged."), "merge_gate", value)
        assert {[^e], []} = Criteria.flag_leading_merge_gates([e])
      end
    end

    test "it names every flagged index and leaves the rest of the list untouched" do
      list = [
        entry("ordinary work"),
        entry("MERGE-GATED: lead closes"),
        entry("talks about a [MERGE-GATED] lead act"),
        entry("[MERGE-GATED] also lead-closed")
      ]

      {out, idx} = Criteria.flag_leading_merge_gates(list)
      assert idx == [1, 3]
      assert Enum.map(out, &Map.get(&1, "merge_gate")) == [nil, true, nil, true]
      assert Enum.at(out, 0) == Enum.at(list, 0)
    end

    test "non-list and non-map input passes through" do
      assert {nil, []} = Criteria.flag_leading_merge_gates(nil)
      assert {["x"], []} = Criteria.flag_leading_merge_gates(["x"])
    end
  end
end
