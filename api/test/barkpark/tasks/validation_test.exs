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

  # Helper for the outcome.resolution describe — ExUnit forbids defp inside
  # describe blocks, so it lives at module level.
  defp task_with_outcome(outcome) do
    Validation.validate_task_content(%{
      "kind" => "task",
      "lifecycle_status" => "done",
      "outcome" => outcome
    })
  end
end
