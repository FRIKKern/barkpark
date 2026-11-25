defmodule Barkpark.Content.PortableTextAlign do
  @moduledoc """
  The one line-up of two block lists that `PortableTextMerge` (#28349) and
  `PortableTextPairing` share (task-dd2886673f171e40, #28714 review N1).

  The blocks two lists have in common, as a longest common subsequence: the
  fixed points. Between two of them, and before the first and after the
  last, a gap: the blocks of each list left out of the line-up. The merge
  reads a gap as one side's edit of the base; the pairing reads it as the
  stored blocks an edited block can replace. They used to line up blocks
  each their own way and had already drifted: the merge by a longest common
  subsequence, the pairing by a greedy first match, so a block moved up
  was a fixed point to one and not to the other.

  Where more than one line-up is longest (two copies of one block), the
  walk from the start pairs a block of `a` with the block of `b` it meets
  first that is the same, unless leaving it out keeps a longer line-up.
  """

  @typedoc "An index of `a` and the index of `b` it lines up with."
  @type pair :: {non_neg_integer(), non_neg_integer()}

  @doc """
  The index pairs of a longest common subsequence of `a` and `b`, in order.
  `same?` says when a block of `a` and a block of `b` are one block.
  """
  @spec pairs(list(), list(), (term(), term() -> boolean())) :: [pair()]
  def pairs(a, b, same? \\ &==/2) do
    {a, b} = {List.to_tuple(a), List.to_tuple(b)}
    walk(a, b, same?, lengths(a, b, same?), 0, 0, [])
  end

  @doc """
  The gaps between `pairs` (from `pairs/3`) of lists of `n` and `m` blocks,
  in order: `{index of a before it (-1 at the start), indexes of a, indexes
  of b}`. Empty gaps are left in.
  """
  @spec gaps([pair()], non_neg_integer(), non_neg_integer()) :: [
          {integer(), [non_neg_integer()], [non_neg_integer()]}
        ]
  def gaps(pairs, n, m) do
    ([{-1, -1}] ++ pairs ++ [{n, m}])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{a0, b0}, {a1, b1}] ->
      # A range ending at -1 would read as the last index.
      {a0, Enum.to_list((a0 + 1)..(a1 - 1)//1), Enum.to_list((b0 + 1)..(b1 - 1)//1)}
    end)
  end

  # Row i, column j: the length of the longest common subsequence of a from
  # i and b from j. A tuple of rows, built from the last row up.
  defp lengths(a, b, same?) do
    {n, m} = {tuple_size(a), tuple_size(b)}
    last = Tuple.duplicate(0, m + 1)

    (n - 1)..0//-1
    |> Enum.reduce({[last], last}, fn i, {rows, below} ->
      ai = elem(a, i)

      row =
        (m - 1)..0//-1
        |> Enum.reduce([0], fn j, [right | _] = done ->
          v =
            if same?.(ai, elem(b, j)),
              do: elem(below, j + 1) + 1,
              else: max(elem(below, j), right)

          [v | done]
        end)
        |> List.to_tuple()

      {[row | rows], row}
    end)
    |> elem(0)
    |> List.to_tuple()
  end

  defp walk(a, b, _same?, _l, i, j, acc) when i >= tuple_size(a) or j >= tuple_size(b),
    do: Enum.reverse(acc)

  defp walk(a, b, same?, l, i, j, acc) do
    cond do
      same?.(elem(a, i), elem(b, j)) -> walk(a, b, same?, l, i + 1, j + 1, [{i, j} | acc])
      at(l, i + 1, j) >= at(l, i, j + 1) -> walk(a, b, same?, l, i + 1, j, acc)
      true -> walk(a, b, same?, l, i, j + 1, acc)
    end
  end

  defp at(l, i, j), do: l |> elem(i) |> elem(j)
end
