defmodule Barkpark.Content.PortableTextMergeBlockFieldsTest do
  @moduledoc """
  task-68298dcf20a1ec8a (#28817 review, T2): the block line-up compared
  blocks as drawn, so a block field change that draws the same (`level`
  without `listItem`, an unknown field, a `style` removed) read as no
  change: `merge(base, mine_with_level, base)` lost the level.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M

  defp b(key, text, fields \\ %{}) do
    Map.merge(
      %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
      },
      fields
    )
  end

  defp text(block), do: hd(block["children"])["text"]

  defp base, do: [b("k1", "one two"), b("k2", "three four")]

  # Field changes that leave the drawing as it was.
  defp change("level without listItem", block), do: Map.put(block, "level", 2)
  defp change("an unknown field", block), do: Map.put(block, "note", "x")
  defp change("style removed", block), do: Map.delete(block, "style")

  for name <- ["level without listItem", "an unknown field", "style removed"] do
    test "#{name}: merge(base, mine, base) keeps mine's change" do
      mine = List.update_at(base(), 1, &change(unquote(name), &1))
      assert {:ok, merged} = M.merge(base(), mine, base())
      assert Enum.at(merged, 1) |> Map.delete("_key") == Enum.at(mine, 1) |> Map.delete("_key")
    end

    test "#{name}: merge(base, base, theirs) keeps theirs' change" do
      theirs = List.update_at(base(), 0, &change(unquote(name), &1))
      assert {:ok, merged} = M.merge(base(), base(), theirs)
      assert Enum.at(merged, 0) |> Map.delete("_key") == Enum.at(theirs, 0) |> Map.delete("_key")
    end

    test "#{name} on mine, a word edit in the same block on theirs: both kept" do
      mine = List.update_at(base(), 0, &change(unquote(name), &1))
      theirs = List.replace_at(base(), 0, b("k1", "one two three"))
      assert {:ok, merged} = M.merge(base(), mine, theirs)
      got = Enum.at(merged, 0)
      assert text(got) == "one two three"

      assert Map.drop(got, ["_key", "children"]) ==
               Map.drop(Enum.at(mine, 0), ["_key", "children"])
    end

    test "#{name}: the same word edit on both sides, plus the change on mine: the change kept" do
      edited = b("k1", "one two X")
      mine = List.replace_at(base(), 0, change(unquote(name), edited))
      theirs = List.replace_at(base(), 0, edited)
      assert {:ok, merged} = M.merge(base(), mine, theirs)
      got = Enum.at(merged, 0)
      assert text(got) == "one two X"

      assert Map.drop(got, ["_key", "children"]) ==
               Map.drop(Enum.at(mine, 0), ["_key", "children"])
    end
  end

  test "a field change both sides made alike merges cleanly" do
    mine = List.update_at(base(), 0, &Map.put(&1, "level", 2))
    assert {:ok, merged} = M.merge(base(), mine, mine)
    assert Enum.at(merged, 0)["level"] == 2
  end

  test "different values of one field on each side never take one silently" do
    mine = List.update_at(base(), 0, &Map.put(&1, "level", 2))
    theirs = List.update_at(base(), 0, &Map.put(&1, "level", 3))

    case M.merge(base(), mine, theirs) do
      {:clash, _banner, _view} -> :ok
      {:ok, merged} -> flunk("merged without a clash: #{inspect(Enum.at(merged, 0)["level"])}")
    end
  end
end
