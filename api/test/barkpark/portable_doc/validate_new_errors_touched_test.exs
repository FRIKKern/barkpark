defmodule Barkpark.PortableDoc.Validate.NewErrorsTouchedTest do
  @moduledoc """
  `NewErrors.split_touched/2` (the op and batch check, R4.5) gives the same
  answer as the whole-doc `split/2` while validating only the top-level blocks
  a write touched. Seeded random papers and edits, synthetic blocks only.
  """

  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Validate
  alias Barkpark.PortableDoc.Validate.NewErrors

  @cases 600

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp leaf(id, kind) do
    case kind do
      0 -> %{"id" => id, "type" => "paragraph", "content" => text(id)}
      1 -> %{"id" => id, "type" => "heading", "level" => 9, "text" => id}
      2 -> %{"id" => id, "type" => "heading", "level" => true, "text" => id}
      3 -> %{"id" => id, "type" => "paragraph", "content" => [%{"value" => id}]}
      _ -> %{"id" => id, "type" => "heading", "level" => 2, "text" => id}
    end
  end

  defp block(id) do
    case :rand.uniform(8) do
      7 ->
        children =
          Enum.map(1..:rand.uniform(3), fn _ -> leaf(nested_id(), :rand.uniform(5) - 1) end)

        %{"id" => id, "type" => "section", "blocks" => children}

      8 ->
        items =
          Enum.map(1..:rand.uniform(3), fn n ->
            item = %{"content" => text("i#{n}")}
            if :rand.uniform(3) == 1, do: Map.put(item, "checked", "yes"), else: item
          end)

        %{"id" => id, "type" => "list", "ordered" => false, "items" => items}

      kind ->
        leaf(id, rem(kind, 5))
    end
  end

  defp idless, do: block("x") |> Map.delete("id")

  defp nested_id, do: "n#{:rand.uniform(6)}"
  defp fresh_id, do: "b#{System.unique_integer([:positive])}"

  defp paper,
    do:
      Enum.map(1..:rand.uniform(8), fn _ ->
        if :rand.uniform(10) == 1, do: idless(), else: block(fresh_id())
      end)

  defp edit(blocks) do
    case {:rand.uniform(7), blocks} do
      {_, []} ->
        [block(fresh_id())]

      {1, _} ->
        List.insert_at(blocks, :rand.uniform(length(blocks) + 1) - 1, block(fresh_id()))

      {2, _} ->
        List.delete_at(blocks, :rand.uniform(length(blocks)) - 1)

      {3, _} ->
        at = :rand.uniform(length(blocks)) - 1
        List.update_at(blocks, at, &block(&1["id"]))

      {4, _} ->
        at = :rand.uniform(length(blocks)) - 1
        {moved, rest} = List.pop_at(blocks, at)
        List.insert_at(rest, :rand.uniform(length(rest) + 1) - 1, moved)

      {5, _} ->
        nested = %{"id" => fresh_id(), "type" => "section", "blocks" => [leaf(nested_id(), 1)]}
        List.insert_at(blocks, :rand.uniform(length(blocks) + 1) - 1, nested)

      {6, _} ->
        Enum.map(blocks, fn block ->
          if :rand.uniform(3) == 1, do: block(block["id"]), else: block
        end)

      {7, _} ->
        List.insert_at(blocks, :rand.uniform(length(blocks) + 1) - 1, idless())
    end
  end

  defp edits(blocks, 0), do: blocks
  defp edits(blocks, n), do: blocks |> edit() |> edits(n - 1)

  defp counted(errors), do: Enum.frequencies_by(errors, & &1.code)

  defp nested_id_spans_blocks?(blocks) do
    blocks
    |> Enum.flat_map(fn block ->
      (block["blocks"] || []) |> Enum.map(& &1["id"]) |> Enum.uniq()
    end)
    |> Enum.frequencies()
    |> Enum.any?(fn {_id, n} -> n > 1 end)
  end

  # Two errors with one key (a nested id repeated in two top-level blocks) are
  # one count: whole-doc labels the first in the paper old, touched-only labels
  # the one in the edited block added. The counts always agree.
  test "the touched-only answer equals the whole-doc answer on #{@cases} random edits" do
    :rand.seed(:exsss, {45, 4, 5})

    for _case <- 1..@cases do
      stored = paper()
      written = edits(stored, :rand.uniform(3))
      {added, _existing} = NewErrors.split(stored, written)
      {touched_added, _touched_existing} = NewErrors.split_touched(stored, written)

      assert counted(touched_added) == counted(added),
             "stored: #{inspect(stored)}\nwritten: #{inspect(written)}"

      if not nested_id_spans_blocks?(written) do
        assert Enum.sort(touched_added) == Enum.sort(added),
               "stored: #{inspect(stored)}\nwritten: #{inspect(written)}"
      end
    end
  end

  test "repeated top-level ids fall back to the whole-doc answer" do
    repeated = [leaf("a", 1), leaf("a", 0)]

    assert NewErrors.split_touched(repeated, [leaf("z", 0) | repeated]) ==
             NewErrors.split(repeated, [leaf("z", 0) | repeated])
  end

  test "id-less stored blocks count on the stored side: ids minted on a write add no duplicate" do
    section = fn id -> %{"id" => id, "type" => "section", "blocks" => [leaf("n", 0)]} end
    stored = Enum.map([section.("x"), section.("x")], &Map.delete(&1, "id"))
    written = [section.("m1"), section.("m2")]

    assert {[], _existing} = NewErrors.split_touched(stored, written)
    assert {[], _existing} = NewErrors.split(stored, written)
  end

  test "an untouched block is not validated" do
    untouched = leaf("u", 1)
    stored = [untouched, leaf("a", 0)]

    assert {[], []} = NewErrors.split_touched(stored, [untouched, leaf("a", 4)])
    assert {[_], [_]} = NewErrors.split(stored, [untouched, leaf("a", 1)])

    assert {[%{path: "/blocks/1/level"}], []} =
             NewErrors.split_touched(stored, [untouched, leaf("a", 1)])
  end

  test "a new block repeating an untouched block's nested id adds one duplicate" do
    section = %{"id" => "s", "type" => "section", "blocks" => [leaf("n", 0)]}

    assert {[%{code: :duplicate_block_id, path: "/blocks/1/id"}], []} =
             NewErrors.split_touched([section], [section, leaf("n", 0)])
  end

  test "an untouched list item with the same id string is not a block" do
    list = %{"id" => "l", "type" => "list", "items" => [%{"id" => "n", "content" => text("x")}]}

    assert NewErrors.split_touched([list], [list, leaf("n", 0)]) ==
             NewErrors.split([list], [list, leaf("n", 0)])
  end

  test "validate/2 is every top-level block's check, then the duplicate rule" do
    :rand.seed(:exsss, {45, 4, 6})

    for _case <- 1..200 do
      blocks = paper() |> edits(2)

      reports =
        blocks |> Enum.with_index() |> Enum.map(fn {b, i} -> Validate.check_top_block(b, i) end)

      errors = Enum.flat_map(reports, &elem(&1, 0))
      ids = Enum.flat_map(reports, &elem(&1, 1))

      expected =
        case errors ++ Validate.duplicate_errors(ids) do
          [] -> :ok
          all -> {:error, all}
        end

      assert Validate.validate(%{"blocks" => blocks}) == expected
    end
  end
end
