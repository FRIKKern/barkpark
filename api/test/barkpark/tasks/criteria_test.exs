defmodule Barkpark.Tasks.CriteriaTest do
  # Pure, DB-free {met,total} counting — see Barkpark.Tasks.Criteria.
  # Wire contract (portabledoc-inline-liveref-taskchip-wire §4, amended):
  # met must be EXACTLY true; garbage never crashes; absent → nil (omit,
  # never "0/0").
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Criteria

  defp crit(met), do: %{"criterion" => "c", "met" => met, "evidence" => "e"}

  describe "progress/1 — happy path" do
    test "counts only met === true entries" do
      content = %{
        "acceptance_criteria" => [crit(true), crit(false), crit(true)]
      }

      assert Criteria.progress(content) == %{met: 2, total: 3}
    end

    test "all met" do
      assert Criteria.progress(%{"acceptance_criteria" => [crit(true)]}) ==
               %{met: 1, total: 1}
    end

    test "accepts a %Document{} and reads its content" do
      doc = %Document{content: %{"acceptance_criteria" => [crit(true), crit(false)]}}
      assert Criteria.progress(doc) == %{met: 1, total: 2}
    end

    test "delegated through the Barkpark.Tasks facade" do
      assert Barkpark.Tasks.criteria_progress(%{"acceptance_criteria" => [crit(true)]}) ==
               %{met: 1, total: 1}
    end
  end

  describe "progress/1 — criteria absent → nil (omit, never 0/0)" do
    test "no acceptance_criteria key" do
      assert Criteria.progress(%{"kind" => "task"}) == nil
    end

    test "acceptance_criteria nil" do
      assert Criteria.progress(%{"acceptance_criteria" => nil}) == nil
    end

    test "acceptance_criteria empty list" do
      assert Criteria.progress(%{"acceptance_criteria" => []}) == nil
    end

    test "acceptance_criteria non-list garbage" do
      assert Criteria.progress(%{"acceptance_criteria" => "3 of 5"}) == nil
      assert Criteria.progress(%{"acceptance_criteria" => %{"met" => true}}) == nil
      assert Criteria.progress(%{"acceptance_criteria" => 42}) == nil
    end

    test "nil / non-map content" do
      assert Criteria.progress(nil) == nil
      assert Criteria.progress("garbage") == nil
      assert Criteria.progress(%Document{content: nil}) == nil
    end
  end

  describe "progress/1 — garbage entries count as UNMET, never crash" do
    test "met missing" do
      assert Criteria.progress(%{
               "acceptance_criteria" => [%{"criterion" => "c"}, crit(true)]
             }) == %{met: 1, total: 2}
    end

    test ~s(met "yes" / "true" / 1 — non-boolean truthiness is UNMET) do
      list = [crit("yes"), crit("true"), crit(1), crit(true)]

      assert Criteria.progress(%{"acceptance_criteria" => list}) ==
               %{met: 1, total: 4}
    end

    test "met false is unmet (and does not crash the present-but-false fetch)" do
      assert Criteria.progress(%{"acceptance_criteria" => [crit(false)]}) ==
               %{met: 0, total: 1}
    end

    test "non-map entries count toward total as unmet" do
      list = ["just a string", 7, nil, [crit(true)], crit(true)]

      assert Criteria.progress(%{"acceptance_criteria" => list}) ==
               %{met: 1, total: 5}
    end

    test "atom-keyed entries tolerated (in-memory callers)" do
      list = [%{criterion: "c", met: true}, %{criterion: "d", met: "yes"}]

      assert Criteria.progress(%{acceptance_criteria: list}) ==
               %{met: 1, total: 2}
    end
  end

  describe "of_list/1 — raw list entry point (the Studio badge path)" do
    test "same counting on a bare list" do
      assert Criteria.of_list([crit(true), crit(false)]) == %{met: 1, total: 2}
    end

    test "nil for empty/absent/garbage" do
      assert Criteria.of_list([]) == nil
      assert Criteria.of_list(nil) == nil
      assert Criteria.of_list("garbage") == nil
    end
  end
end
