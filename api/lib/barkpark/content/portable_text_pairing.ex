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

  The kept blocks in stored order are the fixed points, lined up as the
  merge lines up blocks (`PortableTextAlign`, shared with
  `PortableTextMerge`, #28714 review N1). Between two of them is a gap: the
  stored text blocks nothing kept and the rebuilt blocks the post put
  there. A block kept out of that order (`:moved`) is no bound.

    * The same count on both sides: first each pair in place whose words
      agree (a Dice score of 0.5 over the words of the two blocks), so a
      find and replace across the value keeps every key (#28724 review B1).
    * Between those, each rebuilt block is paired with a stored block only
      by its words, in order, where at least half of them are the same. A
      block with no such match is new, and a stored block with none was
      deleted. In order, a block inserted beside a deleted one took its key
      (#28714 review S3).
    * Between all of those, a stretch of one block for one is paired in
      place whatever its words: a heading renamed, an empty paragraph typed
      into, beside an edited block (#28724 review S1). The post carries no
      keys, so a delete and an insert in one place read as a rewrite.
    * Then the rebuilt and stored text blocks no gap paired, across the
      value, by their words: a move puts an edited block and its stored
      block in different gaps (#28714 review S4).
    * The pairing by words has one budget per save, not per gap (#28714
      review): `@max_cells` (rebuilt × stored, summed over the gaps and the
      pass across the value) and `@max_work` (cells × distinct words). A
      stretch past what is left is not paired by words: of the same count,
      it is paired in place, as before; otherwise its blocks are new. The
      budget is spent in document order, so past it the first gaps pair
      (#28714 r2 review: it was spent from the last gap up).
  """

  alias Barkpark.Content.PortableTextAlign

  # Rebuilt × stored text blocks, summed over one save's gaps, at most.
  @max_cells 10_000

  # Cells × distinct words per block, summed over one save's gaps, at most.
  @max_work 2_000_000

  # The share of words two blocks must have in common to be one block.
  @min_score 0.5

  @doc """
  `%{position => stored_index}`: for each rebuilt text block at `position` in
  `kept`, the index in `stored` of the block it replaces. `kept` holds
  `{:kept, block, stored_index}` (in stored order), `{:moved, block,
  stored_index}` and `{:rebuilt, block}`, in posted order.
  """
  @spec pairs([{:kept | :moved, map(), non_neg_integer()} | {:rebuilt, map()}], [map()]) :: %{
          non_neg_integer() => non_neg_integer()
        }
  def pairs(kept, stored) do
    used = for {kind, _block, i} when kind in [:kept, :moved] <- kept, into: MapSet.new(), do: i
    stored = List.to_tuple(stored)
    kept = List.to_tuple(kept)

    {acc, budget} =
      kept
      |> gaps(tuple_size(stored))
      |> Enum.reduce({%{}, {@max_cells, @max_work}}, fn {posted, held}, {acc, budget} ->
        rebuilt = rebuilt(kept, posted)
        left = left(stored, held, used)
        {pairs, budget} = pair(rebuilt, left, budget)
        {Map.merge(acc, pairs), budget}
      end)

    # A block whose stored block a move put in another gap (#28714 review
    # S4: stored A B C, posted C B' A): the edited and stored text blocks no
    # gap paired, across the value, by their words.
    paired = acc |> Map.values() |> MapSet.new() |> MapSet.union(used)

    rebuilt =
      for p <- 0..(tuple_size(kept) - 1)//1,
          not is_map_key(acc, p),
          match?({:rebuilt, %{"_type" => "block"}}, elem(kept, p)),
          do: {p, elem(elem(kept, p), 1)}

    left = left(stored, 0..(tuple_size(stored) - 1)//1, paired)
    {r, l} = {counted_all(rebuilt), counted_all(left)}
    {rest, _budget} = within(r, l, indexes(r), indexes(l), budget, false)
    Map.merge(acc, ids(rest, r, l))
  end

  # Each gap as {positions in `kept`, stored indexes}, from the line-up of
  # the kept blocks in stored order (`PortableTextAlign.gaps/3`, the
  # merge's). A moved block is not a bound.
  defp gaps(kept, n) do
    fixed = for p <- 0..(tuple_size(kept) - 1)//1, {:kept, _b, i} <- [elem(kept, p)], do: {p, i}

    fixed
    |> PortableTextAlign.gaps(tuple_size(kept), n)
    |> Enum.map(fn {_lo, posted, held} -> {posted, held} end)
  end

  defp rebuilt(kept, posted) do
    for p <- posted, {:rebuilt, %{"_type" => "block"} = block} <- [elem(kept, p)], do: {p, block}
  end

  defp left(stored, held, used) do
    for j <- held,
        not MapSet.member?(used, j),
        text_block?(elem(stored, j)),
        do: {j, elem(stored, j)}
  end

  defp text_block?(%{"_type" => "block", "_key" => k}) when is_binary(k), do: true
  defp text_block?(_block), do: false

  defp pair([], _left, budget), do: {%{}, budget}
  defp pair(_rebuilt, [], budget), do: {%{}, budget}

  # A gap's blocks, in three steps (#28724 review):
  #
  #   1. The same count on both sides: each pair in place whose words agree.
  #      A find and replace edits every block in place, and pairs here
  #      whatever the budget (B1).
  #   2. Between those, by words (`by_words/2`), within the budget. Past it,
  #      a stretch of the same count is paired in place, as before.
  #   3. Between all of those, a stretch of one block for one, whatever its
  #      words: a heading renamed or an empty paragraph typed into, beside an
  #      edited block (S1). The post carries no keys, so a delete and an
  #      insert in one place read as that rewrite.
  #
  # An inserted block beside a deleted one is left out by 1 and 2 and is no
  # stretch of one for one, so it takes no key (#28714 review S3).
  defp pair(rebuilt, left, budget) do
    {r, l} = {counted_all(rebuilt), counted_all(left)}
    {n, m} = {tuple_size(r), tuple_size(l)}

    in_place =
      if n == m,
        do: for(k <- 0..(n - 1), score(words_of(r, k), words_of(l, k)) >= @min_score, do: {k, k}),
        else: []

    {found, budget} =
      in_place
      |> PortableTextAlign.gaps(n, m)
      |> Enum.reduce({in_place, budget}, fn {_lo, ri, li}, {acc, budget} ->
        {pairs, budget} = within(r, l, ri, li, budget, true)
        {pairs ++ acc, budget}
      end)

    found = Enum.sort(found)
    ones = for {_lo, [i], [j]} <- PortableTextAlign.gaps(found, n, m), do: {i, j}
    {ids(found ++ ones, r, l), budget}
  end

  # `by_words/2` over the blocks at indexes `ri` of `r` and `li` of `l`, as
  # index pairs, within the budget. Past it nothing, or, when `in_place?`
  # and the counts are the same, each in place.
  defp within(_r, _l, [], _li, budget, _in_place?), do: {[], budget}
  defp within(_r, _l, _ri, [], budget, _in_place?), do: {[], budget}

  defp within(r, l, ri, li, {cells_left, work_left} = budget, in_place?) do
    rs = for i <- ri, do: {i, words_of(r, i)}
    ls = for j <- li, do: {j, words_of(l, j)}
    cells = length(rs) * length(ls)

    cond do
      cells <= cells_left and cells * min(widest(rs), widest(ls)) <= work_left ->
        work = cells * min(widest(rs), widest(ls))
        pairs = by_words(List.to_tuple(rs), List.to_tuple(ls))
        {Map.to_list(pairs), {cells_left - cells, work_left - work}}

      in_place? and length(ri) == length(li) ->
        {Enum.zip(ri, li), budget}

      true ->
        {[], budget}
    end
  end

  defp counted_all(blocks),
    do: blocks |> Enum.map(fn {id, b} -> {id, counted(b)} end) |> List.to_tuple()

  defp words_of(t, k), do: t |> elem(k) |> elem(1)
  defp indexes(t), do: Enum.to_list(0..(tuple_size(t) - 1)//1)

  defp ids(pairs, r, l),
    do: Map.new(pairs, fn {i, j} -> {elem(elem(r, i), 0), elem(elem(l, j), 0)} end)

  # A block's words as {word => count, number of words}.
  defp counted(block) do
    words = words(block)
    {Enum.frequencies(words), length(words)}
  end

  defp widest(blocks), do: blocks |> Enum.map(fn {_, {f, _}} -> map_size(f) end) |> Enum.max()

  # The order-keeping pairing with the highest total score, counting only
  # pairs at or over `@min_score` (a longest common subsequence, weighted).
  defp by_words(r, l) do
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

  # Dice over the two blocks' words, counted with repeats. Two blocks whose
  # lengths alone keep it under `@min_score` are not compared word by word.
  defp score({_fa, 0}, _b), do: 0.0
  defp score(_a, {_fb, 0}), do: 0.0

  defp score({fa, la}, {fb, lb}) do
    if 2 * min(la, lb) / (la + lb) < @min_score do
      0.0
    else
      {small, big} = if map_size(fa) <= map_size(fb), do: {fa, fb}, else: {fb, fa}
      shared = Enum.sum(for {w, x} <- small, y = big[w], do: min(x, y))
      2 * shared / (la + lb)
    end
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
