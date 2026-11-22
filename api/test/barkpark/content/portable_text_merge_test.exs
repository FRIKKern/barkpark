defmodule Barkpark.Content.PortableTextMergeTest do
  @moduledoc """
  task-47be2cdf59d0acd5 (#28349 r4): A's post over B's save of one rich
  text is merged block by block. Blocks are lined up by their words, since
  a save through the editor's HTML gives them new keys. Where the line-up
  can go more than one way and that changes the result, it is a clash.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText
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

  # A side as the editor posts it: through HTML, keys adopted by index.
  defp post(base, texts),
    do: PortableText.from_html(Enum.map_join(texts, &"<p>#{&1}</p>"), base)

  defp words(blocks), do: Enum.map(blocks, fn bl -> hd(bl["children"])["text"] end)

  defp keys_unique?(blocks), do: blocks |> Enum.map(& &1["_key"]) |> then(&(&1 == Enum.uniq(&1)))

  test "K5: A types in block 0, B adds a paragraph: both, theirs keys kept" do
    base = [b("k1", "one two")]
    theirs = [b("k1", "one two"), b("b1", "B para")]

    assert {:ok, merged} = M.merge(base, post(base, ["one twoHel"]), theirs)
    assert words(merged) == ["one twoHel", "B para"]
    assert keys_unique?(merged)
  end

  test "A and B change different blocks; each keeps the other's" do
    base = [b("a", "alpha"), b("m", "middle"), b("z", "omega")]
    theirs = [b("a", "alpha B"), b("m", "middle"), b("z", "omega")]

    assert {:ok, merged} = M.merge(base, post(base, ["alpha", "middle", "omega A"]), theirs)
    assert words(merged) == ["alpha B", "middle", "omega A"]
  end

  test "both changed one block: a clash; stored has theirs, the view mine, the banner theirs" do
    base = [b("k1", "one two"), b("k2", "tail")]
    theirs = [b("k1", "B one two"), b("k2", "tail"), b("k3", "B para")]

    assert {:clash, ["B one two"], stored, view} =
             M.merge(base, post(base, ["one two A", "tail"]), theirs)

    assert words(stored) == ["B one two", "tail", "B para"]
    assert words(view) == ["one two A", "tail", "B para"]
    assert keys_unique?(view)
  end

  test "both made the same change: one change, no clash" do
    base = [b("k1", "one")]
    assert {:ok, merged} = M.merge(base, post(base, ["one!"]), [b("x", "one!")])
    assert words(merged) == ["one!"]
  end

  test "two identical paragraphs, B edits one and A the other: a clash, never a pick" do
    base = [b("p1", "same"), b("p2", "same")]
    theirs = [b("p1", "same"), b("p2", "same B")]

    assert {:clash, texts, stored, view} = M.merge(base, post(base, ["same A", "same"]), theirs)
    assert stored == theirs
    assert words(view) == ["same A", "same"]
    assert "same B" in texts
  end

  test "identical paragraphs away from both edits do not make a clash" do
    base = [b("a", "alpha"), b("p1", "same"), b("p2", "same"), b("z", "omega")]
    theirs = [b("a", "alpha B"), b("p1", "same"), b("p2", "same"), b("z", "omega")]

    assert {:ok, merged} =
             M.merge(base, post(base, ["alpha", "same", "same", "omega A"]), theirs)

    assert words(merged) == ["alpha B", "same", "same", "omega A"]
  end

  test "empty paragraphs: A types in one beside another, B adds one at the end" do
    base = [b("e1", ""), b("e2", ""), b("t", "tail")]
    theirs = base ++ [b("n", "B para")]

    assert {:ok, merged} = M.merge(base, post(base, ["Hel", "", "tail"]), theirs)
    assert words(merged) == ["Hel", "", "tail", "B para"]
  end

  test "empty paragraphs: A types in one, B types in the other: a clash" do
    base = [b("e1", ""), b("e2", "")]

    assert {:clash, _texts, stored, view} =
             M.merge(base, post(base, ["Hel", ""]), [b("e1", ""), b("e2", "B")])

    assert words(stored) == ["", "B"]
    assert words(view) == ["Hel", ""]
  end

  test "B deletes the block A is editing: a clash; A's block is kept in the view" do
    base = [b("a", "alpha"), b("z", "omega")]

    assert {:clash, [], stored, view} =
             M.merge(base, post(base, ["alpha A", "omega"]), [b("z", "omega")])

    assert words(stored) == ["omega"]
    assert words(view) == ["alpha A", "omega"]
  end

  test "B moves a block A is editing: the moved block is neither lost nor doubled" do
    base = [b("a", "alpha"), b("z", "omega")]
    theirs = [b("z", "omega"), b("a", "alpha")]

    assert {:clash, _texts, stored, view} =
             M.merge(base, post(base, ["alpha A", "omega"]), theirs)

    assert stored == theirs
    assert words(view) == ["alpha A", "omega"]
  end

  test "B moves a block A did not touch: kept once, in B's order" do
    base = [b("a", "alpha"), b("m", "middle"), b("z", "omega")]
    theirs = [b("m", "middle"), b("a", "alpha"), b("z", "omega")]

    result = M.merge(base, post(base, ["alpha", "middle", "omega A"]), theirs)

    blocks =
      case result do
        {:ok, merged} -> merged
        {:clash, _texts, stored, _view} -> stored
      end

    assert Enum.sort(words(blocks)) |> Enum.count(&(&1 in ["alpha", "middle"])) == 2
    assert length(blocks) == 3
  end

  test "past the cap the merge is not tried: a clash, theirs stored, mine shown" do
    base = for i <- 1..150, do: b("k#{i}", "p#{i}")
    theirs = base ++ [b("n", "B para")]
    mine = for i <- 1..150, do: b("k#{i}", if(i == 1, do: "p1 A", else: "p#{i}"))

    assert {:clash, texts, ^theirs, ^mine} = M.merge(base, mine, theirs)
    assert texts == ["p1", "B para"]
  end

  test "a custom block changed on one side is taken, not read as text" do
    media = %{"_type" => "mediaModule", "_key" => "m1", "src" => "a.png"}
    base = [b("k1", "one"), media]
    theirs = [b("k1", "one"), Map.put(media, "src", "b.png")]

    assert {:ok, [_, %{"src" => "b.png"}]} = M.merge(base, [b("x", "one A"), media], theirs)
  end
end
