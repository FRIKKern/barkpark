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

    test "overlapping changes keep the text of both" do
      merged = TextRebase.merge3("abcdef", "abXef", "aYdef")
      assert merged == "aYdbXef"
      assert String.contains?(merged, "X") and String.contains?(merged, "Y")
    end

    test "a letter is never cut from its accent" do
      base = "café"
      assert TextRebase.merge3(base, base <> " noir", "Le " <> base) == "Le café noir"
    end
  end

  describe "rebase/3" do
    test "a post nearest an older value is merged onto the stored one" do
      params = %{"title" => "Post A7", "excerpt" => "x"}
      bases = %{"title" => ["Post"]}

      assert TextRebase.rebase(params, bases, %{"title" => "Post B3"}) ==
               %{"title" => "Post B3 A7", "excerpt" => "x"}
    end

    test "a post nearest the stored value stands: the editor had taken it" do
      params = %{"title" => "Post B3 A7"}

      assert TextRebase.rebase(params, %{"title" => ["Post", "Post B3"]}, %{"title" => "Post B3"}) ==
               params
    end

    test "a post equal to an older value keeps the stored one" do
      assert TextRebase.rebase(%{"excerpt" => "First"}, %{"excerpt" => ["First"]}, %{
               "excerpt" => "First B1"
             }) == %{"excerpt" => "First B1"}
    end

    test "no older value, or no strings: as posted" do
      assert TextRebase.rebase(%{"t" => "a"}, %{"t" => ["b"]}, %{"t" => "b"}) == %{"t" => "a"}
      assert TextRebase.rebase(%{"t" => "a"}, %{"t" => []}, %{"t" => "c"}) == %{"t" => "a"}
      assert TextRebase.rebase(%{"t" => ["a"]}, %{"t" => ["b"]}, %{"t" => "c"}) == %{"t" => ["a"]}
      assert TextRebase.rebase(%{"t" => "a"}, %{"t" => ["b"]}, %{"t" => nil}) == %{"t" => "a"}
    end
  end
end
