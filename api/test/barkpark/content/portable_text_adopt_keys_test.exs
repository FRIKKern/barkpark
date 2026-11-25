defmodule Barkpark.Content.PortableTextAdoptKeysTest do
  @moduledoc """
  task-dc8eaead5484fd12 (#28360 review): an edited block took the `_key` and
  fields of the stored block at its index. A paragraph added above an edited
  one in one post took the edited one's key and its `anchor`, and the edited
  one got a new key; TanStack matches blocks by `_key`. It now takes them
  from the stored block it replaces (`PortableTextPairing`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp span(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}

  defp block(k, text, extra \\ %{}) do
    Map.merge(
      %{
        "_type" => "block",
        "_key" => k,
        "style" => "normal",
        "markDefs" => [],
        "children" => [span(k <> "s", text)]
      },
      extra
    )
  end

  # What the editor posts after `edit`, read against `stored`.
  defp save(stored, edit), do: PortableText.from_html(PortableText.to_html(edit), stored)

  defp keyed(out, text), do: Enum.find(out, &(words(&1) == text))

  defp words(b), do: Enum.map_join(b["children"], "", & &1["text"])

  defp new(text), do: block("new", text)

  setup do
    p1 = block("k1", "The quick brown fox jumps over the lazy dog", %{"anchor" => "intro"})
    p2 = block("k2", "A second paragraph that stays as it was", %{"anchor" => "second"})
    {:ok, p1: p1, p2: p2}
  end

  test "a block inserted above an edited block takes neither its key nor its fields",
       %{p1: p1, p2: p2} do
    edited = block("k1", "The quick brown fox leaps over the lazy dog")
    out = save([p1, p2], [new("A brand new opening line"), edited, p2])

    assert keyed(out, "The quick brown fox leaps over the lazy dog")["_key"] == "k1"
    assert keyed(out, "The quick brown fox leaps over the lazy dog")["anchor"] == "intro"
    assert keyed(out, "A brand new opening line")["_key"] not in ["k1", "k2"]
    refute Map.has_key?(keyed(out, "A brand new opening line"), "anchor")
    assert keyed(out, "A second paragraph that stays as it was") == p2
  end

  test "the same with nothing after the edited block", %{p1: p1} do
    edited = block("k1", "The quick brown fox leaps over the lazy dog")
    out = save([p1], [new("A brand new opening line"), edited])

    assert keyed(out, "The quick brown fox leaps over the lazy dog")["_key"] == "k1"
    assert keyed(out, "The quick brown fox leaps over the lazy dog")["anchor"] == "intro"
    refute Map.has_key?(keyed(out, "A brand new opening line"), "anchor")
  end

  test "a block inserted between two edited blocks: each keeps its own", %{p1: p1, p2: p2} do
    e1 = block("k1", "The quick brown fox leaps over the lazy dog")
    e2 = block("k2", "A second paragraph that changed from what it was")
    out = save([p1, p2], [e1, new("Something in the middle"), e2])

    assert keyed(out, words(e1))["_key"] == "k1"
    assert keyed(out, words(e2))["_key"] == "k2"
    assert keyed(out, words(e2))["anchor"] == "second"
    refute Map.has_key?(keyed(out, "Something in the middle"), "anchor")
  end

  test "an edited block whose neighbour was deleted keeps its key", %{p1: p1, p2: p2} do
    e2 = block("k2", "A second paragraph that changed from what it was")
    out = save([p1, p2], [e2])

    assert [%{"_key" => "k2", "anchor" => "second"}] = out
  end

  test "a block rewritten in place, one for one, keeps its key", %{p1: p1, p2: p2} do
    out = save([p1, p2], [block("k1", "Nothing in common at all"), p2])

    assert keyed(out, "Nothing in common at all")["_key"] == "k1"
    assert keyed(out, "Nothing in common at all")["anchor"] == "intro"
  end

  # Beside an insert, a rewrite with no words in common cannot be told from
  # a new block: neither takes the stored block's key.
  test "an insert beside a rewrite with no words in common moves no key", %{p1: p1, p2: p2} do
    out = save([p1, p2], [new("A brand new opening line"), block("k1", "Nothing in common"), p2])

    refute Enum.any?(out, &(&1["_key"] == "k1"))
    refute Enum.any?(out, &(&1["anchor"] == "intro"))
  end

  # A value first saved by this desk carries position keys (b0, b1 …), which
  # is also the key an unpaired block is given (#28714 review).
  test "with position keys, an insert at the top takes a key no block holds" do
    p1 = block("b0", "The quick brown fox jumps over the lazy dog", %{"anchor" => "intro"})
    p2 = block("b1", "A second paragraph that stays as it was")
    edited = block("b0", "The quick brown fox leaps over the lazy dog")
    out = save([p1, p2], [new("A brand new opening line"), edited, p2])

    keys = Enum.map(out, & &1["_key"])
    assert keys == Enum.uniq(keys), "duplicate keys #{inspect(keys)}"
    assert keyed(out, words(edited))["_key"] == "b0"
    assert keyed(out, words(edited))["anchor"] == "intro"
    assert keyed(out, "A brand new opening line")["_key"] not in ["b0", "b1"]
  end

  # The pairing by words has one budget per save (#28714 review): a paste
  # of many gaps of long blocks cannot make it run for seconds. Bounded by
  # work done (reductions), not by time, as text_undo_test is (#28710).
  test "the pairing by words is bounded per save, not per gap" do
    vocab = for i <- 1..400, do: "w#{i}"

    para = fn seed ->
      Enum.map_join(0..199, " ", &Enum.at(vocab, rem(seed * 7 + &1 * 13, 400)))
    end

    {kept, stored} =
      Enum.reduce(0..9, {[], []}, fn g, {kept, stored} ->
        anchor = block("a#{g}", "anchor #{g}")
        gap = for i <- 0..99, do: block("g#{g}x#{i}", para.(g * 100 + i))
        posted = for i <- 0..98, do: {:rebuilt, block("r", para.(g * 100 + i) <> " more")}
        at = length(stored)
        {kept ++ [{:kept, anchor, at} | posted], stored ++ [anchor | gap]}
      end)

    {:reductions, before} = Process.info(self(), :reductions)
    pairs = Barkpark.Content.PortableTextPairing.pairs(kept, stored)
    {:reductions, after_} = Process.info(self(), :reductions)

    # Measured: about 28M with the budget, about 406M at 175fde76c3 (the cap per gap).
    assert after_ - before < 80_000_000, "took #{after_ - before} reductions"
    assert map_size(pairs) > 0
  end

  # task-78fa90c58c93e534 (#28714 r2 review).
  describe "every key once in a save" do
    defp box(k), do: %{"_type" => "image", "_key" => k, "asset" => %{"_ref" => "image-abc"}}

    test "a copied object box gets a fresh key, and the first copy keeps its own",
         %{p1: p1, p2: p2} do
      out = save([p1, box("img1"), p2], [p1, box("img1"), box("img1"), p2])
      keys = Enum.map(out, & &1["_key"])

      assert keys == Enum.uniq(keys)
      assert [^p1, first, copy, ^p2] = out
      assert first == box("img1")
      assert copy == %{box("img1") | "_key" => copy["_key"]}
    end

    test "the same with the copy above the box", %{p1: p1, p2: p2} do
      out = save([p1, box("img1"), p2], [box("img1"), p1, box("img1"), p2])
      keys = Enum.map(out, & &1["_key"])

      assert keys == Enum.uniq(keys)
      assert Enum.at(out, 0) == box("img1")
    end

    # The pairing budget fits one gap of 99 x 100 blocks, not two: the first
    # gap pairs, as the document reads, and the second is new.
    test "the pairing budget is spent in document order" do
      four = fn k, i -> "w#{k}#{i} x#{k}#{i} y#{k}#{i} z#{k}#{i}" end
      gap = fn k -> for i <- 0..99, do: block("#{k}#{i}", four.(k, i)) end

      edit = fn k ->
        for i <- 1..99, do: block("e", String.replace(four.(k, i), ~r/z\S+$/, "edited"))
      end

      fixed = block("K", "a block between the two gaps that stays")

      out = save(gap.("a") ++ [fixed] ++ gap.("c"), edit.("a") ++ [fixed] ++ edit.("c"))
      {first, [^fixed | second]} = Enum.split(out, 99)

      assert Enum.map(first, & &1["_key"]) == for(i <- 1..99, do: "a#{i}")
      assert Enum.all?(second, &(not String.starts_with?(&1["_key"], "c")))
    end
  end
end
