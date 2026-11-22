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
    test "free text unapplies where this editor's words still are, theirs kept" do
      for field <- [%{"type" => "text"}, %{"type" => "string"}] do
        assert ValueUndo.revert("Main 12", "Main 1", "Their Main 12", field) == "Their Main 1"
      end
    end

    # task-0b9061cb95e89484 review B1: text-merged, two picks made a value neither
    # editor chose ("small" from "x-large" over "x-small").
    test "any other string is one value: changed since, it stays theirs" do
      select = %{
        "type" => "select",
        "options" => [%{"value" => "small"}, %{"value" => "x-small"}]
      }

      assert ValueUndo.revert("x-large", "large", "x-small", select) == "x-small"
      assert ValueUndo.revert_steps([{"x-large", "large"}], "x-small", select) == "x-small"

      options = %{"type" => "string", "options" => %{"list" => ["draft", "draft_2", "in_review"]}}
      assert ValueUndo.revert("in_review", "draft", "in_review_2", options) == "in_review_2"

      listed = %{"type" => "string", "options" => [%{"value" => "a"}, %{"value" => "ab"}]}
      assert ValueUndo.revert("ab", "a", "abb", listed) == "abb"

      for type <- ~w(slug date datetime codelist) do
        assert ValueUndo.revert("2026-11-21", "2026-11-20", "2026-12-21", %{"type" => type}) ==
                 "2026-12-21"
      end

      # A field the schema does not name is not free text either.
      assert ValueUndo.revert("my-slug-x", "my-slug", "their-my-slug-x") == "their-my-slug-x"
    end

    test "nested: an object's date or datetime and a slug's current stay theirs, its free text merges" do
      event = %{
        "type" => "composite",
        "fields" => [
          %{"name" => "place", "type" => "string"},
          %{"name" => "on", "type" => "date"},
          %{"name" => "at", "type" => "datetime"}
        ]
      }

      mine = %{"place" => "Oslo", "on" => "2026-11-21", "at" => "2026-11-20T10:30"}
      was = %{"place" => "Oslo", "on" => "2026-11-20", "at" => "2026-11-20T10:00"}
      theirs = %{"place" => "Oslo", "on" => "2026-12-21", "at" => "2026-11-21T11:30"}
      assert ValueUndo.revert(mine, was, theirs, event) == theirs

      assert ValueUndo.revert(
               %{"place" => "Oslo S"},
               %{"place" => "Oslo"},
               %{"place" => "Gamle Oslo S"},
               event
             ) == %{"place" => "Gamle Oslo"}

      slug = %{"type" => "slug"}

      assert ValueUndo.revert(
               %{"_type" => "slug", "current" => "a-x"},
               %{"_type" => "slug", "current" => "a"},
               %{"_type" => "slug", "current" => "b-a-x"},
               slug
             ) == %{"_type" => "slug", "current" => "b-a-x"}
    end

    test "a list item's codelist code stays theirs; its free text merges" do
      cards = %{
        "type" => "arrayOf",
        "of" => %{
          "type" => "composite",
          "name" => "card",
          "fields" => [
            %{"name" => "label", "type" => "string"},
            %{"name" => "code", "type" => "codelist"}
          ]
        }
      }

      mine = [%{"_key" => "k", "label" => "One!", "code" => "AB"}]
      was = [%{"_key" => "k", "label" => "One", "code" => "A"}]

      assert ValueUndo.revert(
               mine,
               was,
               [%{"_key" => "k", "label" => "One!", "code" => "ABC"}],
               cards
             ) ==
               [%{"_key" => "k", "label" => "One", "code" => "ABC"}]
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

  describe "a list with no keys" do
    test "what this editor added goes, what it removed comes back, theirs added at the end stays" do
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

    # task-0b9061cb95e89484 review B4: put back by index, "two" landed before "one".
    test "another editor's item before mine moves positions: the step does nothing" do
      before = ["one", "two", "three"]
      theirs = ["zero", "one", "three"]
      assert ValueUndo.revert(["one", "three"], before, theirs) == theirs
      assert ValueUndo.revert_steps([{["one", "three"], before}], theirs) == theirs

      retyped = ["one", "two!", "three"]
      assert ValueUndo.revert(retyped, before, ["zero" | retyped]) == ["zero" | retyped]

      # Objects with no `_key`, the same.
      a = [%{"label" => "A"}, %{"label" => "B"}]

      assert ValueUndo.revert(a, [%{"label" => "A"}], [%{"label" => "R"} | a]) == [
               %{"label" => "R"} | a
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
