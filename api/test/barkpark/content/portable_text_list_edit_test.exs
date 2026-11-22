defmodule Barkpark.Content.PortableTextListEditTest.Blocks do
  @moduledoc false
  def item(key, text, list, extra \\ %{}) do
    Map.merge(
      %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
      },
      Map.merge(list, extra)
    )
  end

  def bullet(level), do: %{"listItem" => "bullet", "level" => level}
end

defmodule Barkpark.Content.PortableTextListEditTest do
  @moduledoc """
  task-be63132f2ec337c7: a list item indented, outdented or turned from
  bullet to number with its text untouched was not saved. `from_html/3`
  keeps a stored block verbatim when the edit did not touch it, and it
  matched a list item by its `<li>` alone, which does not say the list or
  the depth. It now also matches where the editor draws the item. A stored
  value the editor draws the same way stays byte-identical (#26158).
  """
  use ExUnit.Case, async: true

  import Barkpark.Content.PortableTextListEditTest.Blocks

  alias Barkpark.Content.PortableText

  defp shape(blocks), do: Enum.map(blocks, &Map.take(&1, ["_key", "listItem", "level"]))

  @stored [item("k1", "x", bullet(1)), item("k2", "y", bullet(1))]

  test "an indented item is saved at level 2, with its key and spans" do
    out = PortableText.from_html("<ul><li>x<ul><li>y</li></ul></li></ul>", @stored)

    assert shape(out) == [
             %{"_key" => "k1", "listItem" => "bullet", "level" => 1},
             %{"_key" => "k2", "listItem" => "bullet", "level" => 2}
           ]

    assert hd(out) == hd(@stored)
    assert Enum.at(out, 1) == Map.put(Enum.at(@stored, 1), "level", 2)
  end

  test "an outdented item is saved at level 1" do
    stored = [item("k1", "x", bullet(1)), item("k2", "y", bullet(2))]
    out = PortableText.from_html("<ul><li>x</li><li>y</li></ul>", stored)
    assert Enum.at(out, 1) == Map.put(Enum.at(stored, 1), "level", 1)
  end

  test "bullets turned to numbers are saved as numbers" do
    out = PortableText.from_html("<ol><li>x</li><li>y</li></ol>", @stored)

    assert out ==
             Enum.map(@stored, &Map.put(&1, "listItem", "number"))
  end

  test "one item turned to a number: only that item changes" do
    out = PortableText.from_html("<ul><li>x</li></ul><ol><li>y</li></ol>", @stored)
    assert hd(out) == hd(@stored)
    assert Enum.at(out, 1) == Map.put(Enum.at(@stored, 1), "listItem", "number")
  end

  # #26158: what the editor draws the same way as stored is stored, byte for
  # byte, through an unrelated edit.
  describe "an unrelated edit keeps every stored list item byte-identical" do
    for {name, stored} <- [
          {"custom listItem", [item("k1", "x", %{"listItem" => "square", "level" => 1})]},
          {"no level", [item("k1", "x", %{"listItem" => "bullet"})]},
          {"level 3 under 1", [item("k1", "x", bullet(1)), item("k2", "y", bullet(3))]},
          {"numbers, nested",
           [
             item("k1", "x", %{"listItem" => "number", "level" => 1}),
             item("k2", "y", %{"listItem" => "number", "level" => 2})
           ]},
          {"extra fields", [item("k1", "x", bullet(1), %{"custom" => %{"a" => 1}})]}
        ] do
      @stored_case stored
      test name do
        para = %{
          "_type" => "block",
          "_key" => "p1",
          "style" => "normal",
          "markDefs" => [],
          "children" => [%{"_type" => "span", "_key" => "p1s", "text" => "one", "marks" => []}]
        }

        stored = [para | @stored_case]
        html = PortableText.to_html(stored)
        assert PortableText.from_html(html, stored) == stored

        edited = String.replace(html, "<p>one</p>", "<p>one two</p>")
        [_ | rest] = PortableText.from_html(edited, stored)
        assert rest == @stored_case
      end
    end
  end
end
