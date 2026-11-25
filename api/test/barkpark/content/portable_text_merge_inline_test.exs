defmodule Barkpark.Content.PortableTextMergeInlineTest do
  @moduledoc """
  The merge inside one block, text only (`PortableTextMerge.Inline`,
  task-da701626f5be2143, plan /papers/pt-merge-inside-one-block rev 4).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge.Inline

  defp span(key, text, marks \\ []),
    do: %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks}

  defp block(key, spans, defs \\ []) when is_list(spans),
    do: %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => defs,
      "children" => spans
    }

  defp b(text, key \\ "k"), do: block(key, [span(key <> "s", text)])
  defp text(%{"children" => cs}), do: Enum.map_join(cs, & &1["text"])

  test "disjoint words of one block merge: ONE two THREE" do
    assert {:ok, blk} =
             Inline.merge(b("one two three"), b("ONE two three", "p0"), b("one two THREE"))

    assert text(blk) == "ONE two THREE" and blk["_key"] == "k"
  end

  test "the old disjoint fixture pair merges: B one two A" do
    assert {:ok, blk} = Inline.merge(b("one two"), b("one two A"), b("B one two"))
    assert text(blk) == "B one two A"
  end

  test "a kana commit after theirs took an earlier word out" do
    assert {:ok, blk} = Inline.merge(b("one two。"), b("one two。かな"), b("two。"))
    assert text(blk) == "two。かな"
  end

  test "both type \"the\", in different sentences" do
    base = b("cat sat. dog ran.")
    assert {:ok, blk} = Inline.merge(base, b("the cat sat. dog ran."), b("cat sat. the dog ran."))
    assert text(blk) == "the cat sat. the dog ran."
  end

  test "theirs' spans outside mine's splice keep their maps; stored defs stay, used or not" do
    def = %{"_key" => "d1", "_type" => "link", "href" => "https://x.example"}
    unused = %{"_key" => "d9", "_type" => "link", "href" => "https://unused.example"}
    s1 = span("t1", "one ", ["strong"]) |> Map.put("x-extra", 1)
    s2 = span("t2", "two ", ["d1"])
    theirs = block("k", [s1, s2, span("t3", "three FOUR")], [def, unused])

    base =
      block(
        "k",
        [
          span("b1", "one ", ["strong"]) |> Map.put("x-extra", 1),
          span("b2", "two ", ["d1"]),
          span("b3", "three four")
        ],
        [def, unused]
      )

    mine =
      block(
        "p0",
        [
          span("p0s0", "one ", ["strong"]) |> Map.put("x-extra", 1),
          span("p0s1", "two ", ["p0m0"]),
          span("p0s2", "THREE four")
        ],
        [%{def | "_key" => "p0m0"}]
      )

    assert {:ok, blk} = Inline.merge(base, mine, theirs)
    assert [^s1, ^s2, %{"_key" => "t3", "text" => "THREE FOUR"}] = blk["children"]
    assert blk["markDefs"] == [def, unused] and blk["_key"] == "k"
  end

  test "a custom block both changed, or text one side made an image, clashes without raising" do
    img = fn k, a -> %{"_type" => "image", "_key" => k, "alt" => a} end
    assert Inline.merge(img.("i", "a"), img.("i", "b"), img.("i", "c")) == :clash
    assert Inline.merge(b("one two"), img.("p0", "x"), b("one TWO")) == :clash
  end

  describe "a clash" do
    test "both edit \"two\"",
      do:
        assert(
          Inline.merge(b("one two three"), b("one TWO three"), b("one twoo three")) == :clash
        )

    test "both put text in at one point",
      do: assert(Inline.merge(b("one two"), b("one X two"), b("one Y two")) == :clash)

    test "cart: carts and dart",
      do: assert(Inline.merge(b("cart is"), b("carts is"), b("dart is")) == :clash)

    test "たべる: たべた and のべる", do: assert(Inline.merge(b("たべる"), b("たべた"), b("のべる")) == :clash)

    test "touching ranges",
      do:
        assert(Inline.merge(b("one two three"), b("ONE two three"), b("onetwo three")) == :clash)

    test "a mark only, or a mark of its own put in" do
      assert Inline.merge(
               b("one two three"),
               block("k", [span("a", "one", ["strong"]), span("b", " two three")]),
               b("one two THREE")
             ) == :clash

      assert Inline.merge(
               b("one two three"),
               block("k", [span("a", "one two "), span("b", "new", ["em"]), span("c", " three")]),
               b("ONE two three")
             ) == :clash
    end

    test "a block field either side changed" do
      assert Inline.merge(
               b("one two three"),
               Map.put(b("ONE two three"), "style", "h2"),
               b("one two THREE")
             ) == :clash
    end

    test "a flag made where mine's letters meet theirs' next span" do
      base = block("k", [span("a", "x "), span("b", "🇴 two three", ["strong"])])
      mine = block("k", [span("a", "x 🇳"), span("b", "🇴 two three", ["strong"])])
      theirs = block("k", [span("a", "x "), span("b", "🇴 two THREE", ["strong"])])
      assert Inline.merge(base, mine, theirs) == :clash
    end
  end
end
