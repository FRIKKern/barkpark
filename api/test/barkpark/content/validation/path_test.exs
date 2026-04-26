defmodule Barkpark.Content.Validation.PathTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation.Path, as: VPath

  describe "parse/1" do
    test "root path" do
      assert {:ok, []} = VPath.parse("")
      assert {:ok, []} = VPath.parse("/")
    end

    test "object key" do
      assert {:ok, ["foo"]} = VPath.parse("/foo")
    end

    test "nested object key" do
      assert {:ok, ["foo", "bar"]} = VPath.parse("/foo/bar")
    end

    test "array index" do
      assert {:ok, ["items", 2]} = VPath.parse("/items/2")
    end

    test "wildcard" do
      assert {:ok, ["items", :wildcard, "tag"]} = VPath.parse("/items/*/tag")
    end

    test "RFC 6901 escapes" do
      assert {:ok, ["a/b"]} = VPath.parse("/a~1b")
      assert {:ok, ["a~b"]} = VPath.parse("/a~0b")
    end

    test "rejects relative paths" do
      assert {:error, :must_start_with_slash} = VPath.parse("foo")
    end
  end

  describe "resolve/2 — non-wildcard" do
    test "returns one tuple with the value" do
      assert [{"/title", "Hello"}] = VPath.resolve("/title", %{"title" => "Hello"})
    end

    test "supports atom-keyed maps" do
      assert [{"/title", "Hello"}] = VPath.resolve("/title", %{title: "Hello"})
    end

    test "missing keys yield nil" do
      assert [{"/title", nil}] = VPath.resolve("/title", %{"other" => 1})
    end

    test "drilling through scalar yields nil" do
      assert [{"/foo", nil}] = VPath.resolve("/foo/bar", %{"foo" => "scalar"})
    end

    test "array index" do
      assert [{"/items/1", "b"}] = VPath.resolve("/items/1", %{"items" => ["a", "b", "c"]})
    end

    test "missing array index yields nil" do
      assert [{"/items/9", nil}] = VPath.resolve("/items/9", %{"items" => ["a"]})
    end
  end

  describe "resolve/2 — wildcard expansion" do
    test "expands every array element with concrete index in path" do
      doc = %{"items" => [%{"tag" => "x"}, %{"tag" => "y"}]}

      assert [
               {"/items/0/tag", "x"},
               {"/items/1/tag", "y"}
             ] = VPath.resolve("/items/*/tag", doc)
    end

    test "wildcard parent missing → empty list" do
      assert [] = VPath.resolve("/items/*/tag", %{"other" => 1})
    end

    test "wildcard parent not a list → empty list" do
      assert [] = VPath.resolve("/items/*/tag", %{"items" => "scalar"})
    end

    test "nested wildcards" do
      doc = %{"groups" => [%{"items" => [1, 2]}, %{"items" => [3]}]}

      assert [
               {"/groups/0/items/0", 1},
               {"/groups/0/items/1", 2},
               {"/groups/1/items/0", 3}
             ] = VPath.resolve("/groups/*/items/*", doc)
    end

    test "concrete path replaces wildcards with integer indices" do
      doc = %{"items" => [%{"v" => 10}]}
      assert [{"/items/0/v", 10}] = VPath.resolve("/items/*/v", doc)
    end
  end
end
