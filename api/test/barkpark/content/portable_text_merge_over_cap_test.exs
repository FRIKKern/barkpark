defmodule Barkpark.Content.PortableTextMergeOverCapTest do
  @moduledoc """
  task-64eed140345d8927 (#28882 review): past `@max_objects` the merge is
  not tried and returns a clash. The same edit on both sides, or a value one
  side left as it was, is no clash: it was held with an empty banner.
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

  defp objs(n, v), do: for(i <- 0..(n - 1), do: ob("o#{i}", v))

  defp field(objects, tail),
    do: [bl("k", [sp("h", "head ")] ++ objects ++ [sp("t", tail)]), bl("a", [sp("as", "anchor")])]

  defp cost(f) do
    {:reductions, r0} = Process.info(self(), :reductions)
    result = f.()
    {:reductions, r1} = Process.info(self(), :reductions)
    {r1 - r0, result}
  end

  @n 6_000

  test "the same edit on both sides, 18k objects: merged, not held" do
    base = field(objs(@n, 1), " tail end")
    edited = field(objs(@n, 2), " tail END")

    {r, result} = cost(fn -> M.merge(base, edited, edited) end)
    assert r < @bound, "#{r} reductions"
    assert result == {:ok, edited}
  end

  test "the same edit on both sides, block keys apart: merged" do
    base = field(objs(@n, 1), " tail end")
    mine = field(objs(@n, 2), " tail END")
    theirs = Enum.map(mine, &Map.update!(&1, "_key", fn k -> k <> "t" end))

    assert M.merge(base, mine, theirs) == {:ok, theirs}
  end

  test "mine left the value as it was: theirs" do
    base = field(objs(@n, 1), " tail end")
    theirs = field(objs(@n, 1), " tail END")
    assert M.merge(base, base, theirs) == {:ok, theirs}
  end

  test "theirs left the value as it was: mine" do
    base = field(objs(@n, 1), " tail end")
    mine = field(objs(@n, 2), " tail end")
    assert M.merge(base, mine, base) == {:ok, mine}
  end

  test "both changed differently: still a clash, mine in the view, theirs' words in the banner" do
    base = field(objs(@n, 1), " tail end")
    mine = field(objs(@n, 2), " tail end")
    theirs = field(objs(@n, 1), " tail END")

    {r, result} = cost(fn -> M.merge(base, mine, theirs) end)
    assert r < @bound, "#{r} reductions"
    assert {:clash, [text], ^mine} = result
    assert String.ends_with?(text, "tail END")
  end
end
