defmodule Barkpark.Content.ValueUndoTest do
  @moduledoc """
  `ValueUndo`: one editor's change of any value taken back out of what the
  store holds now, another editor's changes since kept (TanStack's
  `revert`, `revertSteps`, `mergeList3`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.ValueUndo

  defp card(key, label), do: %{"_key" => key, "_type" => "card", "label" => label}

  describe "a value no one else changed since" do
    test "comes back, whatever its kind" do
      assert ValueUndo.revert("c", "b", "c") == "b"
      assert ValueUndo.revert(3, 2, 3) == 2
      assert ValueUndo.revert(true, false, true) == false

      assert ValueUndo.revert([card("c2", "Two")], [card("c1", "One"), card("c2", "Two")], [
               card("c2", "Two")
             ]) ==
               [card("c1", "One"), card("c2", "Two")]
    end
  end

  describe "a select (or any scalar) someone else changed since" do
    test "stays theirs" do
      assert ValueUndo.revert("c", "b", "a") == "a"
      assert ValueUndo.revert(3, 2, 7) == 7
      assert ValueUndo.revert_steps([{"c", "b"}], "a") == "a"
    end
  end

  describe "text" do
    test "unapplies where this editor's words still are, theirs kept" do
      assert ValueUndo.revert("my-slug-x", "my-slug", "their-my-slug-x") == "their-my-slug"
    end
  end

  describe "a keyed list" do
    test "an item this editor removed comes back after the one it followed; theirs stays" do
      before = [card("c1", "One"), card("c2", "Two")]
      after_ = [card("c2", "Two")]
      theirs = [card("c2", "Two"), card("r", "Remote")]

      assert ValueUndo.revert(after_, before, theirs) ==
               [card("c1", "One"), card("c2", "Two"), card("r", "Remote")]

      middle = [card("a", "A"), card("b", "B"), card("c", "C")]

      assert ValueUndo.revert([card("a", "A"), card("c", "C")], middle, [
               card("c", "C"),
               card("a", "A")
             ]) ==
               [card("c", "C"), card("a", "A"), card("b", "B")]
    end

    test "an item this editor added goes, unless someone changed it since" do
      before = [card("c1", "One")]
      after_ = [card("c1", "One"), card("n", "New")]

      assert ValueUndo.revert(after_, before, [card("r", "Remote") | after_]) ==
               [card("r", "Remote"), card("c1", "One")]

      changed = [card("c1", "One"), card("n", "New, theirs")]
      assert ValueUndo.revert(after_, before, changed) == changed
    end

    test "an item both changed is reverted key by key: their key stays, mine comes back" do
      before = [%{"_key" => "k", "label" => "One", "note" => "n"}]
      after_ = [%{"_key" => "k", "label" => "One!", "note" => "n"}]
      theirs = [%{"_key" => "k", "label" => "One!", "note" => "theirs"}]

      assert ValueUndo.revert(after_, before, theirs) == [
               %{"_key" => "k", "label" => "One", "note" => "theirs"}
             ]
    end

    test "an empty list on either side is still a keyed list" do
      assert ValueUndo.revert([card("c1", "One")], [], [card("c1", "One"), card("r", "R")]) ==
               [card("r", "R")]

      assert ValueUndo.revert([], [card("c1", "One")], [card("r", "R")]) ==
               [card("c1", "One"), card("r", "R")]
    end
  end

  describe "a list of plain values" do
    test "what this editor added goes, what it removed comes back, theirs stays" do
      assert ValueUndo.revert(["red", "blue"], ["red"], ["red", "blue", "green"]) == [
               "red",
               "green"
             ]

      assert ValueUndo.revert(["blue"], ["red", "blue"], ["blue", "green"]) == [
               "red",
               "blue",
               "green"
             ]
    end
  end

  describe "an object (nested fields)" do
    test "each key this editor changed comes back; a sibling key someone else changed stays" do
      before = %{"street" => "Main 1", "city" => "Oslo"}
      after_ = %{"street" => "Main 12", "city" => "Oslo"}
      theirs = %{"street" => "Main 12", "city" => "Bergen"}

      assert ValueUndo.revert(after_, before, theirs) == %{
               "street" => "Main 1",
               "city" => "Bergen"
             }
    end

    test "a key this editor added goes; one it cleared comes back" do
      assert ValueUndo.revert(%{"a" => "1", "b" => "x"}, %{"a" => "1"}, %{"a" => "2", "b" => "x"}) ==
               %{"a" => "2"}

      assert ValueUndo.revert(%{"a" => "1"}, %{"a" => "1", "b" => "x"}, %{"a" => "2"}) ==
               %{"a" => "2", "b" => "x"}
    end
  end

  describe "steps" do
    test "all or nothing: a step someone else changed under leaves the whole change" do
      steps = [{"b", "c"}, {"c", "d"}]
      # Undo: last first, each to -> from.
      undo = steps |> Enum.reverse() |> Enum.map(fn {a, b} -> {b, a} end)
      assert ValueUndo.revert_steps(undo, "d") == "b"
      assert ValueUndo.revert_steps(undo, "x") == "x"
    end
  end
end
