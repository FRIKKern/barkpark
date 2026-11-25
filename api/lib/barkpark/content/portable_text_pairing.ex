defmodule Barkpark.Content.PortableTextPairing do
  @moduledoc """
  Which stored block an edited block replaces, for `PortableText.from_html/3`
  (task-dc8eaead5484fd12, #28360 review).

  A save through the editor's HTML gives every block a new key, so the blocks
  it posts are read against the stored ones. A block whose HTML is a stored
  block's is that block (`:kept`); the rest were edited or added
  (`:rebuilt`), and an edited block takes the stored block's `_key` and the
  fields the editor does not draw (`adopt/2`). This module says which stored
  block that is. It used to be the one at the same index, so a paragraph
  added above an edited one took the edited one's key and fields, and the
  edited one got a new key. TanStack matches blocks by `_key`.

  The line-up follows `PortableTextMerge` (#28349): the kept blocks are the
  fixed points, and between two of them is a gap, the stored text blocks
  nothing kept and the rebuilt blocks the post put there.

    * Same count on both sides: paired in order, each block edited in place,
      as a gap of one for one is in the merge.
    * Different counts (an insert or a delete beside an edit): each rebuilt
      block is paired with a stored block only by its words, in order, where
      at least half of them are the same (a Dice score of 0.5 over the words
      of the two blocks). A block with no such match is new, and a stored
      block with none was deleted.
    * Past `@max_cells` (rebuilt × stored in one gap) nothing in that gap is
      paired.
  """

  # Rebuilt × stored text blocks in one gap, at most, for a pairing by words.
  @max_cells 10_000

  # The share of words two blocks must have in common to be one block.
  @min_score 0.5

  @doc """
  `%{position => stored_index}`: for each rebuilt text block at `position` in
  `kept`, the index in `stored` of the block it replaces. `kept` holds
  `{:kept, block, stored_index}` and `{:rebuilt, block}`, in posted order.
  """
  @spec pairs([{:kept, map(), non_neg_integer()} | {:rebuilt, map()}], [map()]) :: %{
          non_neg_integer() => non_neg_integer()
        }
  def pairs(kept, stored) do
    used = for {:kept, _block, i} <- kept, into: MapSet.new(), do: i
    stored = List.to_tuple(stored)

    kept
    |> gaps(tuple_size(stored))
    |> Enum.reduce(%{}, fn {lo, hi, rebuilt}, acc ->
      left =
        for j <- (lo + 1)..(hi - 1)//1,
            not MapSet.member?(used, j),
            text_block?(elem(stored, j)),
            do: {j, elem(stored, j)}

      Map.merge(acc, pair(rebuilt, left))
    end)
  end

  # Each gap as {stored index before it, stored index after it, its rebuilt
  # text blocks}. A kept block is a fixed point only when it comes after the
  # last one in stored order too; a block moved up is kept, not a bound.
  defp gaps(kept, n) do
    {gaps, rebuilt, lo} =
      kept
      |> Enum.with_index()
      |> Enum.reduce({[], [], -1}, fn
        {{:kept, _block, i}, _p}, {gaps, rebuilt, lo} when i > lo ->
          {[{lo, i, Enum.reverse(rebuilt)} | gaps], [], i}

        {{:rebuilt, %{"_type" => "block"} = block}, p}, {gaps, rebuilt, lo} ->
          {gaps, [{p, block} | rebuilt], lo}

        _other, acc ->
          acc
      end)

    [{lo, n, Enum.reverse(rebuilt)} | gaps]
  end

  defp text_block?(%{"_type" => "block", "_key" => k}) when is_binary(k), do: true
  defp text_block?(_block), do: false

  defp pair([], _left), do: %{}
  defp pair(_rebuilt, []), do: %{}

  defp pair(rebuilt, left) when length(rebuilt) == length(left),
    do: Map.new(Enum.zip(rebuilt, left), fn {{p, _}, {j, _}} -> {p, j} end)

  defp pair(rebuilt, left) when length(rebuilt) * length(left) > @max_cells, do: %{}

  defp pair(rebuilt, left), do: by_words(rebuilt, left)

  # The order-keeping pairing with the highest total score, counting only
  # pairs at or over `@min_score` (a longest common subsequence, weighted).
  defp by_words(rebuilt, left) do
    r = rebuilt |> Enum.map(fn {p, b} -> {p, words(b)} end) |> List.to_tuple()
    l = left |> Enum.map(fn {j, b} -> {j, words(b)} end) |> List.to_tuple()
    {n, m} = {tuple_size(r), tuple_size(l)}

    table =
      for i <- 0..(n - 1), j <- 0..(m - 1), reduce: %{} do
        t ->
          s = score(elem(elem(r, i), 1), elem(elem(l, j), 1))
          diag = if s >= @min_score, do: get(t, i - 1, j - 1) + s, else: -1.0
          Map.put(t, {i, j}, Enum.max([get(t, i - 1, j), get(t, i, j - 1), diag]))
      end

    walk(table, r, l, n - 1, m - 1, %{})
  end

  defp get(_t, i, j) when i < 0 or j < 0, do: 0.0
  defp get(t, i, j), do: Map.fetch!(t, {i, j})

  defp walk(_t, _r, _l, i, j, acc) when i < 0 or j < 0, do: acc

  defp walk(t, r, l, i, j, acc) do
    here = get(t, i, j)

    cond do
      here == get(t, i - 1, j) ->
        walk(t, r, l, i - 1, j, acc)

      here == get(t, i, j - 1) ->
        walk(t, r, l, i, j - 1, acc)

      true ->
        acc = Map.put(acc, elem(elem(r, i), 0), elem(elem(l, j), 0))
        walk(t, r, l, i - 1, j - 1, acc)
    end
  end

  # Dice over the two blocks' words, counted with repeats.
  defp score([], _b), do: 0.0
  defp score(_a, []), do: 0.0

  defp score(a, b) do
    {fa, fb} = {Enum.frequencies(a), Enum.frequencies(b)}
    shared = Enum.sum(for {w, x} <- fa, y = fb[w], do: min(x, y))
    2 * shared / (length(a) + length(b))
  end

  defp words(%{"children" => children}) when is_list(children) do
    children
    |> Enum.map_join(" ", fn
      %{"text" => text} when is_binary(text) -> text
      _child -> ""
    end)
    |> String.downcase()
    |> String.split()
  end

  defp words(_block), do: []
end
