defmodule Barkpark.Tasks.ValidationTest do
  # Pure, DB-free content-shape checks — see Barkpark.Tasks.Validation.
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Validation

  describe "kind discriminator" do
    test "accepts a well-formed task content map" do
      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "open"
             }) == :ok
    end

    test "rejects an unknown top-level kind" do
      assert {:error, %{"kind" => [msg]}} =
               Validation.validate_kind_content("widget", %{})

      assert msg =~ "unknown kind"
    end

    test "missing kind is required" do
      # validate_kind_content stamps "task" internally, so a content map
      # lacking its own "kind" self-identifier is rejected.
      assert {:error, errors} = Validation.validate_task_content(%{"lifecycle_status" => "open"})
      assert errors["kind"] == ["is required"]
    end

    test "mismatched kind reports expected vs got" do
      assert {:error, %{"kind" => [msg]}} =
               Validation.validate_task_content(%{"kind" => "note", "lifecycle_status" => "open"})

      assert msg =~ "expected \"task\""
    end
  end

  describe "lifecycle_status (required string enum)" do
    test "present + valid passes" do
      for status <- Validation.lifecycle_statuses() do
        assert Validation.validate_task_content(%{"kind" => "task", "lifecycle_status" => status}) ==
                 :ok
      end
    end

    test "missing is required" do
      assert {:error, %{"lifecycle_status" => [msg]}} =
               Validation.validate_task_content(%{"kind" => "task"})

      assert msg =~ "is required"
    end

    test "out-of-enum value is rejected" do
      assert {:error, %{"lifecycle_status" => [msg]}} =
               Validation.validate_task_content(%{"kind" => "task", "lifecycle_status" => "nope"})

      assert msg =~ "must be one of"
    end
  end

  describe "priority bounds (0..4)" do
    test "accepts the full valid range" do
      for p <- 0..4 do
        assert Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "priority" => p
               }) == :ok
      end
    end

    test "rejects out-of-range and non-integer priority" do
      for bad <- [-1, 5, "2", 1.5] do
        assert {:error, %{"priority" => [_]}} =
                 Validation.validate_task_content(%{
                   "kind" => "task",
                   "lifecycle_status" => "open",
                   "priority" => bad
                 })
      end
    end
  end

  describe "falsy-masking regression — literal false must not slip through" do
    # Before the fetch/2 fix, `Map.get(content, key) || Map.get(content, atom)`
    # treated a present `false` as absent, so an invalid `false` silently
    # passed the type check instead of raising.

    test "string field set to false is a type error, not silently accepted" do
      assert {:error, %{"assignee" => [msg]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "assignee" => false
               })

      assert msg =~ "must be a string"
    end

    test "string-list field set to false is a type error" do
      assert {:error, %{"dependencies" => [_]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "dependencies" => false
               })
    end

    test "map field set to false is a type error" do
      assert {:error, %{"claim" => [_]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "claim" => false
               })
    end

    test "list field set to false is a type error" do
      assert {:error, %{"labels" => [_]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "labels" => false
               })
    end

    test "map-list field set to false is a type error" do
      assert {:error, %{"worklog" => [_]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "worklog" => false
               })
    end

    test "kind set to false reports mismatch, not missing" do
      assert {:error, %{"kind" => [msg]}} =
               Validation.validate_task_content(%{"kind" => false, "lifecycle_status" => "open"})

      # Distinguishes the masked path ("is required") from the real one.
      assert msg =~ "expected \"task\""
      refute msg =~ "is required"
    end
  end

  describe "outcome.resolution (validated enum, charter D23)" do
    @resolutions ~w(shipped fixed partial wont_do duplicate superseded discarded)

    test "every advertised resolution value passes" do
      for resolution <- @resolutions do
        assert task_with_outcome(%{"resolution" => resolution}) == :ok
      end
    end

    test "off-enum resolution is rejected, naming the allowed list" do
      assert {:error, %{"outcome" => [msg]}} = task_with_outcome(%{"resolution" => "abandoned"})
      assert msg =~ "resolution must be one of"
      for resolution <- @resolutions, do: assert(msg =~ resolution)
      assert msg =~ "\"abandoned\""
    end

    test "empty-string resolution is rejected (present-but-empty is off-enum)" do
      assert {:error, %{"outcome" => [msg]}} = task_with_outcome(%{"resolution" => ""})
      assert msg =~ "resolution must be one of"
    end

    test "absent outcome is fine" do
      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "done"
             }) == :ok
    end

    test "outcome map without a resolution is fine; unknown other keys stay tolerated" do
      assert task_with_outcome(%{"summary" => "shipped the thing", "weird_key" => 42}) == :ok
    end

    test "non-map outcome keeps the existing shape error" do
      assert {:error, %{"outcome" => [msg]}} = task_with_outcome("shipped")
      assert msg == "must be a map when set, got \"shipped\""
    end
  end

  describe "atom-key fallback still works" do
    test "atom keys are accepted equivalently to string keys" do
      assert Validation.validate_task_content(%{kind: "task", lifecycle_status: "open"}) == :ok
    end
  end

  describe "acceptance_criteria — the criterion wording is a CAS key" do
    # pds-bl-stamp-trailing-newline-deadend. A criterion's stored text is what
    # every met-flip is CAS'd against (`Tasks.Internal` compares with `==`), and
    # the shells that carry that text drop trailing newlines, so a criterion
    # authored with one can be refused forever and stamped never. These arms pin
    # the refusal at the authoring door. They do NOT relax the `==` match, and
    # `Tasks.Internal` is deliberately untouched by this change.

    test "a criterion ending in a newline is refused" do
      assert {:error, %{"acceptance_criteria" => [msg]}} =
               task_with_criteria([%{"criterion" => "ships the thing\n"}])

      assert msg =~ "criterion 0 begins or ends with whitespace"
      # The message QUOTES the offending text: an author who cannot see the
      # character in their editor can see it in `inspect/1`'s escaping.
      assert msg =~ ~S("ships the thing\n")
      assert msg =~ "never stamped"
    end

    test "a criterion ending in a space is refused" do
      assert {:error, %{"acceptance_criteria" => [msg]}} =
               task_with_criteria([%{"criterion" => "ships the thing "}])

      assert msg =~ "criterion 0 begins or ends with whitespace"
    end

    test "a criterion BEGINNING with whitespace is refused too" do
      assert {:error, %{"acceptance_criteria" => [msg]}} =
               task_with_criteria([%{"criterion" => "\n ships the thing"}])

      assert msg =~ "criterion 0 begins or ends with whitespace"
    end

    # THE NON-VACUITY ARM, and the reason the rule is spelled with
    # `String.trim/1` rather than "no newlines". 4 of the 35,603 criteria
    # strings in the live corpus carry an INTERNAL newline and stamp fine; a
    # rule that banned newlines outright would refuse four honest rows to catch
    # a shape nobody has written. If this test ever goes red, the rule got
    # wider than its evidence.
    test "a criterion with an INTERNAL newline is accepted" do
      assert task_with_criteria([
               %{"criterion" => "ships the thing\nand proves it\n\nwith a run"}
             ]) == :ok
    end

    test "a clean criterion is accepted (the control)" do
      assert task_with_criteria([%{"criterion" => "ships the thing"}]) == :ok
    end

    # The reported index must be the OFFENDING row, not a constant. A message
    # that always said "criterion 0" would pass every arm above while sending
    # an author to the wrong line.
    test "the message names the offending index, not the first one" do
      assert {:error, %{"acceptance_criteria" => [msg]}} =
               task_with_criteria([
                 %{"criterion" => "clean"},
                 %{"criterion" => "clean too"},
                 %{"criterion" => "dirty\n"}
               ])

      assert msg =~ "criterion 2 begins or ends with whitespace"
      refute msg =~ "criterion 0"
    end

    test "an entry with no criterion text is not this rule's business" do
      assert task_with_criteria([%{"met" => false}]) == :ok
      assert task_with_criteria([%{"criterion" => 42}]) == :ok
    end

    # Regression guard for the check this rule REPLACED: the list-of-maps and
    # is-a-list shapes must still refuse. A new rule that dropped an old one
    # would be a silent widening.
    test "the pre-existing shape rules still fire" do
      assert {:error, %{"acceptance_criteria" => [msg]}} = task_with_criteria(["not a map"])
      assert msg =~ "must be a list of maps"

      assert {:error, %{"acceptance_criteria" => [msg]}} = task_with_criteria("nope")
      assert msg =~ "must be a list when set"
    end

    test "absent acceptance_criteria is still fine" do
      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "open"
             }) == :ok
    end
  end

  # Helper for the outcome.resolution describe — ExUnit forbids defp inside
  # describe blocks, so it lives at module level.
  defp task_with_criteria(criteria) do
    Validation.validate_task_content(%{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => criteria
    })
  end

  defp task_with_outcome(outcome) do
    Validation.validate_task_content(%{
      "kind" => "task",
      "lifecycle_status" => "done",
      "outcome" => outcome
    })
  end
end
