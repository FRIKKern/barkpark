defmodule Barkpark.Content.PortableTextMergeBlockKeysCostTest do
  @moduledoc """
  task-d1eb66738fe73ed0 (#28861 review): a repeated block `_key` took its
  fresh key from a walk that restarted at 1 on every repeat, so d blocks
  sharing one key cost d² tries. Each key now carries its own counter, as
  inline objects do (`unique_objects/1`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M

  defp b(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  defp cost(f) do
    {:reductions, r0} = Process.info(self(), :reductions)
    result = f.()
    {:reductions, r1} = Process.info(self(), :reductions)
    {r1 - r0, result}
  end

  # base × mine stays at the cells cap (2 × 10,000): mine pastes 9,998
  # blocks that share one key between the two; theirs changes the last.
  test "9,998 pasted blocks sharing one key, theirs changing the last block: keys unique, linear" do
    base = [b("a", "one"), b("z", "end")]
    pasted = for i <- 1..9_998, do: b("dup", "pasted #{i}")
    mine = [b("a", "one") | pasted] ++ [b("z", "end")]
    theirs = [b("a", "one"), b("z", "END")]

    {r, result} = cost(fn -> M.merge(base, mine, theirs) end)

    assert {:ok, merged} = result
    keys = Enum.map(merged, & &1["_key"])
    assert keys == Enum.uniq(keys)
    assert length(merged) == 10_000
    assert hd(merged)["children"] |> hd() |> Map.get("text") == "one"
    assert List.last(merged)["children"] |> hd() |> Map.get("text") == "END"
    assert r < 20_000_000, "#{r} reductions"
  end
end
