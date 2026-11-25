defmodule Barkpark.Content.PortableTextMergeInlineTest do
  @moduledoc """
  The merge inside one block, text and marks (`PortableTextMerge.Inline`,
  task-da701626f5be2143, plan /papers/pt-merge-inside-one-block rev 4).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M
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
  defp texts({:ok, blocks}), do: Enum.map(blocks, &text/1)
  # Each span as {text, marks}, a link by its def's href.
  defp runs(%{"children" => cs} = blk) do
    hrefs = Map.new(List.wrap(blk["markDefs"]), &{&1["_key"], &1["href"]})
    Enum.map(cs, &{&1["text"], Enum.map(&1["marks"], fn m -> hrefs[m] || m end)})
  end

  test "disjoint words of one block merge: ONE two THREE" do
    assert {:ok, blk} =
             Inline.merge(b("one two three"), b("ONE two three", "p0"), b("one two THREE"))

    assert text(blk) == "ONE two THREE" and blk["_key"] == "k"
  end

  test "the old disjoint fixture pair merges either way round, in one span: B one two A" do
    assert {:ok, blk} = Inline.merge(b("one two"), b("one two A"), b("B one two"))
    assert [%{"_key" => "ks", "text" => "B one two A"}] = blk["children"]
    assert {:ok, blk} = Inline.merge(b("one two"), b("B one two"), b("one two A"))
    assert [%{"_key" => "ks", "text" => "B one two A"}] = blk["children"]
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

  test "a word mine took out of theirs' span leaves one span, keyed as theirs" do
    assert {:ok, blk} =
             Inline.merge(b("one two three four"), b("one three four"), b("one two three FOUR"))

    assert [%{"_key" => "ks", "text" => "one three FOUR"}] = blk["children"]
  end

  test "mine's runs between two spans: a key theirs holds is not reused" do
    base = block("k", [span("a", "one "), span("b", "two three", ["strong"])])
    theirs = block("k", [span("a", "one "), span("b", "two THREE", ["strong"])])

    mine =
      block("k", [
        span("x0", "one "),
        span("a", "X", ["strong"]),
        span("b", "Y"),
        span("x1", "two three", ["strong"])
      ])

    assert {:ok, blk} = Inline.merge(base, mine, theirs)

    assert Enum.map(blk["children"], &{&1["_key"], &1["text"]}) ==
             [{"a", "one "}, {"ki0", "X"}, {"ki1", "Y"}, {"b", "two THREE"}]
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

    test "an edit beside a word reaches into it",
      do:
        assert(Inline.merge(b("one two three"), b("ONE two three"), b("onetwo three")) == :clash)

    test "ranges that touch with no letter between: one .. two",
      do: assert(Inline.merge(b("one .. two"), b("one !. two"), b("one .? two")) == :clash)

    # task-07d2ca9aa7667208: a mark is part of the splice; across the
    # other side's edit it clashes.
    test "mine bolds one two three while theirs rewrites two" do
      assert Inline.merge(
               b("one two three"),
               block("k", [span("a", "one two three", ["strong"])]),
               b("one TWO three")
             ) == :clash
    end

    test "a block over TextRebase.max_bytes/0 of text" do
      text = String.duplicate("word ", div(Barkpark.Content.TextRebase.max_bytes(), 5) + 1)
      assert Inline.merge(b(text), b("FIRST " <> text), b(text <> "LAST")) == :clash
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

  describe "#28761 review" do
    # task-07d2ca9aa7667208: a mark change inside a text splice is mine's
    # (both were a clash before marks merged).
    test "a mark change riding inside a text splice merges apart from theirs': a bold put on" do
      base = block("k", [span("a", "ONE", ["strong"]), span("b", " two three four")])

      mine =
        block("k", [
          span("a", "ONE", ["strong"]),
          span("c", " TWO three", ["strong"]),
          span("b", " four")
        ])

      theirs = block("k", [span("a", "ONE", ["strong"]), span("b", " two three FOUR")])
      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert runs(blk) == [{"ONE TWO three", ["strong"]}, {" FOUR", []}]
    end

    test "a mark change riding inside a text splice merges apart from theirs': a bold taken off" do
      base =
        block("k", [span("a", "one two "), span("b", "THREE", ["strong"]), span("c", " four")])

      mine = block("k", [span("a", "one TWO THREE four")])

      theirs =
        block("k", [span("a", "one two "), span("b", "THREE", ["strong"]), span("c", " FOUR")])

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert runs(blk) == [{"one TWO THREE", []}, {" FOUR", []}]
    end

    test "typing on at the end of a bold word still merges" do
      base = block("k", [span("a", "ONE", ["strong"]), span("b", " two")])
      mine = block("k", [span("a", "ONEx", ["strong"]), span("b", " two")])
      theirs = block("k", [span("a", "ONE", ["strong"]), span("b", " TWO")])
      assert {:ok, blk} = Inline.merge(base, mine, theirs)

      assert Enum.map(blk["children"], &{&1["text"], &1["marks"]}) == [
               {"ONEx", ["strong"]},
               {" TWO", []}
             ]
    end

    for {name, base, mine, theirs} <- [
          {"a decimal", "pi 3.14 now", "pi 4.14 now", "pi 3.15 now"},
          {"a price", "costs 1,000 kr", "costs 2,000 kr", "costs 1,001 kr"},
          {"a time", "at 12:30 then", "at 12:35 then", "at 13:30 then"},
          {"a date", "on 2026-11-25 ok", "on 2026-11-26 ok", "on 2027-11-25 ok"},
          {"a date with slashes", "on 11/25/2026 ok", "on 11/26/2026 ok", "on 12/25/2026 ok"},
          {"a contraction", "we don't go", "we dan't go", "we don'tt go"},
          {"a hyphenated word", "an e-mail here", "an a-mail here", "an e-mails here"}
        ] do
      test "#{name} is one word: two edits in it clash" do
        assert Inline.merge(b(unquote(base)), b(unquote(mine)), b(unquote(theirs))) == :clash
      end
    end

    test "a sentence's full stop after a number is not inside it" do
      assert {:ok, blk} =
               Inline.merge(
                 b("cost 3. Then four"),
                 b("cost 4. Then four"),
                 b("cost 3. Then FOUR")
               )

      assert text(blk) == "cost 4. Then FOUR"
    end

    test "plain letters put inside theirs' bold span: the span's right piece takes a key of its own" do
      base = block("k", [span("a", "one two three", ["strong"]), span("b", " four")])

      mine =
        block("p0", [
          span("p0s0", "one ", ["strong"]),
          span("p0s1", "new "),
          span("p0s2", "two three", ["strong"]),
          span("p0s3", " four")
        ])

      theirs = block("k", [span("a", "one two three", ["strong"]), span("b", " FOUR")])
      assert {:ok, blk} = Inline.merge(base, mine, theirs)

      assert Enum.map(blk["children"], &{&1["_key"], &1["text"]}) ==
               [{"a", "one "}, {"p0s1", "new "}, {"ki0", "two three"}, {"b", " FOUR"}]
    end

    test "an inline object in the block is a clash" do
      obj = %{"_type" => "inlineImage", "_key" => "o1", "src" => "x.png"}
      with_obj = fn text -> block("k", [span("a", text), obj, span("c", " end")]) end

      assert Inline.merge(
               with_obj.("one two three"),
               with_obj.("ONE two three"),
               with_obj.("one two THREE")
             ) == :clash
    end

    test "a block of another _type, its fields the same, is a clash" do
      callout = &%{b(&1) | "_type" => "callout"}

      assert Inline.merge(
               callout.("one two three"),
               callout.("ONE two three"),
               callout.("one two THREE")
             ) == :clash
    end

    test "the same edit both sides, in spans cut another way: theirs, once" do
      theirs = block("k", [span("t1", "one "), span("t2", "TWO three")])
      assert Inline.merge(b("one two three"), b("one TWO three", "p0"), theirs) == {:ok, theirs}
    end

    test "the guard's count bound: a word more often than mine + theirs - base is refused" do
      [base, mine, theirs] = [b("the cat"), b("the cat"), b("the cat")]
      refute Inline.guard?(b("the the cat"), base, mine, theirs)
      assert Inline.guard?(b("the cat"), base, mine, theirs)
      assert Inline.guard?(b("the the cat"), base, b("the the cat"), theirs)
    end

    # 64 KB of text in 32,000 spans (#28761 review: 10.5 s and 75M before).
    test "a block at the cap in many spans stays linear" do
      spans = fn first, last ->
        for i <- 1..32_000 do
          t =
            cond do
              i == 1 -> first
              i == 32_000 -> last
              true -> "a "
            end

          span("s#{i}", t, if(rem(i, 2) == 0, do: ["em"], else: []))
        end
      end

      {base, mine, theirs} =
        {block("k", spans.("a ", "a ")), block("k", spans.("b ", "a ")),
         block("k", spans.("a ", "c "))}

      {:reductions, r0} = Process.info(self(), :reductions)
      assert {:ok, _} = Inline.merge(base, mine, theirs)
      {:reductions, r1} = Process.info(self(), :reductions)
      assert r1 - r0 < 30_000_000, "#{r1 - r0} reductions"
    end
  end

  describe "task-81d9efce3bbf6428: a mark change inside a splice" do
    # base: TWO bold, then " three four five"; theirs edits "five".
    defp marked(two, rest),
      do: block("k", [span("a", "one "), span("b", two, ["strong"]), span("c", rest)])

    defp theirs_five, do: marked("two", " three four FIVE")

    test "mine edits two and four and bolds three between them: merged, three bold" do
      mine =
        block("k", [
          span("a", "one "),
          span("b", "TWO three", ["strong"]),
          span("c", " FOUR five")
        ])

      assert {:ok, blk} = Inline.merge(marked("two", " three four five"), mine, theirs_five())
      assert runs(blk) == [{"one ", []}, {"TWO three", ["strong"]}, {" FOUR FIVE", []}]
    end

    test "mine edits two and four and unbolds a bold word between them: merged, unbolded" do
      base =
        block("k", [
          span("a", "one two "),
          span("b", "three", ["strong"]),
          span("c", " four five")
        ])

      theirs =
        block("k", [
          span("a", "one two "),
          span("b", "three", ["strong"]),
          span("c", " four FIVE")
        ])

      mine = block("k", [span("a", "one TWO three FOUR five")])
      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert runs(blk) == [{"one TWO three FOUR", []}, {" FIVE", []}]
    end

    test "mine edits two and four, marks kept: it merges" do
      mine = marked("TWO", " three FOUR five")
      assert {:ok, blk} = Inline.merge(marked("two", " three four five"), mine, theirs_five())
      assert text(blk) == "one TWO three FOUR FIVE"
    end

    # n letters "ab", every other pair bold; mine puts "xy" in their place,
    # same marks; theirs edits the tail.
    defp rewrite(n) do
      pairs = fn t, k ->
        for i <- 0..(div(n, 2) - 1),
            do: span("#{k}#{i}", t, if(rem(i, 2) == 0, do: ["strong"], else: []))
      end

      base = block("k", pairs.("ab", "b") ++ [span("t", " gap end")])

      {base, block("k", pairs.("xy", "m") ++ [span("t", " gap end")]),
       block("k", pairs.("ab", "b") ++ [span("t", " gap END")])}
    end

    # The letter diff that read marks kept is gone with task-07d2ca9aa7667208:
    # marks ride the splice, past the old cap too.
    test "a rewrite of mixed marks costs under 15M reductions, at the old cap and past it" do
      for n <- [500, 2_000] do
        {base, mine, theirs} = rewrite(n)
        {:reductions, r0} = Process.info(self(), :reductions)
        assert {:ok, blk} = Inline.merge(base, mine, theirs)
        {:reductions, r1} = Process.info(self(), :reductions)
        assert r1 - r0 < 15_000_000
        assert text(blk) == String.duplicate("xy", div(n, 2)) <> " gap END"
      end
    end

    # #28802 review B1 (the reviewer's save-path probe): mine and theirs
    # share base's span keys, so every run of mine takes a fresh key. A walk
    # from 0 per run cost 1,589M reductions (28 s) at 16,000 spans.
    test "the save path: mine flips the marks of 16,000 spans whose keys theirs shares, under 40M" do
      n = 16_000
      words = fn ms -> for i <- 0..(n - 1), do: span("s#{i}", "ab ", ms.(i)) end
      strong = fn r -> fn i -> if rem(i, 2) == r, do: ["strong"], else: [] end end
      base = [block("k", words.(strong.(0)) ++ [span("t", "gap end")])]
      mine = [block("k", words.(strong.(1)) ++ [span("t", "gap end")])]
      theirs = [block("k", words.(strong.(0)) ++ [span("t", "gap END")])]

      {:reductions, r0} = Process.info(self(), :reductions)
      result = M.merge(base, mine, theirs)
      {:reductions, r1} = Process.info(self(), :reductions)

      assert r1 - r0 < 40_000_000, "#{r1 - r0} reductions"
      assert {:ok, [blk]} = result
      assert text(blk) == String.duplicate("ab ", n) <> "gap END"
      keys = Enum.map(blk["children"], & &1["_key"])
      assert length(keys) == length(Enum.uniq(keys))
    end

    # S1: a key taken by content is looked up in a set, not in a list.
    test "30,000 links of mine, each its own key, one href theirs holds: under 20M" do
      n = 30_000
      x = link("d1", "https://x.example")
      base = block("k", [span("s", String.duplicate("a", n)), span("t", " end")], [x])

      mine =
        block(
          "k",
          for(i <- 0..(n - 1), do: span("m#{i}", "a", ["l#{i}"])) ++ [span("t", " end")],
          [x | for(i <- 0..(n - 1), do: link("l#{i}", "https://x.example"))]
        )

      theirs = block("k", [span("s", String.duplicate("a", n)), span("t", " END")], [x])

      {:reductions, r0} = Process.info(self(), :reductions)
      result = Inline.merge(base, mine, theirs)
      {:reductions, r1} = Process.info(self(), :reductions)

      assert r1 - r0 < 20_000_000, "#{r1 - r0} reductions"
      assert {:ok, blk} = result
      assert text(blk) == String.duplicate("a", n) <> " END"
    end

    test "a pure deletion or paste past the cap, marks mixed, merges: it keeps no letter" do
      {base, _mine, theirs} = rewrite(1002)
      tail = block("k", [span("t", " gap end")])
      assert {:ok, blk} = Inline.merge(base, tail, theirs)
      assert text(blk) == " gap END"

      # Mine pastes 1,002 letters of both marks before base's own.
      {_base, xy, _theirs} = rewrite(1002)
      paste = block("k", Enum.drop(xy["children"], -1) ++ base["children"])
      assert {:ok, blk} = Inline.merge(base, paste, theirs)
      assert text(blk) == String.duplicate("xy", 501) <> String.duplicate("ab", 501) <> " gap END"
    end

    test "a bold word typed new between two edits merges: no text of base changed marks" do
      mine =
        block("k", [
          span("a", "one "),
          span("b", "TWO NEW", ["strong"]),
          span("c", " three FOUR five")
        ])

      assert {:ok, blk} = Inline.merge(marked("two", " three four five"), mine, theirs_five())
      assert text(blk) == "one TWO NEW three FOUR FIVE"
    end
  end

  describe "task-5d102d5baa016e0a: a word is a run with no space" do
    for {name, base, mine, theirs} <- [
          {"a domain", "see example.com now", "see exampel.com now", "see example.org now"},
          {"a slash pair", "use a/b here", "use A/b here", "use a/B here"},
          {"a letter and a digit", "is x-1 ok", "is y-1 ok", "is x-2 ok"},
          {"an ellipsis between digits", "from 1...2 on", "from 0...2 on", "from 1...3 on"},
          {"a quoted word", ~s(say "hi" now), ~s(say "hu" now), ~s(say "hi!" now)}
        ] do
      test "#{name} is one word: two edits in it clash" do
        assert Inline.merge(b(unquote(base)), b(unquote(mine)), b(unquote(theirs))) == :clash
      end
    end

    test "edits in two words that touch punctuation merge: one, TWO" do
      assert {:ok, blk} = Inline.merge(b("one, two."), b("ONE, two."), b("one, TWO."))
      assert text(blk) == "ONE, TWO."
    end

    test "CJK punctuation parts Han runs: 京都。県庁" do
      assert {:ok, blk} = Inline.merge(b("東京。都庁"), b("京都。都庁"), b("東京。県庁"))
      assert text(blk) == "京都。県庁"
    end

    test "an ideographic space parts words: one\u3000TWO" do
      assert {:ok, blk} = Inline.merge(b("one\u3000two"), b("ONE\u3000two"), b("one\u3000TWO"))
      assert text(blk) == "ONE\u3000TWO"
    end
  end

  describe "task-3d00496b0292f20b: needless clashes" do
    test "one edit both sides made that lowers a word's count, spans cut apart: theirs" do
      base = b("dog dog dog x")
      mine = block("k", [span("a", "dog! "), span("b", "dog dog x")])
      theirs = block("k", [span("c", "dog! dog"), span("d", " dog x")])
      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert text(blk) == "dog! dog dog x"
    end

    test "a bold word deleted before a word that starts alike merges" do
      base =
        block("k", [span("a", "one "), span("b", "two", ["strong"]), span("c", " three four")])

      mine = block("k", [span("a", "one three four")])

      theirs =
        block("k", [span("a", "one "), span("b", "two", ["strong"]), span("c", " three FOUR")])

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert text(blk) == "one three FOUR"
    end
  end

  describe "task-07d2ca9aa7667208: marks and links" do
    defp link(k, href), do: %{"_key" => k, "_type" => "link", "href" => href}

    test "mine bolds one, theirs edits three: merged, bold on one only" do
      mine = block("k", [span("a", "one", ["strong"]), span("b", " two three")])
      assert {:ok, blk} = Inline.merge(b("one two three"), mine, b("one two THREE"))
      assert runs(blk) == [{"one", ["strong"]}, {" two THREE", []}]
      assert List.last(blk["children"])["_key"] == "ks"
    end

    test "theirs bolds three, mine edits one: theirs' bold stays" do
      theirs = block("k", [span("ks", "one two "), span("t", "three", ["strong"])])
      assert {:ok, blk} = Inline.merge(b("one two three"), b("ONE two three"), theirs)
      assert runs(blk) == [{"ONE two ", []}, {"three", ["strong"]}]
    end

    test "mine links one, theirs edits three: theirs' defs unchanged, plus mine's" do
      ours = link("t1", "https://b.example")

      base =
        block("k", [span("ks", "one "), span("l", "two", ["t1"]), span("r", " three")], [ours])

      theirs =
        block("k", [span("ks", "one "), span("l", "two", ["t1"]), span("r", " THREE")], [ours])

      mine =
        block(
          "k",
          [
            span("m", "one", ["m1"]),
            span("ks", " "),
            span("l", "two", ["t1"]),
            span("r", " three")
          ],
          [link("m1", "https://a.example"), ours]
        )

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert blk["markDefs"] == [ours, link("m1", "https://a.example")]

      assert runs(blk) == [
               {"one", ["https://a.example"]},
               {" ", []},
               {"two", ["https://b.example"]},
               {" THREE", []}
             ]
    end

    test "two adjacent links with equal content stay two links" do
      href = "https://a.example"

      mine =
        block("k", [span("a", "one", ["m1"]), span("b", "two", ["m2"]), span("c", " three")], [
          link("m1", href),
          link("m2", href)
        ])

      assert {:ok, blk} = Inline.merge(b("onetwo three"), mine, b("onetwo THREE"))
      assert [%{"marks" => [k1]}, %{"marks" => [k2]}, %{"text" => " THREE"}] = blk["children"]
      assert k1 != k2 and Enum.map(blk["markDefs"], & &1["_key"]) == [k1, k2]
      assert Enum.map(blk["markDefs"], & &1["href"]) == [href, href]
    end

    # #28802 review S2: mine's new link beside mine's own link of one content.
    test "mine links one beside its own equal-content link on two: two links, either side splicing" do
      x = link("d1", "https://x.example")
      spans = &[span("s0", "one ", &1), span("s1", "two", ["d1"]), span("s2", &2)]
      base = block("k", spans.([], " three"), [x])
      mine = block("k", spans.(["m1"], " three"), [x, link("m1", "https://x.example")])
      theirs = block("k", spans.([], " THREE"), [x])

      for {one, other} <- [{mine, theirs}, {theirs, mine}] do
        assert {:ok, blk} = Inline.merge(base, one, other)

        assert runs(blk) == [
                 {"one ", ["https://x.example"]},
                 {"two", ["https://x.example"]},
                 {" THREE", []}
               ]

        assert [%{"marks" => [k1]}, %{"marks" => [k2]}, _] = blk["children"]
        assert k1 != k2
        assert blk["markDefs"] |> Enum.map(& &1["_key"]) |> Enum.sort() == Enum.sort([k1, k2])
      end
    end

    # task-336c3a9b3baa9d0e (#28802 r2 review N1): mine swapped base's def
    # keys and put an x-linked "a" in; mine draws one x link "aa".
    test "mine re-keyed its defs and grows its x link: one link, not two" do
      {x, y} = {"https://x.example", "https://y.example"}

      base =
        block("k", [span("s0", "a", ["d1"]), span("s1", "a", ["d2"]), span("t", " end")], [
          link("d1", x),
          link("d2", y)
        ])

      mine =
        block("k", [span("s0", "aa", ["d2"]), span("s1", "a", ["d1"]), span("t", " end")], [
          link("d2", x),
          link("d1", y)
        ])

      theirs = put_in(base, ["children", Access.at(2), "text"], " END")

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert runs(blk) == [{"aa", [x]}, {"a", [y]}, {" END", []}]
      assert Enum.sort(Enum.map(blk["markDefs"], & &1["_key"])) == ["d1", "d2"]
    end

    test "a link theirs holds by content is theirs' def; a key theirs holds is not reused" do
      href = "https://a.example"
      base = block("k", [span("m1", "one two three")])

      theirs =
        block("k", [span("m1", "one two "), span("t", "THREE", ["d1"])], [link("d1", href)])

      mine = block("k", [span("a", "one", ["m1"]), span("b", " two three")], [link("m1", href)])

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert [%{"marks" => ["d1"]} | _] = blk["children"]
      assert blk["markDefs"] == [link("d1", href)]

      other =
        block("k", [span("a", "one", ["m1"]), span("b", " two three")], [
          link("m1", "https://o.example")
        ])

      assert {:ok, blk} = Inline.merge(base, other, theirs)
      [new] = blk["markDefs"] -- [link("d1", href)]
      assert new["href"] == "https://o.example" and new["_key"] not in ["m1", "d1"]
      assert hd(blk["children"])["marks"] == [new["_key"]]
    end

    test "mine takes out the only link to a def: the def goes; a def no span used stays" do
      unused = link("d9", "https://unused.example")

      base =
        block("k", [span("a", "one", ["d1"]), span("b", " two three")], [
          link("d1", "https://x.example"),
          unused
        ])

      theirs =
        block("k", [span("a", "one", ["d1"]), span("b", " two THREE")], [
          link("d1", "https://x.example"),
          unused
        ])

      assert {:ok, blk} = Inline.merge(base, block("k", [span("b", "ONE two three")]), theirs)
      assert runs(blk) == [{"ONE two THREE", []}]
      assert blk["markDefs"] == [unused]
    end

    test "mine changes a link's href on one, theirs edits three: the new def, the old one gone" do
      base =
        block("k", [span("a", "one", ["d1"]), span("b", " two three")], [
          link("d1", "https://x.example")
        ])

      theirs =
        block("k", [span("a", "one", ["d1"]), span("b", " two THREE")], [
          link("d1", "https://x.example")
        ])

      mine =
        block("k", [span("a", "one", ["d1"]), span("b", " two three")], [
          link("d1", "https://y.example")
        ])

      assert {:ok, blk} = Inline.merge(base, mine, theirs)
      assert runs(blk) == [{"one", ["https://y.example"]}, {" two THREE", []}]
      assert [%{"href" => "https://y.example"}] = blk["markDefs"]
    end
  end

  describe "through PortableTextMerge.merge/4" do
    # The first failing test of task-da701626f5be2143: a clash on main.
    test "disjoint words of one block merge: ONE two THREE" do
      base = [b("one two three")]

      assert texts(M.merge(base, [b("ONE two three", "p0")], [b("one two THREE")])) ==
               ["ONE two THREE"]

      assert {:clash, ["one two THREE"], _} =
               M.merge(base, [b("ONE two three", "p0")], [b("one two THREE")], inline: false)
    end

    test "a custom block both changed, or text one side made an image, is a clash" do
      img = fn k, a -> %{"_type" => "image", "_key" => k, "alt" => a} end
      assert {:clash, _, _} = M.merge([img.("i", "a")], [img.("i", "b")], [img.("i", "c")])
      assert {:clash, _, _} = M.merge([b("one two")], [img.("p0", "x")], [b("one TWO")])
    end

    # A save bounded by work done (#28714, #28710): 140 blocks (under
    # `@max_cells`), every other one at `TextRebase.max_bytes/0` and changed
    # on both sides. Past the merge's inline budget the rest clash, as before.
    test "a save of 70 blocks at the cap, changed on both sides, stays under 80M reductions" do
      text = String.duplicate("word ", div(Barkpark.Content.TextRebase.max_bytes(), 5) - 4)

      value = fn f ->
        Enum.flat_map(1..70, &[b(f.("b#{&1} " <> text), "k#{&1}"), b("anchor #{&1}", "a#{&1}")])
      end

      {base, mine, theirs} = {value.(& &1), value.(&("FIRST " <> &1)), value.(&(&1 <> "LAST"))}

      {:reductions, r0} = Process.info(self(), :reductions)
      assert {:clash, _texts, view} = M.merge(base, mine, theirs)
      {:reductions, r1} = Process.info(self(), :reductions)

      assert r1 - r0 < 80_000_000, "#{r1 - r0} reductions"
      assert text(hd(view)) == "FIRST b1 " <> text <> "LAST"
      assert text(Enum.at(view, 138)) == "FIRST b70 " <> text
    end

    # A block that does not fit what is left of the budget is a clash and
    # costs nothing: a smaller block after it still merges (#28781 review,
    # the charge-on-miss mutant). Ten capped blocks use about 1.97M of the
    # 2M; the eleventh does not fit; the small one does.
    test "a block too big for what is left of the budget clashes, and a small block after it still merges" do
      text = String.duplicate("word ", div(Barkpark.Content.TextRebase.max_bytes(), 5) - 4)

      value = fn f, small ->
        Enum.flat_map(1..11, &[b(f.("b#{&1} " <> text), "k#{&1}"), b("anchor #{&1}", "a#{&1}")]) ++
          [b(small, "s")]
      end

      base = value.(& &1, "one two three")
      mine = value.(&("FIRST " <> &1), "ONE two three")
      theirs = value.(&(&1 <> "LAST"), "one two THREE")

      assert {:clash, [_eleventh], view} = M.merge(base, mine, theirs)
      assert text(Enum.at(view, 18)) == "FIRST b10 " <> text <> "LAST"
      assert text(Enum.at(view, 20)) == "FIRST b11 " <> text
      assert text(List.last(view)) == "ONE two THREE"
    end
  end
end
