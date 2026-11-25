defmodule Barkpark.Content.PortableTextMergeObjectCostTest do
  @moduledoc """
  task-1cb50a8ed57c0547 (#28817 review, N2): inline objects were not
  bounded by the merge's text-byte caps. 50,000 objects in one block cost
  121-177M reductions, over the 80M save bound. Past an object count the
  merge is not tried: a clash, as past `@max_cells`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M

  @bound 80_000_000

  defp sp(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}
  defp ob(k, v), do: %{"_type" => "chip", "_key" => k, "v" => v}

  defp bl(k, cs),
    do: %{
      "_type" => "block",
      "_key" => k,
      "style" => "normal",
      "markDefs" => [],
      "children" => cs
    }

  defp cost(f) do
    {:reductions, r0} = Process.info(self(), :reductions)
    result = f.()
    {:reductions, r1} = Process.info(self(), :reductions)
    {r1 - r0, result}
  end

  defp objs(n, prefix, v), do: for(i <- 0..(n - 1), do: ob("#{prefix}#{i}", v))

  defp field(objects, tail, other \\ [sp("as", "anchor")]),
    do: [bl("k", [sp("h", "head ")] ++ objects ++ [sp("t", tail)]), bl("a", other)]

  test "50k inline objects, mine changes every one, theirs edits a word: under the bound, a clean clash" do
    base = field(objs(50_000, "o", 1), " tail end")
    mine = field(objs(50_000, "o", 2), " tail end")
    theirs = field(objs(50_000, "o", 1), " tail END")

    {r, result} = cost(fn -> M.merge(base, mine, theirs) end)
    assert r < @bound, "#{r} reductions"
    assert {:clash, _texts, view} = result
    assert view == mine
  end

  test "50k inline objects whose keys another block uses: under the bound, a clean clash" do
    other = [sp("as", "anchor")] ++ objs(50_000, "m", 0)
    base = field(objs(1, "o", 1), " tail end", other)
    mine = field(objs(50_000, "m", 3), " tail end", other)
    theirs = field(objs(1, "o", 1), " tail END", other)

    {r, result} = cost(fn -> M.merge(base, mine, theirs) end)
    assert r < @bound, "#{r} reductions"
    assert {:clash, _texts, ^mine} = result
  end

  test "just under the cap (4,999 objects a side), mine changes every one: still tried, under the bound" do
    base = field(objs(4_999, "o", 1), " tail end")
    mine = field(objs(4_999, "o", 2), " tail end")
    theirs = field(objs(4_999, "o", 1), " tail END")

    {r, _result} = cost(fn -> M.merge(base, mine, theirs) end)
    assert r < @bound, "#{r} reductions"
  end

  test "a few hundred objects still merge" do
    base = field(objs(300, "o", 1), " tail end")

    mine =
      field(objs(300, "o", 1), " tail end") |> List.replace_at(1, bl("a", [sp("as", "anchor A")]))

    theirs = field(objs(300, "o", 1), " tail END")

    assert {:ok, merged} = M.merge(base, mine, theirs)
    assert hd(hd(merged)["children"] |> Enum.take(-1))["text"] == " tail END"
    assert hd(Enum.at(merged, 1)["children"])["text"] == "anchor A"
  end
end
