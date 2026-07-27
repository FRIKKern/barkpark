defmodule Barkpark.Tasks.CriteriaTest do
  # Pure, DB-free {met,total} counting — see Barkpark.Tasks.Criteria.
  # Wire contract (portabledoc-inline-liveref-taskchip-wire §4, amended):
  # met must be EXACTLY true; garbage never crashes; absent → nil (omit,
  # never "0/0").
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Criteria, Internal}

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

  # ─── The close gate's own predicates (PDS-D288/D289/D290) ─────────────────
  #
  # `Tasks.Close` seats these three in `do_close_txn/10`'s `with` chain, on the
  # doc read under the per-task advisory lock. They are pure over content, so
  # they are proven here DB-free; the close-path integration lives in
  # close_test.exs. Counting MUST agree with `Criteria.progress/1` above — a gate
  # that disagrees with the badge is a gate nobody can predict.

  describe "Internal.unmet_criteria/1 — what the D289 gate measures" do
    test "returns each unmet row's index and wording, in list order" do
      content = %{
        "acceptance_criteria" => [
          %{"criterion" => "A", "met" => true},
          %{"criterion" => "B", "met" => false},
          %{"criterion" => "C"}
        ]
      }

      assert Internal.unmet_criteria(content) == [
               %{"index" => 1, "criterion" => "B"},
               %{"index" => 2, "criterion" => "C"}
             ]
    end

    test "met must be EXACTLY true — truthy strings/ints are unmet (agrees with progress/1)" do
      list = [crit("yes"), crit("true"), crit(1), crit(true)]
      content = %{"acceptance_criteria" => list}

      assert Criteria.progress(content) == %{met: 1, total: 4}
      assert Enum.map(Internal.unmet_criteria(content), & &1["index"]) == [0, 1, 2]
    end

    test "garbage entries count as unmet with a nil wording, never crash" do
      content = %{"acceptance_criteria" => ["a string", 7, nil, crit(true)]}

      assert Internal.unmet_criteria(content) == [
               %{"index" => 0, "criterion" => nil},
               %{"index" => 1, "criterion" => nil},
               %{"index" => 2, "criterion" => nil}
             ]
    end

    test "absent / non-list / nil content → [] (nothing to prove, never a refusal)" do
      assert Internal.unmet_criteria(%{"kind" => "task"}) == []
      assert Internal.unmet_criteria(%{"acceptance_criteria" => nil}) == []
      assert Internal.unmet_criteria(%{"acceptance_criteria" => []}) == []
      assert Internal.unmet_criteria(%{"acceptance_criteria" => "3 of 5"}) == []
      assert Internal.unmet_criteria(nil) == []
    end

    test "atom-keyed entries tolerated (in-memory callers)" do
      content = %{"acceptance_criteria" => [%{criterion: "A", met: true}, %{criterion: "B"}]}
      assert Internal.unmet_criteria(content) == [%{"index" => 1, "criterion" => "B"}]
    end
  end

  describe "Internal.close_holder/2 — the D288 three allow-arms" do
    defp doc(content), do: %Document{content: content}

    test "arm 1 — no claim map at all is :unclaimed (container closes survive)" do
      assert Internal.close_holder(doc(%{"kind" => "task"}), "anyone") == {:ok, :unclaimed}
      assert Internal.close_holder(doc(%{"claim" => nil}), "anyone") == {:ok, :unclaimed}
      assert Internal.close_holder(doc(%{"claim" => "garbage"}), "anyone") == {:ok, :unclaimed}
    end

    test "arm 2 — the lease holder" do
      claim = %{"claim" => %{"worker" => "w1", "epoch" => 3}}
      assert Internal.close_holder(doc(claim), "w1") == {:ok, :holder}
      assert Internal.close_holder(doc(claim), "w2") == {:error, {:not_holder, "w1"}}
    end

    test "arm 3 — self-resume needs BOTH keys: previous_worker (TTL reap) and released_by" do
      reaped = %{"claim" => %{"worker" => nil, "previous_worker" => "w1"}}
      released = %{"claim" => %{"worker" => nil, "released_by" => "w1"}}

      assert Internal.close_holder(doc(reaped), "w1") == {:ok, :self_resume}
      assert Internal.close_holder(doc(released), "w1") == {:ok, :self_resume}

      assert Internal.close_holder(doc(reaped), "w2") == {:error, {:not_holder, "w1"}}
      assert Internal.close_holder(doc(released), "w2") == {:error, {:not_holder, "w1"}}
    end

    test "a live claim is never self-resumable by the previous holder" do
      content = %{"claim" => %{"worker" => "w2", "previous_worker" => "w1"}}
      assert Internal.close_holder(doc(content), "w1") == {:error, {:not_holder, "w2"}}
    end

    test "a claim naming nobody at all refuses with a nil held_by" do
      assert Internal.close_holder(doc(%{"claim" => %{"epoch" => 1}}), "w1") ==
               {:error, {:not_holder, nil}}
    end

    test "the plain holder check is NOT reusable here — it refuses both arms 1 and 3" do
      # Why D288 forbids reusing Internal.check_holder/2 verbatim: it fails on a
      # nil claim.worker, which would refuse every container close and every
      # self-resume close on the live ledger.
      assert Internal.check_holder(doc(%{"kind" => "task"}), "anyone") ==
               {:error, :not_holder}

      assert Internal.check_holder(
               doc(%{"claim" => %{"worker" => nil, "released_by" => "w1"}}),
               "w1"
             ) ==
               {:error, :not_holder}
    end
  end

  describe "Internal.check_worker_id/1 — the D290 sentinels" do
    test "refuses empty-after-trim and None|null|nil|- in any case" do
      for sentinel <- ["", "   ", "\t\n", "None", "none", "NONE", "null", "NULL", "nil", "-"] do
        assert Internal.check_worker_id(sentinel) == {:error, {:sentinel_worker_id, sentinel}},
               "#{inspect(sentinel)} is a missing value, not a worker"
      end
    end

    test "accepts real worker ids, including ones that merely contain a sentinel" do
      for id <- ["oc-lead", "cc-showcase", "none-of-your-business", "nil-hoard", "w-1"] do
        assert Internal.check_worker_id(id) == :ok
      end
    end
  end
end
