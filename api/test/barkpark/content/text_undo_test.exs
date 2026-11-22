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
      assert TextRebase.merge3_both("Hello world", "Hello there", "Hello wOrld") == nil
      assert TextRebase.merge3("Hello world", "Hello there", "Hello wOrld") == "Hello there"
    end

    # The conflict decision gives nil where TanStack's merge3 does: ours made
    # a diff-match-patch patch that has nowhere to go in theirs
    # (task-881f16e32fffbe9a). Undo keeps merge3_both.
    test "merge3_clash: nil where TanStack's merge3 is null, else merge3_both" do
      for {base, ours, theirs} <- [
            {"First words here", "First words here mine", ""},
            {"First words here", "First words here mine", "First"},
            {"First words", "First words!", "First Rewritten"},
            {"First words here today", "First words Xhere today", "First today"}
          ] do
        assert TextRebase.merge3_clash(base, ours, theirs) == nil, inspect({base, ours, theirs})
      end

      # Where TanStack's patch still places ours: the same merge as merge3_both.
      for {base, ours, theirs, merged} <- [
            {"aaa bbb", "aaaX bbb", "aa bbb", "aaX bbb"},
            {"I am heree. Next", "I am heree, yes. Next", "I am here. Next",
             "I am here, yes. Next"},
            {"Hello world ", "Hello world X", "Hello world", "Hello worldX"},
            {"One. Two three. Four five six.", "One. Two three. Yes four five six.",
             "One. Four five six.", "One. Yes four five six."},
            {"First words here today", "First Xwords here today", "First today", "First Xtoday"},
            {"Old text", "Old text and more", "Brand new", "Brand new and more"},
            {"Hello world", "Hello world!", "Hello", "Hello!"},
            {"First words here", "First words here mine", "words here", "words here mine"}
          ] do
        assert TextRebase.merge3_clash(base, ours, theirs) == merged
        assert TextRebase.merge3_both(base, ours, theirs) == merged
      end

      # merge3_both and the save path's merge3 still merge the cleared case.
      assert TextRebase.merge3_both("First words here", "First words here mine", "") == " mine"
      assert TextRebase.merge3("First words here", "First words here mine", "") == " mine"
    end

    test "undo takes A's words back out after B deleted the sentence before them" do
      assert TextUndo.revert(
               "One. Two three. Yes four.",
               "One. Two three. four.",
               "One. Yes four."
             ) ==
               "One. four."
    end

    test "nil over the size bound" do
      big = String.duplicate("x", TextRebase.max_bytes() + 1)
      assert TextRebase.merge3_both(big, big <> "a", "b" <> big) == nil
    end
  end
end
