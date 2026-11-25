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

  # Both edit the word "two": an overlap, a clash before and after the merge
  # inside one block (task-266ffbe9cd115f3c).
  test "both changed one block: a clash; the view has mine there and theirs elsewhere, the banner theirs" do
    base = [b("k1", "one two"), b("k2", "tail")]
    theirs = [b("k1", "one TWO"), b("k2", "tail"), b("k3", "B para")]

    assert {:clash, ["one TWO"], view} =
             M.merge(base, post(base, ["one twoA", "tail"]), theirs)

    assert words(view) == ["one twoA", "tail", "B para"]
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

    assert {:clash, texts, view} = M.merge(base, post(base, ["same A", "same"]), theirs)
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

    assert {:clash, ["B"], view} =
             M.merge(base, post(base, ["Hel", ""]), [b("e1", ""), b("e2", "B")])

    assert words(view) == ["Hel", ""]
  end

  test "B deletes the block A is editing: a clash; A's block is kept in the view" do
    base = [b("a", "alpha"), b("z", "omega")]

    assert {:clash, [], view} =
             M.merge(base, post(base, ["alpha A", "omega"]), [b("z", "omega")])

    assert words(view) == ["alpha A", "omega"]
  end

  test "B moves a block A is editing: the moved block is neither lost nor doubled" do
    base = [b("a", "alpha"), b("z", "omega")]
    theirs = [b("z", "omega"), b("a", "alpha")]

    assert {:clash, _texts, view} =
             M.merge(base, post(base, ["alpha A", "omega"]), theirs)

    assert words(view) == ["alpha A", "omega"]
  end

  test "B moves a block A did not touch: kept once, in B's order" do
    base = [b("a", "alpha"), b("m", "middle"), b("z", "omega")]
    theirs = [b("m", "middle"), b("a", "alpha"), b("z", "omega")]

    result = M.merge(base, post(base, ["alpha", "middle", "omega A"]), theirs)

    blocks =
      case result do
        {:ok, merged} -> merged
        {:clash, _texts, _view} -> theirs
      end

    assert Enum.sort(words(blocks)) |> Enum.count(&(&1 in ["alpha", "middle"])) == 2
    assert length(blocks) == 3
  end

  test "past the cap the merge is not tried: a clash, mine shown" do
    base = for i <- 1..150, do: b("k#{i}", "p#{i}")
    theirs = base ++ [b("n", "B para")]
    mine = for i <- 1..150, do: b("k#{i}", if(i == 1, do: "p1 A", else: "p#{i}"))

    assert {:clash, texts, ^mine} = M.merge(base, mine, theirs)
    assert texts == ["p1", "B para"]
  end

  test "a custom block changed on one side is taken, not read as text" do
    media = %{"_type" => "mediaModule", "_key" => "m1", "src" => "a.png"}
    base = [b("k1", "one"), media]
    theirs = [b("k1", "one"), Map.put(media, "src", "b.png")]

    assert {:ok, [_, %{"src" => "b.png"}]} = M.merge(base, [b("x", "one A"), media], theirs)
  end

  # #28349 r4 review, cases by number; base [P, "Q one two", R] unless
  # given. `:whole`: the line-up is not certain, the view is mine as it is.
  # A split, a join, a delete or an insert beside an edit, both adding at
  # one place, a move of a block the other edited: never merged.
  @cases [
    {"01 A edits Q, B adds X before Q", ~w(P Q1 R), ~w(P QA R), ~w(P X Q1 R),
     {:ok, ~w(P X QA R)}},
    {"02 A edits Q, B adds X after Q", ~w(P Q1 R), ~w(P QA R), ~w(P Q1 X R), {:ok, ~w(P QA X R)}},
    {"03 A edits Q, B adds X before Q and edits Q", ~w(P Q1 R), ~w(P QA R), ~w(P X QB R), :whole},
    {"04 A edits Q, B edits Q and adds X after", ~w(P Q1 R), ~w(P QA R), ~w(P QB X R), :whole},
    {"05 A splits Q, B edits R", ~w(P Q1 R), ~w(P Qa Qb R), ~w(P Q1 RB), :whole},
    {"06 A splits Q, B edits Q", ~w(P Q1 R), ~w(P Qa Qb R), ~w(P QB R), :whole},
    {"07 B splits Q, A edits Q", ~w(P Q1 R), ~w(P QA R), ~w(P Qa Qb R), :whole},
    {"08 A joins Q+R, B edits R", ~w(P Q1 R), ~w(P QR), ~w(P Q1 RB), :whole},
    {"10 B moves R to the top, A edits R", ~w(P Q1 R), ~w(P Q1 RA), ~w(R P Q1), :whole},
    {"11 B moves R to the top, A edits Q", ~w(P Q1 R), ~w(P QA R), ~w(R P Q1), {:ok, ~w(R P QA)}},
    {"12 A deletes Q, B edits Q", ~w(P Q1 R), ~w(P R), ~w(P QB R), :whole},
    {"13 both delete Q", ~w(P Q1 R), ~w(P R), ~w(P R), {:ok, ~w(P R)}},
    {"14 B deletes Q and edits R, A edits Q", ~w(P Q1 R), ~w(P QA R), ~w(P RB), :whole},
    {"20 both restyle Q differently", ~w(P Q1 R), ~w(P QA R), ~w(P QB R), {:block, ~w(P QA R)}},
    {"26 both add a different block at the end", ~w(P Q1 R), ~w(P Q1 R A1), ~w(P Q1 R B1),
     :whole},
    {"27 both add the same block at the end", ~w(P Q1 R), ~w(P Q1 R same), ~w(P Q1 R same),
     :whole},
    {"30 A edits P and deletes Q, B adds X after Q", ~w(P Q1 R), ~w(PA R), ~w(P Q1 X R), :whole},
    {"31 B deletes Q, A adds Y after Q", ~w(P Q1 R), ~w(P Q1 Y R), ~w(P R), {:ok, ~w(P Y R)}},
    {"33 both delete Q, B edits R", ~w(P Q1 R), ~w(P R), ~w(P RB), :whole},
    {"34 B deletes P and edits Q, A edits P", ~w(P Q1 R S), ~w(PA Q1 R S), ~w(QB R S), :whole},
    {"35 both press Enter at the end", ~w(P Q1 R), ["P", "Q1", "R", ""], ["P", "Q1", "R", ""],
     :whole},
    {"36 A deletes R and edits Q, B edits P", ~w(P Q1 R), ~w(P QA), ~w(PB Q1 R), :whole}
  ]

  for {name, base, mine, theirs, want} <- @cases do
    @row {base, mine, theirs, want}
    test "case #{name}" do
      {base, mine, theirs, want} = @row

      blocks = fn texts ->
        Enum.map(texts, &b("k" <> Integer.to_string(:erlang.unique_integer([:positive])), &1))
      end

      {base, mine, theirs} = {blocks.(base), blocks.(mine), blocks.(theirs)}
      result = M.merge(base, mine, theirs)

      case want do
        {:ok, ws} ->
          assert {:ok, merged} = result
          assert words(merged) == ws

        {:block, ws} ->
          assert {:clash, [_ | _], view} = result
          assert words(view) == ws

        :whole ->
          assert {:clash, _texts, ^mine} = result
      end

      # Never words nobody typed, never a block twice that no side has twice.
      out = with({:ok, m} <- result, do: m) |> then(&if(is_list(&1), do: &1, else: elem(&1, 2)))
      known = words(base) ++ words(mine) ++ words(theirs)
      assert Enum.all?(words(out), &(&1 in known))

      for w <- words(out),
          do:
            assert(
              Enum.count(words(out), &(&1 == w)) <=
                max(Enum.count(words(mine), &(&1 == w)), Enum.count(words(theirs), &(&1 == w)))
            )
    end
  end
end
