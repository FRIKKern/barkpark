defmodule Barkpark.Content.TextRebaseTest do
  @moduledoc """
  task-e6ef964ac2e41d5a: a post written from an older value than the store
  holds keeps the other editor's words.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.TextRebase

  describe "merge3/3" do
    test "one side unchanged: the other side's text" do
      assert TextRebase.merge3("abc", "abc", "abXc") == "abXc"
      assert TextRebase.merge3("abc", "abYc", "abc") == "abYc"
      assert TextRebase.merge3("abc", "same", "same") == "same"
    end

    test "changes apart from each other: both apply" do
      assert TextRebase.merge3("Hello world", "Hello big world", "Hello world!") ==
               "Hello big world!"

      assert TextRebase.merge3("Hello world", "Hello world!", "Hi world") == "Hi world!"
    end

    test "two inserts at the same point: the stored one first" do
      assert TextRebase.merge3(
               "Fixture post A2 A5",
               "Fixture post A2 A5 A7",
               "Fixture post A2 A5 B3"
             ) ==
               "Fixture post A2 A5 B3 A7"
    end

    # #25994 review: keeping the text of both brought deleted words back.
    test "overlapping changes give ours, the last post, deletions kept" do
      assert TextRebase.merge3("abcdef", "abXef", "aYdef") == "abXef"

      assert TextRebase.merge3("one two three four", "one four", "one TWO three four") ==
               "one four"
    end

    test "an insert touching ours' splice that ours already holds stands" do
      assert TextRebase.merge3("Fixture post B1", "Fixture B2 post B1 x", "Fixture B2 post B1") ==
               "Fixture B2 post B1 x"

      # Not held by ours: both changes still apply.
      assert TextRebase.merge3("Hello world", "Hello world!", "Hello earth") == "Hello earth!"

      assert TextRebase.merge3("Hello world", "Hello big world", "Hello world!") ==
               "Hello big world!"
    end

    test "an insert at the same point that already holds theirs' insert stands" do
      assert TextRebase.merge3(
               "Fixture post B1",
               "Fixture post B1 B2 x",
               "Fixture post B1 B2"
             ) == "Fixture post B1 B2 x"
    end

    test "a letter is never cut from its accent" do
      base = "café"
      assert TextRebase.merge3(base, base <> " noir", "Le " <> base) == "Le café noir"
    end
  end

  describe "rebase/3" do
    test "a post edited from an older value is merged onto the stored one" do
      params = %{"title" => "Post A7", "excerpt" => "x"}

      assert TextRebase.rebase(params, %{"title" => "Post"}, %{"title" => "Post B3"}) ==
               %{"title" => "Post B3 A7", "excerpt" => "x"}
    end

    test "a post edited from the stored value stands, deletions included" do
      # The page had taken B's save and deleted it: the store holds the base.
      assert TextRebase.rebase(%{"title" => "Post!"}, %{"title" => "Post B3"}, %{
               "title" => "Post B3"
             }) == %{"title" => "Post!"}

      assert TextRebase.rebase(%{"title" => "New title"}, %{"title" => "Post B3"}, %{
               "title" => "Post B3"
             }) == %{"title" => "New title"}
    end

    test "a post that left the field at its base keeps the stored value" do
      assert TextRebase.rebase(%{"excerpt" => "First"}, %{"excerpt" => "First"}, %{
               "excerpt" => "First B1"
             }) == %{"excerpt" => "First B1"}
    end

    test "no base, or no strings: as posted" do
      assert TextRebase.rebase(%{"t" => "a"}, %{}, %{"t" => "c"}) == %{"t" => "a"}
      assert TextRebase.rebase(%{"t" => "a"}, %{"t" => nil}, %{"t" => "c"}) == %{"t" => "a"}
      assert TextRebase.rebase(%{"t" => ["a"]}, %{"t" => "b"}, %{"t" => "c"}) == %{"t" => ["a"]}
      assert TextRebase.rebase(%{"t" => "a"}, %{"t" => "b"}, %{"t" => nil}) == %{"t" => "a"}
    end

    test "above the size bound a post stands as sent, and quickly" do
      big = String.duplicate("x", TextRebase.max_bytes() + 1)
      params = %{"body" => big <> " A"}

      {us, result} =
        :timer.tc(fn ->
          TextRebase.rebase(params, %{"body" => big}, %{"body" => "B " <> big})
        end)

      assert result == params
      assert us < 50_000
    end
  end

  # task-5b8f13c40a052514: `seen`, the value the tab believed stored.
  describe "rebase/4 with what the tab believed stored" do
    test "the store moved from it under the post: an overlap keeps the store" do
      seen = %{"notes" => "one two three"}
      stored = %{"notes" => "one twB three"}

      assert TextRebase.rebase(%{"notes" => "one twA three"}, %{}, stored, seen) ==
               %{"notes" => "one twB three"}
    end

    test "the store moved from it: edits apart merge, with no base from the page" do
      assert TextRebase.rebase(
               %{"notes" => "ONE two three"},
               %{},
               %{"notes" => "one two THREE"},
               %{"notes" => "one two three"}
             ) == %{"notes" => "ONE two THREE"}
    end

    test "the store still holds it (the tab was told): an overlap is ours, as before" do
      bases = %{"notes" => "one two three"}
      stored = %{"notes" => "one twB three"}

      assert TextRebase.rebase(%{"notes" => "one twA three"}, bases, stored, stored) ==
               %{"notes" => "one twA three"}
    end

    test "a path into an object, and a post that left the field as it was" do
      seen = %{["meta", "label"] => "a b"}
      stored = %{"meta" => %{"label" => "a B"}}

      assert TextRebase.rebase(%{"meta" => %{"label" => "a b"}}, %{}, stored, seen) ==
               %{"meta" => %{"label" => "a B"}}
    end
  end
end
