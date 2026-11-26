defmodule Barkpark.Content.PortableTextMergeCompareCostTest do
  @moduledoc """
  task-681d2fd0a0020ff8 (#28882 review): around the merge, a save of a
  50,000-object rich text drew both values to compare them, 28-29M
  reductions a compare, on every post. Past the merge's object cap the
  compares set keys aside instead of drawing (`PortableTextMerge.past_cap?/2`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge, as: M
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote

  # Each compare, at most: well under the 28M a drawn compare cost.
  @bound 5_000_000

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

  defp field(n, v \\ 1, tail \\ " tail end"),
    do: [
      bl(
        "k",
        [sp("h", "head ")] ++ for(i <- 0..(n - 1)//1, do: ob("o#{i}", v)) ++ [sp("t", tail)]
      )
    ]

  defp cost(f) do
    {:reductions, r0} = Process.info(self(), :reductions)
    result = f.()
    {:reductions, r1} = Process.info(self(), :reductions)
    {r1 - r0, result}
  end

  @compares [
    same_drawn?: &M.same_drawn?/2,
    same_shape?: &M.same_shape?/2,
    unchanged?: &RichTextRemote.unchanged?/2
  ]

  for {name, _} <- @compares do
    test "#{name}: 50k objects, the same value posted back, under the bound and the same" do
      base = field(50_000)
      mine = PortableText.from_html(PortableText.to_html(base), base)
      {r, same?} = cost(fn -> Keyword.fetch!(@compares, unquote(name)).(mine, base) end)
      assert r < @bound, "#{r} reductions"
      assert same?
    end

    test "#{name}: 50k objects, one object changed, under the bound and not the same" do
      base = field(50_000)

      mine =
        field(50_000)
        |> update_in([Access.at(0), "children", Access.at(25_000)], &Map.put(&1, "v", 2))

      {r, same?} = cost(fn -> Keyword.fetch!(@compares, unquote(name)).(mine, base) end)
      assert r < @bound, "#{r} reductions"
      refute same?
    end

    test "#{name}: past the cap, a value that draws the same with other span keys reads as changed" do
      base = field(16_000)
      mine = field(16_000) |> put_in([Access.at(0), "children", Access.at(0), "_key"], "other")
      refute Keyword.fetch!(@compares, unquote(name)).(mine, base)
    end

    test "#{name}: under the cap, it still compares the drawing" do
      base = field(100)
      mine = field(100) |> put_in([Access.at(0), "children", Access.at(0), "_key"], "other")
      assert Keyword.fetch!(@compares, unquote(name)).(mine, base)
    end
  end

  test "past the cap, a post that reads as changed is a clash, never a silent write" do
    base = field(16_000)
    mine = field(16_000) |> put_in([Access.at(0), "children", Access.at(0), "_key"], "other")
    theirs = field(16_000, 1, " tail END")
    assert {:clash, _texts, ^mine} = M.merge(base, mine, theirs)
  end
end
