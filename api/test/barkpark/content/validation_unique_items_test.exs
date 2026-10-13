defmodule Barkpark.Content.ValidationUniqueItemsTest do
  # Sanity's `Rule.unique()` on an array, with the message editors see
  # (task-bd4b556125fe702e: the Agency studio's `illustrators` must not list the
  # same person twice).
  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation

  @schema %{
    "name" => "book",
    "fields" => [
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "illustrators",
        "type" => "arrayOf",
        "validation" => %{"unique" => true, "message" => "En illustratør kan bare stå én gang."},
        "of" => %{"type" => "reference", "refType" => "person"}
      },
      %{
        "name" => "tags",
        "type" => "arrayOf",
        "validation" => %{"unique" => true},
        "of" => %{"type" => "string"}
      },
      %{"name" => "notes", "type" => "arrayOf", "of" => %{"type" => "string"}}
    ]
  }

  defp errors(content), do: Validation.check(content, "Bok", @schema).errors

  test "the same reference twice is one finding, in the schema's own words" do
    content = %{
      "illustrators" => [
        %{"_key" => "a", "_ref" => "person-1"},
        %{"_key" => "b", "_ref" => "person-2"},
        %{"_key" => "c", "_ref" => "person-1"}
      ]
    }

    assert Map.get(errors(content), "illustrators") == ["En illustratør kan bare stå én gang."]
  end

  test "different references, and rows told apart only by _key, are judged by what they hold" do
    assert Map.get(
             errors(%{
               "illustrators" => [
                 %{"_key" => "a", "_ref" => "p1"},
                 %{"_key" => "b", "_ref" => "p2"}
               ]
             }),
             "illustrators"
           ) == nil

    assert Map.get(errors(%{"tags" => ["a", "b", "a"]}), "tags") == ["Items must be unique"]
    assert Map.get(errors(%{"tags" => ["a", "b"]}), "tags") == nil
  end

  test "an array without the rule is not judged for duplicates" do
    assert Map.get(errors(%{"notes" => ["same", "same"]}), "notes") == nil
  end
end
