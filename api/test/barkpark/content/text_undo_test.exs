defmodule Barkpark.Content.TextUndoTest do
  @moduledoc """
  task-c25c112913859b11: one editor's own text change taken back out of a
  field, the other editor's words kept (`TextUndo`, as the TanStack
  Studio's `revert` and `revertSteps`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.TextRebase
  alias Barkpark.Content.TextUndo

  describe "revert/3" do
    test "takes A's suffix out and keeps B's prefix" do
      assert TextUndo.revert(
               "Fixture post 14 A aaa",
               "Fixture post 14 A",
               "bbb Fixture post 14 A aaa"
             ) ==
               "bbb Fixture post 14 A"
    end

    test "with nothing else written, gives the step's text back" do
      assert TextUndo.revert("Fixture A", "Fixture", "Fixture A") == "Fixture"
    end

    test "redo puts A's words back beside B's" do
      assert TextUndo.revert("Fixture post 14", "Fixture post 14 A", "bbb Fixture post 14") ==
               "bbb Fixture post 14 A"
    end

    test "leaves the text when B wrote over A's words" do
      assert TextUndo.revert("Hello A world", "Hello world", "Hello B world") == "Hello B world"
    end
  end

  describe "revert_steps/2" do
    test "walks the steps in order" do
      steps = [{"Fixture A aaa", "Fixture A"}, {"Fixture A", "Fixture"}]
      assert TextUndo.revert_steps(steps, "bbb Fixture A aaa") == "bbb Fixture"
    end

    test "all or nothing: a step that no longer applies leaves the whole change" do
      steps = [{"Fixture A aaa", "Fixture A"}, {"Fixture A", "Fixture"}]
      # B wrote into the " A" since: the first step applies, the second not.
      assert TextUndo.revert_steps(steps, "Fixture xA aaa") == "Fixture xA aaa"
    end
  end

  describe "TextRebase.merge3_both/3" do
    test "nil where the two changes overlap, where merge3/3 gives ours" do
      assert TextRebase.merge3_both("Hello world", "Hello A world", "Hello B world") == nil
      assert TextRebase.merge3("Hello world", "Hello A world", "Hello B world") == "Hello A world"
    end

    test "nil over the size bound" do
      big = String.duplicate("x", TextRebase.max_bytes() + 1)
      assert TextRebase.merge3_both(big, big <> "a", "b" <> big) == nil
    end
  end
end
