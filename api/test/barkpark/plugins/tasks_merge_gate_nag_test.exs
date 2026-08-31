defmodule Barkpark.Plugins.TasksMergeGateNagTest do
  @moduledoc """
  The merge-gate wording nag, proven in BOTH directions against REAL corpus
  wording rather than invented strings.

  The `MERGE-GATED` text convention and the `merge_gate` flag are two
  vocabularies and only the flag is machine-readable (`Tasks.Close`'s
  `autostamp_merge_gate/6` keys on it). The nag tells an author when a new
  criterion opens with the marker but carries no flag.

  IT IS DELIBERATELY NARROW. A census of 1845 marker-bearing criteria found 51
  NON-leading cases that are nonetheless genuine gates and 54 that merely
  mention merge-gating — position and prose misclassify in opposite directions.
  So the nag fires only on the LEADING form, and a miss costs one un-nagged
  author rather than a fabricated close. `test/support/fixtures/
  merge_gate_wording.json` carries every non-leading case from the live corpus:
  the silence half of this test is the guarantee that widening the pattern
  would be caught.

  Both halves must hold. A nag that never fires and a nag that never shuts up
  are the same defect wearing different clothes.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Tasks

  @fixture Path.join(__DIR__, "../../support/fixtures/merge_gate_wording.json")

  defp fixture do
    @fixture |> File.read!() |> Jason.decode!()
  end

  # Drive the REAL registered before_save hook rather than a private function,
  # so the test breaks if the gate is ever unregistered (sheets_test.exs shape).
  defp save(criteria) do
    [hook] = Tasks.lifecycle_hooks()[:before_save]

    hook.(%{
      doc: %{"type" => "task", "title" => "t", "content" => %{"acceptance_criteria" => criteria}},
      prev_doc: nil
    })
  end

  defp log_for(criteria), do: capture_log(fn -> assert :ok = save(criteria) end)

  describe "the nag FIRES on the unambiguous leading form" do
    test "a leading MERGE-GATED criterion with no flag warns and still saves" do
      log = log_for([%{"criterion" => "[MERGE-GATED] PR merged to main.", "met" => false}])

      assert log =~ "carry no `merge_gate: true`"
      assert log =~ "acceptance_criteria [0]"
    end

    test "every sampled LEADING criterion from the live corpus warns" do
      cases = fixture()["must_warn"]

      # The mirror of the floor the silence half already carries
      # ("must_stay_silent" asserts `length(cases) > 100`). Without it a
      # fixture regeneration emitting `"must_warn": []` would iterate zero
      # times and pass — silently retiring the nag's FIRING half, while this
      # module's own doc insists "a nag that never fires and a nag that never
      # shuts up are the same defect".
      assert length(cases) >= 40,
             "the warn fixture should carry the whole leading-form population"

      for %{"criterion" => text, "doc" => doc} <- cases do
        log = log_for([%{"criterion" => text, "met" => false}])

        assert log =~ "merge_gate",
               "expected the nag to fire on #{doc}'s leading-form criterion: #{String.slice(text, 0, 90)}"
      end
    end

    test "it names EVERY offending index, not just the first" do
      log =
        log_for([
          %{"criterion" => "ordinary work", "met" => false},
          %{"criterion" => "MERGE-GATED: lead closes", "met" => false},
          %{"criterion" => "more ordinary work", "met" => false},
          %{"criterion" => "[MERGE-GATED] also lead-closed", "met" => false}
        ])

      assert log =~ "acceptance_criteria [1, 3]"
    end
  end

  describe "the nag STAYS SILENT where it must" do
    test "a leading criterion that DOES carry the flag is not nagged" do
      log =
        log_for([
          %{
            "criterion" => "[MERGE-GATED] PR merged to main.",
            "met" => false,
            "merge_gate" => true
          }
        ])

      refute log =~ "merge_gate: true`"
    end

    test "EVERY non-leading corpus case stays silent — genuine gates and mentions alike" do
      cases = fixture()["must_stay_silent"]

      assert length(cases) > 100,
             "the silence fixture should carry the whole non-leading population"

      for %{"criterion" => text, "doc" => doc} <- cases do
        log = log_for([%{"criterion" => text, "met" => false}])

        refute log =~ "carry no `merge_gate: true`",
               "the nag fired on a NON-leading criterion (#{doc}) — widening the pattern nags " <>
                 "authors whose criterion was never a gate: #{String.slice(text, 0, 90)}"
      end
    end

    test "a criterion with no merge-gate wording at all is silent" do
      refute log_for([%{"criterion" => "the suite is green", "met" => false}]) =~ "merge_gate"
    end

    test "a non-binary or absent criterion does not crash the gate" do
      assert :ok = save([%{"met" => false}])
      assert :ok = save([%{"criterion" => 42, "met" => false}])
    end
  end

  describe "it is ADVISORY, never a gate" do
    test "the write is never halted by the wording, however many criteria offend" do
      criteria = for i <- 1..5, do: %{"criterion" => "[MERGE-GATED] #{i}", "met" => false}
      assert :ok = save(criteria)
    end
  end

  describe "the nag rides the ADVISORY CHANNEL, not only the journal" do
    alias Barkpark.Content.Warnings

    test "an unflagged leading gate queues a merge_gate_unflagged entry for the envelope" do
      Warnings.reset()

      capture_log(fn ->
        assert :ok =
                 save([%{"criterion" => "[MERGE-GATED] PR merged to main.", "met" => false}])
      end)

      assert [%{code: "merge_gate_unflagged", severity: "warning", message: message}] =
               Warnings.drain()

      assert message =~ "merge_gate\": true"
      assert message =~ "[0]"
    end

    test "a flagged gate queues nothing" do
      Warnings.reset()

      capture_log(fn ->
        assert :ok =
                 save([
                   %{"criterion" => "[MERGE-GATED] x", "met" => false, "merge_gate" => true}
                 ])
      end)

      assert Warnings.drain() == []
    end
  end
end
