defmodule Barkpark.Content.PortableTextMerge do
  @moduledoc """
  A three-way merge of two Portable Text values, block by block
  (task-47be2cdf59d0acd5, #28349 r3 review K5/K8/S5p, r4 review).

  `base` is the value an editor was given, `mine` what it posts, `theirs`
  what the store holds now. Each side's blocks are lined up with the base's
  by their words (a longest common subsequence of the blocks as drawn), not
  by `_key`: a save through the editor's HTML gives its blocks new keys, so
  keys do not name a block from one save to the next. Between two blocks a
  side kept, a gap: the base blocks it left out and the blocks it put there.

  It merges only when the line-up is certain, and never writes words nobody
  typed (#28349 r4 review, cases 03-35):

    * A gap that left blocks out and put a different number of blocks in
      (a split, a join, a delete or an insert beside an edit) cannot be
      lined up block by block: the whole value is a clash.
    * Both sides added blocks at one place, or one side added blocks inside
      a gap of the other's that spans several base blocks: a clash.
    * A base block both sides changed, each in a gap of one block for one,
      is merged inside the block when each changed its text or marks in one
      place, and the places are words apart (`PortableTextMerge.Inline`,
      task-da701626f5be2143); else it is a clash of that block. Both
      changed it to the same words: one change. Any other block both
      touched (one deleted it, or one changed it in a wider gap): the whole
      value is a clash.
    * Where the words can be lined up more than one way (two identical
      paragraphs, empty ones) and the other side touched a block whose
      place depends on the choice: the whole value is a clash.
    * Past `@max_cells` (blocks of the base × blocks of a side), or past
      `@max_objects` inline objects in the three values, the merge is not
      tried: a clash.
    * Otherwise each base block takes the one side that changed or deleted
      it, and blocks a side added go in where it put them.

  A clash returns only what the editor may show, never a value to store:
  the caller keeps theirs stored (#28349 r4 review, rule 1). TanStack's
  PortableTextInput applies another editor's block patches to the focused
  editor, so a paragraph added in another block is never a clash there.
  """

  alias Barkpark.Content.{PortableText, PortableTextAlign}
  alias Barkpark.Content.PortableTextMerge.Inline

  # Blocks lined up at most: base × side.
  @max_cells 20_000

  # Inline objects in base, mine and theirs together, at most
  # (task-1cb50a8ed57c0547, #28817 review N2): the byte caps count only
  # text, and drawing and lining up objects costs about 3,500 reductions
  # each per side, so 50,000 in one block cost 107-177M, over the 80M save
  # bound. 15,000 keeps a merge near 20M.
  @max_objects 15_000

  # Text merged inside blocks per merge, at most (base + mine + theirs bytes
  # of each such block): past it, a block both changed is a clash of it, as
  # before (about 21 reductions a byte, so a save stays near 40M).
  @inline_bytes 2_000_000

  @doc """
  `{:ok, merged}` when the line-up is certain and no block clashed. Else
  `{:clash, texts, view}`: `view` is what the editor keeps showing (mine for
  each clashed block and theirs elsewhere; mine wherever mine touched and
  theirs elsewhere when a block both touched is not one clear clash; mine
  whole when the line-up is not certain), and `texts` are theirs words the view does not show, for
  the banner. A clash is never stored.

  `opts`: `inline: false` (tests only) leaves out the merge inside one
  block (`Inline`, task-266ffbe9cd115f3c): a block both changed is then a
  clash of that block, as before it.
  """
  def merge(base, mine, theirs, opts \\ []) do
    base = list(base)
    {mine, theirs} = {list(mine), list(theirs)}

    cond do
      length(base) * max(length(mine), length(theirs)) > @max_cells ->
        whole_clash(mine, theirs)

      objects(base) + objects(mine) + objects(theirs) > @max_objects ->
        {:clash, plain_banner(mine, theirs), mine}

      true ->
        line_up(base, mine, theirs, opts)
    end
  end

  defp line_up(base, mine, theirs, opts) do
    m = edits(base, mine)
    t = edits(base, theirs)

    cond do
      not (certain?(m, t) and certain?(t, m)) -> whole_clash(mine, theirs)
      crossed?(m, t) -> crossed_view(base, mine, theirs, m, t)
      true -> three_way(base, m, t, Keyword.get(opts, :inline, true) && keys(mine, theirs))
    end
  end

  # Inline objects (children that are not spans) of a value.
  defp objects(blocks) do
    Enum.reduce(blocks, 0, fn b, n ->
      Enum.reduce(children(b), n, fn
        %{"_type" => "span"}, n -> n
        %{}, n -> n + 1
        _c, n -> n
      end)
    end)
  end

  # The banner past `@max_objects`: theirs' words in each block mine does not
  # hold as it is, never drawn (drawing is what the cap bounds).
  defp plain_banner(mine, theirs) do
    have = MapSet.new(mine, &Map.delete(&1, "_key"))
    for b <- theirs, not MapSet.member?(have, Map.delete(b, "_key")), do: text(b)
  end

  # Nothing of `side`'s needs a guess next to what `other` did.
  defp certain?(side, other) do
    Enum.all?(side.gaps, fn {gone, new} ->
      gone == [] or new == [] or length(gone) == length(new)
    end) and
      not unsure?(side.unsure, other.at, other.ins) and
      Enum.all?(Map.keys(side.ins), fn p ->
        not Map.has_key?(other.ins, p) and not inside?(p, other.gaps)
      end)
  end

  # An insert after base index `p` falls between two blocks a gap left out.
  defp inside?(p, gaps) do
    Enum.any?(gaps, fn {gone, _new} -> gone != [] and hd(gone) <= p and p < List.last(gone) end)
  end

  # A base block both touched that is not one clear clash of one block.
  defp crossed?(m, t) do
    Enum.any?(Map.keys(m.at), fn i ->
      case {Map.fetch(t.at, i), m.at[i]} do
        {:error, _} ->
          false

        {{:ok, te}, me} ->
          not same_edit?(me, te) and
            not (match?({:changed, _}, me) and match?({:changed, _}, te) and
                   MapSet.member?(m.one, i) and MapSet.member?(t.one, i))
      end
    end)
  end

  # `keys`: how many times the field uses each key, for an inline object of
  # a block merged inside it (`Inline`, task-8619a5423030aca8); false
  # leaves the merge inside one block out.
  defp three_way(base, m, t, keys) do
    budget = if keys, do: @inline_bytes, else: -1

    {at, _left} =
      base
      |> Enum.with_index()
      |> Enum.map_reduce(budget, fn {block, i}, left ->
        {me, te} = {Map.get(m.at, i, :same), Map.get(t.at, i, :same)}
        cost = bytes(block, me, te)
        {pick(block, me, te, cost <= left && keys), if(cost <= left, do: left - cost, else: left)}
      end)

    case for({:clash, _, {:changed, b}} <- at, do: text(b)) do
      [] -> {:ok, build(at, m.ins, t.ins)}
      texts -> {:clash, texts, build(at, m.ins, t.ins)}
    end
  end

  # Mine shown as it is; the banner shows theirs blocks that mine does not
  # have.
  defp whole_clash(mine, theirs), do: {:clash, banner(mine, theirs), mine}

  # Every one: typing on the view saves it over theirs, so a block of theirs
  # in neither the view nor the banner was lost with no word. A cap of 5
  # did that in 38 of 6,000 generated clashes (task-f3594c6613f4663e).
  defp banner(view, theirs) do
    have = MapSet.new(view, &drawn/1)
    for b <- theirs, not MapSet.member?(have, drawn(b)), do: text(b)
  end

  # Lined up, but a block both touched is not one clear clash of one block
  # (B changed it with the block next to it): mine wherever mine touched,
  # theirs elsewhere, so the view keeps every change of theirs outside what
  # mine touched and typing on it never takes one out
  # (task-77c9532e1e04907b; before it, mine whole). Blocks neither touched
  # are mine's own. One side deleted a block both touched: mine whole. A view that would hold a word more often than either
  # side does (a gap of theirs zipped onto blocks it moved): mine whole.
  defp crossed_view(base, mine, theirs, m, t) do
    if deleted?(m, t),
      do: whole_clash(mine, theirs),
      else: crossed_view(base, mine, theirs, m, t, kept(base, mine))
  end

  # A block both touched that one side deleted: theirs' blocks next to it
  # may be it, moved (case 10).
  defp deleted?(m, t),
    do: Enum.any?(m.at, fn {i, me} -> Map.has_key?(t.at, i) and :deleted in [me, t.at[i]] end)

  defp crossed_view(base, mine, theirs, m, t, kept) do
    at =
      base
      |> Enum.with_index()
      |> Enum.map(fn {block, i} ->
        case {Map.get(m.at, i, :same), Map.get(t.at, i, :same)} do
          {:same, :same} -> {:keep, Map.get(kept, i, block)}
          {:same, te} -> {:take, te}
          {me, _te} -> {:take, me}
        end
      end)

    view = build(at, m.ins, t.ins)

    if bounded?(view, mine, theirs),
      do: {:clash, banner(view, theirs), view},
      else: whole_clash(mine, theirs)
  end

  # Each base index mine kept, to mine's own block there.
  defp kept(base, mine) do
    pairs = PortableTextAlign.pairs(Enum.map(base, &shape/1), Enum.map(mine, &shape/1))
    mine_at = List.to_tuple(mine)
    Map.new(pairs, fn {i, j} -> {i, elem(mine_at, j)} end)
  end

  defp bounded?(view, mine, theirs) do
    {v, mw, tw} = {words(view), words(mine), words(theirs)}
    Enum.all?(v, fn {w, n} -> n <= max(Map.get(mw, w, 0), Map.get(tw, w, 0)) end)
  end

  defp words(blocks) do
    blocks
    |> Enum.flat_map(&String.split(text(&1)))
    |> Enum.frequencies()
  end

  # A block whose place in one side's line-up is not certain, that the
  # other side changed, deleted or added a block next to.
  defp unsure?(unsure, at, ins) do
    touched = Map.keys(at) ++ for({i, _} <- ins, k <- [i, i + 1], do: k)
    Enum.any?(touched, &MapSet.member?(unsure, &1))
  end

  @doc """
  Whether two values draw the same, keys set aside, as this merge compares
  blocks: the store still holds what a tab believed it held
  (`Forms.ObjectRebase`, task-00c56c6a88ed0b8f).
  """
  def same_drawn?(a, b), do: Enum.map(list(a), &drawn/1) == Enum.map(list(b), &drawn/1)

  defp list(v) when is_list(v), do: v
  defp list(_v), do: []

  # One base block: what each side did with it. Both changed it otherwise
  # only in one-block gaps (`crossed?/2`): merged inside the block
  # (`{:inline, block}`) or a clash of it.
  defp pick(block, :same, :same, _inline?), do: {:keep, block}
  defp pick(_block, m, :same, _inline?), do: {:take, m}
  defp pick(_block, :same, t, _inline?), do: {:take, t}

  defp pick(block, m, t, inline?) do
    cond do
      same_edit?(m, t) -> {:take, t}
      inline? -> inline(block, m, t, inline?)
      true -> {:clash, m, t}
    end
  end

  defp inline(block, {:changed, mb} = m, {:changed, tb} = t, keys) do
    own = Enum.frequencies(Enum.map(children(mb) ++ children(tb), &child_key/1))
    elsewhere = &(Map.get(keys, &1, 0) > Map.get(own, &1, 0))

    case Inline.merge(block, mb, tb, elsewhere: elsewhere) do
      {:ok, merged} -> {:inline, merged}
      :clash -> {:clash, m, t}
    end
  end

  defp inline(_block, m, t, _keys), do: {:clash, m, t}

  # Each key the field uses, counted over both sides' blocks and children.
  defp keys(mine, theirs) do
    (mine ++ theirs)
    |> Enum.flat_map(fn
      %{"children" => cs} = b when is_list(cs) -> [b["_key"] | Enum.map(cs, &child_key/1)]
      b -> [child_key(b)]
    end)
    |> Enum.frequencies()
  end

  defp children(%{"children" => cs}) when is_list(cs), do: cs
  defp children(_block), do: []

  defp child_key(%{"_key" => k}), do: k
  defp child_key(_child), do: nil

  # The text `Inline` reads for a block both changed; 0 for any other.
  defp bytes(block, {:changed, a}, {:changed, b}),
    do: Enum.sum(Enum.map([block, a, b], &byte_size(text(&1))))

  defp bytes(_block, _m, _t), do: 0

  defp same_edit?(:deleted, :deleted), do: true
  defp same_edit?({:changed, a}, {:changed, b}), do: shape(a) == shape(b)
  defp same_edit?(_, _), do: false

  # Mine for a clashed block. Inserts at one place come from one side only
  # (`certain?/2`).
  defp build(at, m_ins, t_ins) do
    head = Map.get(t_ins, -1, []) ++ Map.get(m_ins, -1, [])

    body =
      at
      |> Enum.with_index()
      |> Enum.flat_map(fn {edit, i} ->
        block =
          case edit do
            {:keep, b} -> [b]
            {:take, {:changed, b}} -> [b]
            {:inline, b} -> [b]
            {:take, :deleted} -> []
            {:clash, {:changed, b}, _t} -> [b]
          end

        block ++ Map.get(t_ins, i, []) ++ Map.get(m_ins, i, [])
      end)

    (head ++ body) |> unique_keys() |> unique_objects()
  end

  # What a side did, against the base:
  #
  #   * `at`: each base index it changed or deleted (`{:changed, block}` or
  #     `:deleted`), and `one`, those changed in a gap of one block for one;
  #   * `ins`: the blocks it added after each base index (`-1`, the start);
  #   * `gaps`: each gap as `{base indexes left out, blocks put in}`;
  #   * `unsure`: base indexes whose line-up can go more than one way.
  defp edits(base, side) do
    {a, b} = {Enum.map(base, &shape/1), Enum.map(side, &shape/1)}
    {pairs, unsure} = lcs(a, b)
    side_at = List.to_tuple(side)

    gaps =
      pairs
      |> PortableTextAlign.gaps(length(base), length(side))
      |> Enum.map(fn {b0, gone, new} -> {b0, gone, Enum.map(new, &elem(side_at, &1))} end)
      |> Enum.reject(fn {_b0, gone, new} -> gone == [] and new == [] end)

    Enum.reduce(gaps, %{at: %{}, one: MapSet.new(), ins: %{}, gaps: [], unsure: unsure}, fn
      {b0, [], new}, acc ->
        %{acc | ins: Map.put(acc.ins, b0, new), gaps: [{[], new} | acc.gaps]}

      {_b0, gone, new}, acc when length(gone) == length(new) or new == [] ->
        at =
          if new == [],
            do: Map.new(gone, &{&1, :deleted}),
            else: Map.new(Enum.zip(gone, new), fn {i, bl} -> {i, {:changed, bl}} end)

        one = if length(gone) == 1 and new != [], do: MapSet.put(acc.one, hd(gone)), else: acc.one
        %{acc | at: Map.merge(acc.at, at), one: one, gaps: [{gone, new} | acc.gaps]}

      {_b0, gone, new}, acc ->
        %{acc | gaps: [{gone, new} | acc.gaps]}
    end)
  end

  # Index pairs of a longest common subsequence of `a` and `b`, in order
  # (`PortableTextAlign`, the line-up the key pairing uses too), and the
  # indexes of `a` whose pairing differs between such subsequences.
  defp lcs(a, b) do
    pairs = PortableTextAlign.pairs(a, b)
    {a, b} = {List.to_tuple(a), List.to_tuple(b)}
    {l, c} = tables(a, b)

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

  # An inline object key is unique in the whole field (task-1f8cff9d0bb3af3e,
  # #28817 review T1): theirs' new object keeps its key, and mine may have
  # put the same key in another block. The one later in the field gets a key
  # no block or child of the field uses. `next` carries each key's counter,
  # so d objects sharing a key cost d tries, not d² (#28861 review: a paste
  # of one object 16k times took 24 s).
  defp unique_objects(blocks) do
    used =
      MapSet.new(
        Enum.flat_map(blocks, &[&1["_key"] | Enum.map(children(&1), fn c -> child_key(c) end)])
      )

    {out, _} =
      Enum.map_reduce(blocks, {MapSet.new(), used, %{}}, fn
        %{"children" => cs} = b, acc when is_list(cs) ->
          {cs, acc} = Enum.map_reduce(cs, acc, &object_key/2)
          {Map.put(b, "children", cs), acc}

        b, acc ->
          {b, acc}
      end)

    out
  end

  defp object_key(%{"_type" => type, "_key" => k} = c, {objects, used, next})
       when is_binary(k) and type != "span" do
    if MapSet.member?(objects, k) do
      {k2, n} = fresh_n(k, used, Map.get(next, k, 1))

      {Map.put(c, "_key", k2),
       {MapSet.put(objects, k2), MapSet.put(used, k2), Map.put(next, k, n + 1)}}
    else
      {c, {MapSet.put(objects, k), used, next}}
    end
  end

  defp object_key(c, acc), do: {c, acc}

  defp fresh_n(k, seen, n) do
    k2 = "#{k}m#{n}"
    if MapSet.member?(seen, k2), do: fresh_n(k, seen, n + 1), else: {k2, n}
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

  # A block as the line-up reads it: as drawn, and a text block's own fields
  # beside the drawing (task-68298dcf20a1ec8a, #28817 review T2). A field
  # change that draws the same (`level` without `listItem`, an unknown
  # field, a `style` removed) read as no change, and the merge dropped it.
  # `same_drawn?/2` stays by the drawing: it compares a page's posted HTML,
  # which carries no such field.
  defp shape(%{"_type" => "block"} = block),
    do: {drawn(block), Map.drop(block, ["_key", "children", "markDefs"])}

  defp shape(block), do: drawn(block)

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
