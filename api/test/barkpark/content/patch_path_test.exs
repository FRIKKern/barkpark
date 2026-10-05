defmodule Barkpark.Content.PatchPathTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.PatchPath

  test "path? is true only for keys with . or [" do
    assert PatchPath.path?("seo.metaTitle")
    assert PatchPath.path?("tags[0]")
    refute PatchPath.path?("seo")
    refute PatchPath.path?(:seo)
  end

  test "parse handles keys, double- and single-quoted _key selectors and indexes" do
    assert PatchPath.parse(~s(body[_key=="b1"].text)) ==
             {:ok, [{:key, "body"}, {:keyed, "b1"}, {:key, "text"}]}

    assert PatchPath.parse("body[_key=='b1']") == {:ok, [{:key, "body"}, {:keyed, "b1"}]}
    assert PatchPath.parse("tags[-1]") == {:ok, [{:key, "tags"}, {:index, -1}]}
    assert PatchPath.parse("a.b.c") == {:ok, [{:key, "a"}, {:key, "b"}, {:key, "c"}]}
  end

  test "parse refuses malformed paths" do
    for bad <- ["", ".a", "a.", "a..b", "a[", "a[_key=b]", "a[x]", "[0]", "a]b"] do
      assert {:error, msg} = PatchPath.parse(bad)
      assert msg =~ "is not valid"
    end
  end

  test "root names the top-level field" do
    assert PatchPath.root(~s(body[_key=="b1"].text)) == "body"
    assert PatchPath.root("seo.metaTitle") == "seo"
  end

  test "an out-of-range index is unmatched, not an error" do
    {:ok, segs} = PatchPath.parse("tags[5]")
    assert PatchPath.update(%{"tags" => [1]}, segs, true, fn _ -> {:put, 2} end) == :unmatched
  end
end
