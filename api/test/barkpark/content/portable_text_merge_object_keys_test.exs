defmodule Barkpark.Content.PortableTextMergeObjectKeysTest do
  @moduledoc """
  task-1f8cff9d0bb3af3e (#28817 review, T1): theirs' new inline object
  keeps its key, so the same key added by mine in another block repeated
  across blocks. A merge that only takes each side's blocks did the same.
  An object key is unique in the whole field after any merge: the one
  later in the field is given a new key.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M

  defp sp(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}
  defp ob(k, v), do: %{"_type" => "chip", "_key" => k, "v" => v}

  defp kb(k, cs),
    do: %{
      "_type" => "block",
      "_key" => k,
      "style" => "normal",
      "markDefs" => [],
      "children" => cs
    }

  defp doc(kc, k2c),
    do: [
      kb("k", kc),
      kb("a1", [sp("a1s", "anchor one")]),
      kb("k2", k2c),
      kb("a2", [sp("a2s", "anchor two")])
    ]

  defp base, do: doc([sp("a", "one two three")], [sp("z", "other")])

  defp objects(blocks),
    do:
      for(%{"children" => cs} <- blocks, %{"_type" => "chip"} = o <- cs, do: {o["_key"], o["v"]})

  defp all_keys(blocks),
    do: Enum.flat_map(blocks, fn b -> [b["_key"] | Enum.map(b["children"], & &1["_key"])] end)

  defp assert_unique_objects(blocks) do
    keys = Enum.map(objects(blocks), &elem(&1, 0))
    assert keys == Enum.uniq(keys), "an object key repeats: #{inspect(objects(blocks))}"
  end

  test "theirs' new K in the block merged inline, mine's new K in another block: both kept, keys unique" do
    mine = doc([sp("a", "one two THREE")], [sp("z", "other "), ob("K", 1)])
    theirs = doc([sp("a", "ONE "), ob("K", 2), sp("c", " two three")], [sp("z", "other")])

    assert {:ok, merged} = M.merge(base(), mine, theirs)
    assert Enum.sort(Enum.map(objects(merged), &elem(&1, 1))) == [1, 2]
    assert_unique_objects(merged)
    # The first keeps its key; the new one is unique in the whole field.
    assert {"K", 2} in objects(merged)
    assert Enum.count(all_keys(merged), &(&1 == "K")) == 1
  end

  test "both sides add K, each in a block only it changed (takes only): keys unique" do
    mine = doc([sp("a", "one two three")], [sp("z", "other "), ob("K", 1)])
    theirs = [kb("k", [sp("a", "one "), ob("K", 2), sp("c", " two three")]) | tl(base())]

    assert {:ok, merged} = M.merge(base(), mine, theirs)
    assert Enum.sort(Enum.map(objects(merged), &elem(&1, 1))) == [1, 2]
    assert_unique_objects(merged)
  end

  test "mine's new K in the block merged inline, theirs' new K in another block: keys unique" do
    mine = doc([sp("a", "ONE "), ob("K", 2), sp("c", " two three")], [sp("z", "other")])
    theirs = doc([sp("a", "one two THREE")], [sp("z", "other "), ob("K", 1)])

    assert {:ok, merged} = M.merge(base(), mine, theirs)
    assert_unique_objects(merged)
  end

  test "an object kept by both sides keeps its key" do
    b = doc([sp("a", "one "), ob("K", 1), sp("c", " two three")], [sp("z", "other")])
    mine = doc([sp("a", "ONE "), ob("K", 1), sp("c", " two three")], [sp("z", "other")])
    theirs = doc([sp("a", "one "), ob("K", 1), sp("c", " two three")], [sp("z", "OTHER")])

    assert {:ok, merged} = M.merge(b, mine, theirs)
    assert objects(merged) == [{"K", 1}]
  end
end
