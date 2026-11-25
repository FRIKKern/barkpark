defmodule Barkpark.Content.TextUndoTest do
  @moduledoc """
  task-c25c112913859b11: one editor's own text change taken back out of a
  field, the other editor's words kept (`TextUndo`, as the TanStack
  Studio's `revert` and `revertSteps`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.TextRebase
  alias Barkpark.Content.TextUndo

  # "An answer at once" is measured as work, not time (task-16c776c04c581992).
  # A wall-clock bound failed on loaded CI runners (700 took 553 and 627 ms)
  # with no change to this code. Reductions, the BEAM's count of the work a
  # process does, do not move with load: these cases measured within 2% of
  # each other idle and beside CPU burners, while their time grew up to 15x.
  # The work stays in this process (no task, no NIF).
  defp work(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    {after_ - before, result}
  end

  # Measured at 804ba5e258, on OTP 28 here and on CI's OTP 27 (.tool-versions)
  # within 3% of each other: the 50 KB / 30 KB / 15 KB cases take
  # 2.4M / 1.5M / 0.8M reductions.
  @clash_at_once 5_000_000

  # The caps cases take 0.7M-15M (table250, the most). With the
  # `@max_changed_units` guard removed (the cap these cases pin), the 999-unit
  # rewrites take 23M-26M, about 300 ms here, which the old 500 ms bound let
  # through; this budget does not.
  @caps_at_once 20_000_000

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

    # The port's diff has no deadline: past its bounds it is not run, and
    # the answer is a clash, at once.
    test "merge3_clash: a 50 KB text, or a long rewrite, is a clash at once" do
      body = String.duplicate("alpha beta gamma delta. ", 2_000)
      mid = div(byte_size(body), 2)
      rewrite = String.duplicate("Q", 20_000)

      ours =
        binary_part(body, 0, mid - 10_000) <>
          rewrite <> binary_part(body, mid + 10_000, mid - 10_000)

      small = binary_part(body, 0, 30_000)
      small_ours = binary_part(small, 0, 15_000) <> "!" <> binary_part(small, 15_000, 15_000)
      # Under the unit limit, a 2,000-character rewrite.
      short = binary_part(body, 0, 15_000)

      short_ours =
        binary_part(short, 0, 6_500) <>
          String.duplicate("Q", 2_000) <> binary_part(short, 8_500, 6_500)

      for {base, ours, theirs} <- [
            {body, ours, "B " <> body},
            {small, small_ours, "B " <> small},
            {short, short_ours, "B " <> short}
          ] do
        assert TextRebase.merge3_both(base, ours, theirs) != nil
        {work, result} = work(fn -> TextRebase.merge3_clash(base, ours, theirs) end)
        assert result == nil
        assert work < @clash_at_once, "took #{work} reductions"
      end
    end

    # Short repeated structure makes many diff parts: the clash check stays
    # within its work budget on it, at the caps and past them.
    test "merge3_clash: repeated text, a table, a rewrite at the caps: an answer at once" do
      cat = String.duplicate("the cat sat. ", 1_531) |> String.slice(0, 19_900)

      table =
        Enum.map_join(1..1_100, "", fn i -> "| #{i} | item | ok |\n" end)
        |> String.slice(0, 13_900)

      prose = String.duplicate("alpha beta gamma delta epsilon zeta ", 40)

      splice = fn text, from, n ->
        String.slice(text, 0, from) <>
          String.slice(prose, 0, n) <> String.slice(text, from + n, String.length(text))
      end

      for {text, n} <- [
            {cat, 999},
            {table, 999},
            {cat, 250},
            {table, 250},
            {cat, 700},
            {table, 700}
          ] do
        ours = splice.(text, 9_000, n)
        {work, _result} = work(fn -> TextRebase.merge3_clash(text, ours, "B " <> text) end)
        assert work < @caps_at_once, "#{n} took #{work} reductions"
      end
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
