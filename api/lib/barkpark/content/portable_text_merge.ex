defmodule Barkpark.Content.PortableTextMerge do
  @moduledoc """
  A three-way merge of two Portable Text values, block by block
  (task-47be2cdf59d0acd5, #28349 r3 review K5/K8/S5p).

  `base` is the value an editor was given, `mine` what it posts, `theirs`
  what the store holds now. Each side's blocks are lined up with the base's
  by their words (a longest common subsequence of the blocks as drawn), not
  by `_key`: a save through the editor's HTML gives its blocks new keys, so
  keys do not name a block from one save to the next. A base block a side
  left out, where that side has a new block in its place, is that block
  changed; one it left out with nothing in its place, deleted.

    * A block only one side changed or deleted takes that side's version.
    * Blocks a side added go in where it put them, theirs before mine when
      both added at one place.
    * A block both changed to the same words is one change.
    * A block both changed (or one changed and the other deleted) is a
      clash: TanStack's clash card. The letters inside one block are not
      merged here (task-b655cb81bcb4b164).
    * Where the words can be lined up more than one way (two identical
      paragraphs, empty ones, a block B moved) and the other side touched a
      block whose place depends on the choice, the whole value is a clash:
      the store keeps theirs, the editor keeps mine. Never a silent pick.
    * Past `@max_cells` (blocks of the base × blocks of a side) the merge is
      not tried: a clash, as above.

  TanStack's PortableTextInput applies another editor's block patches to the
  focused editor, so a paragraph added in another block is never a clash
  there either.
  """

  alias Barkpark.Content.PortableText

  # Blocks lined up at most: base × side.
  @max_cells 20_000

  @doc """
  `{:ok, merged}` when no block clashed. Else `{:clash, texts, stored,
  view}`: `stored` takes theirs for each clashed block and every other
  change of both (what may be saved), `view` takes mine for each clashed
  block (what the editor keeps showing), and `texts` are theirs words of the
  clashed blocks, for the banner.
  """
  def merge(base, mine, theirs) do
    base = list(base)
    {mine, theirs} = {list(mine), list(theirs)}

    if length(base) * max(length(mine), length(theirs)) > @max_cells do
      whole_clash(mine, theirs)
    else
      {m_at, m_ins, m_unsure} = edits(base, mine)
      {t_at, t_ins, t_unsure} = edits(base, theirs)

      if unsure?(m_unsure, t_at, t_ins) or unsure?(t_unsure, m_at, m_ins),
        do: whole_clash(mine, theirs),
        else: three_way(base, {m_at, m_ins}, {t_at, t_ins})
    end
  end

  defp three_way(base, {m_at, m_ins}, {t_at, t_ins}) do
    at =
      base
      |> Enum.with_index()
      |> Enum.map(fn {block, i} ->
        pick(block, Map.get(m_at, i, :same), Map.get(t_at, i, :same))
      end)

    clashed = for {:clash, _, t} <- at, do: t

    if clashed == [] do
      {:ok, build(at, m_ins, t_ins, :theirs)}
    else
      texts = for {:changed, b} <- clashed, do: text(b)
      {:clash, texts, build(at, m_ins, t_ins, :theirs), build(at, m_ins, t_ins, :mine)}
    end
  end

  # Theirs stored as it is, mine shown as it is; the banner shows theirs
  # blocks that mine does not have.
  defp whole_clash(mine, theirs) do
    have = MapSet.new(mine, &drawn/1)
    texts = for b <- theirs, not MapSet.member?(have, drawn(b)), do: text(b)
    {:clash, Enum.take(texts, 5), theirs, mine}
  end

  # A block whose place in one side's line-up is not certain, that the
  # other side changed, deleted or added a block next to.
  defp unsure?(unsure, at, ins) do
    touched = Map.keys(at) ++ for({i, _} <- ins, k <- [i, i + 1], do: k)
    Enum.any?(touched, &MapSet.member?(unsure, &1))
  end

  defp list(v) when is_list(v), do: v
  defp list(_v), do: []

  # One base block: what each side did with it.
  defp pick(block, :same, :same), do: {:keep, block}
  defp pick(_block, m, :same), do: {:take, m}
  defp pick(_block, :same, t), do: {:take, t}

  defp pick(_block, m, t) do
    if same_edit?(m, t), do: {:take, t}, else: {:clash, m, t}
  end

  defp same_edit?(:deleted, :deleted), do: true
  defp same_edit?({:changed, a}, {:changed, b}), do: drawn(a) == drawn(b)
  defp same_edit?(_, _), do: false

  defp build(at, m_ins, t_ins, wins) do
    head = Map.get(t_ins, -1, []) ++ Map.get(m_ins, -1, [])

    body =
      at
      |> Enum.with_index()
      |> Enum.flat_map(fn {edit, i} ->
        block =
          case edit do
            {:keep, b} -> [b]
            {:take, {:changed, b}} -> [b]
            {:take, :deleted} -> []
            {:clash, m, t} -> side_block(if(wins == :mine, do: m, else: t))
          end

        block ++ Map.get(t_ins, i, []) ++ Map.get(m_ins, i, [])
      end)

    unique_keys(head ++ body)
  end

  defp side_block({:changed, b}), do: [b]
  defp side_block(:deleted), do: []

  # Each base index a side changed or deleted (`%{i => {:changed, block} |
  # :deleted}`), and the blocks it added after each base index (`-1` for the
  # start).
  defp edits(base, side) do
    {a, b} = {Enum.map(base, &drawn/1), Enum.map(side, &drawn/1)}
    {pairs, unsure} = lcs(a, b)
    {at, ins} = lined_up(base, side, pairs)
    {at, ins, unsure}
  end

  defp lined_up(base, side, pairs) do
    anchors = [{-1, -1}] ++ pairs ++ [{length(base), length(side)}]

    anchors
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({%{}, %{}}, fn [{b0, s0}, {b1, s1}], {at, ins} ->
      gone = Enum.to_list((b0 + 1)..(b1 - 1)//1)
      # Start and count: a range ending at -1 would read as the last index.
      new = Enum.slice(side, s0 + 1, s1 - s0 - 1)
      {paired, rest_gone, rest_new} = pair(gone, new)

      at = Enum.reduce(paired, at, fn {i, b}, at -> Map.put(at, i, {:changed, b}) end)
      at = Enum.reduce(rest_gone, at, fn i, at -> Map.put(at, i, :deleted) end)

      after_i =
        case paired do
          [] -> b0
          _ -> paired |> List.last() |> elem(0)
        end

      ins =
        if rest_new == [],
          do: ins,
          else: Map.update(ins, after_i, rest_new, &(&1 ++ rest_new))

      {at, ins}
    end)
  end

  defp pair([i | gone], [b | new]) do
    {paired, g, n} = pair(gone, new)
    {[{i, b} | paired], g, n}
  end

  defp pair(gone, new), do: {[], gone, new}

  # Index pairs of a longest common subsequence of `a` and `b`, in order,
  # and the indexes of `a` whose pairing differs between such subsequences.
  defp lcs(a, b) do
    {a, b} = {List.to_tuple(a), List.to_tuple(b)}
    {n, m} = {tuple_size(a), tuple_size(b)}
    {l, c} = tables(a, b)
    pairs = walk({a, b, l, n, m}, 0, 0, [])

    unsure =
      if c[{0, 0}] == 1 do
        MapSet.new()
      else
        {lr, cr} = tables(reverse(a), reverse(b))
        unsure(a, b, {l, c}, {lr, cr})
      end

    {pairs, unsure}
  end

  defp reverse(t), do: t |> Tuple.to_list() |> Enum.reverse() |> List.to_tuple()

  # For every suffix pair: the length of their longest common subsequence
  # (`l`) and how many distinct sets of index pairs reach it (`c`). A set
  # without the pair {i, j} leaves out row i or column j (pairs never cross),
  # hence the inclusion–exclusion.
  defp tables(a, b) do
    {n, m} = {tuple_size(a), tuple_size(b)}

    for i <- n..0//-1, j <- m..0//-1, reduce: {%{}, %{}} do
      {l, c} ->
        if i == n or j == m do
          {Map.put(l, {i, j}, 0), Map.put(c, {i, j}, 1)}
        else
          eq = elem(a, i) == elem(b, j)
          {down, right, diag} = {l[{i + 1, j}], l[{i, j + 1}], l[{i + 1, j + 1}]}
          v = if eq, do: diag + 1, else: max(down, right)

          k =
            if(eq, do: c[{i + 1, j + 1}], else: 0) +
              if(down == v, do: c[{i + 1, j}], else: 0) +
              if(right == v, do: c[{i, j + 1}], else: 0) -
              if(diag == v, do: c[{i + 1, j + 1}], else: 0)

          {Map.put(l, {i, j}, v), Map.put(c, {i, j}, k)}
        end
    end
  end

  # An index of `a` is certain when every longest subsequence pairs it with
  # one `b` index, or none does; one none pairs, beside an unsure one, is
  # unsure too (its gap moves).
  defp unsure(a, b, {l, c}, {lr, cr}) do
    {n, m} = {tuple_size(a), tuple_size(b)}
    {best, total} = {l[{0, 0}], c[{0, 0}]}

    through =
      for i <- 0..(n - 1)//1 do
        for j <- 0..(m - 1)//1,
            elem(a, i) == elem(b, j),
            lr[{n - i, m - j}] + 1 + l[{i + 1, j + 1}] == best,
            do: cr[{n - i, m - j}] * c[{i + 1, j + 1}]
      end

    moved = for {ts, i} <- Enum.with_index(through), ts != [] and total not in ts, do: i
    moved = MapSet.new(moved)

    none =
      for {[], i} <- Enum.with_index(through),
          MapSet.member?(moved, i - 1) or MapSet.member?(moved, i + 1),
          do: i

    MapSet.union(moved, MapSet.new(none))
  end

  defp walk({_a, _b, _l, n, m}, i, j, acc) when i >= n or j >= m, do: Enum.reverse(acc)

  defp walk({a, b, l, _n, _m} = g, i, j, acc) do
    cond do
      elem(a, i) == elem(b, j) -> walk(g, i + 1, j + 1, [{i, j} | acc])
      l[{i + 1, j}] >= l[{i, j + 1}] -> walk(g, i + 1, j, acc)
      true -> walk(g, i, j + 1, acc)
    end
  end

  # A merge can put two blocks with one `_key` side by side (each side kept
  # the key of the base block it changed): the later one gets a new key.
  defp unique_keys(blocks) do
    {out, _} =
      Enum.map_reduce(blocks, MapSet.new(), fn
        %{"_key" => k} = b, seen when is_binary(k) ->
          if MapSet.member?(seen, k) do
            k2 = fresh(k, seen, 1)
            {Map.put(b, "_key", k2), MapSet.put(seen, k2)}
          else
            {b, MapSet.put(seen, k)}
          end

        b, seen ->
          {b, seen}
      end)

    out
  end

  defp fresh(k, seen, n) do
    k2 = "#{k}m#{n}"
    if MapSet.member?(seen, k2), do: fresh(k, seen, n + 1), else: k2
  end

  defp text(%{"children" => children}) when is_list(children),
    do:
      Enum.map_join(children, fn c -> (is_map(c) && is_binary(c["text"]) && c["text"]) || "" end)

  defp text(%{"_type" => type}) when is_binary(type), do: "[#{type}]"
  defp text(_block), do: ""

  # A text block as the editor draws it, keys set aside; a custom block (a
  # mediaModule) by its fields, since its drawn summary can hide a change.
  defp drawn(%{"_type" => "block"} = block) do
    block = rekey(block)
    if PortableText.value?([block]), do: PortableText.to_html([block]), else: block
  end

  defp drawn(%{} = block), do: Map.delete(block, "_key")
  defp drawn(other), do: other

  defp rekey(%{"children" => children} = block) when is_list(children) do
    defs = if is_list(block["markDefs"]), do: block["markDefs"], else: []

    renamed =
      defs |> Enum.with_index() |> Map.new(fn {d, j} -> {is_map(d) && d["_key"], "m#{j}"} end)

    children =
      children
      |> Enum.with_index()
      |> Enum.map(fn
        {%{} = c, j} ->
          c = Map.put(c, "_key", "s#{j}")

          if is_list(c["marks"]),
            do: Map.put(c, "marks", Enum.map(c["marks"], &Map.get(renamed, &1, &1))),
            else: c

        {c, _j} ->
          c
      end)

    defs =
      Enum.map(defs, &if(is_map(&1), do: Map.put(&1, "_key", renamed[&1["_key"]]), else: &1))

    block |> Map.put("_key", "k") |> Map.put("children", children) |> Map.put("markDefs", defs)
  end

  defp rekey(block), do: Map.put(block, "_key", "k")
end
