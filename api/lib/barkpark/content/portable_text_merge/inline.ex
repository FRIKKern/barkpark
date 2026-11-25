defmodule Barkpark.Content.PortableTextMerge.Inline do
  @moduledoc """
  The merge inside one block (task-266ffbe9cd115f3c, task-da701626f5be2143,
  plan /papers/pt-merge-inside-one-block rev 4, part 2): a text block both
  sides changed, each in a gap of one block for one, merges when each side
  changed its text in one place and the places are apart. Called only from
  `PortableTextMerge`'s `pick/4` (task-da701626f5be2143; not yet, task 2a).

    * Letters: one grapheme each, tagged with its span's marks (a decorator
      by name, an annotation by its def without `_key`) and its other span
      fields. A child that is not a span, or a block field any side changed,
      is a clash.
    * One splice per side, as `TextRebase` reads a text: the common prefix
      and suffix of the base's letters and the side's, and the middle of the
      base replaced by the side's. Text only: a splice that only changes
      marks, that changes the marks of letters whose text stays (its ends
      differ from the graphemes' alone), or that puts in letters whose
      marks no letter beside or under it has, is a clash (a mark of its own
      is task 4).
    * Apart: each splice widened to whole words (a run of graphemes with no
      space and no CJK punctuation between them: "example.com", "a/b",
      "x-1", "3.14", "don't" and a space-less Han and kana run are each one
      word, "two。かな" two) leaves at least one base letter between them. Two edits in one word, touching ranges and two
      inserts at one point are a clash: "cart" to "carts" and "dart" would
      give "darts".
    * Built from theirs, as the store holds it: only mine's splice is
      replaced, so every span outside it is theirs' map byte for byte, and
      theirs' defs, used or not, stay. Letters put in join the span they
      touch when the marks are equal, else a new span with mine's span key
      or, when theirs has it, a fresh one unique in the block (a span's
      key is read only under its block).
    * A guard on the result: each word is a word of base, mine or theirs,
      at most count(mine) + count(theirs) - count(base) times, and the text
      splits into the graphemes it was built from (no flag made at a join).
      Otherwise a clash. The snap and the guard read words alike, so each
      alone refuses a word made of two edits; the count bound is defence
      in depth behind the snap.

  A block over `TextRebase.max_bytes/0` of text is a clash, as before.
  """

  alias Barkpark.Content.TextRebase

  @fixed ~w(_key _type children markDefs)

  @doc "The block with both sides' text, or `:clash`."
  @spec merge(map(), map(), map()) :: {:ok, map()} | :clash
  def merge(base, mine, theirs) do
    with true <- Enum.all?([base, mine, theirs], &text_block?/1),
         true <- fields_same?(base, mine, theirs),
         {:ok, b} <- letters(base),
         {:ok, m} <- letters(mine),
         {:ok, t} <- letters(theirs),
         {:ok, ms} <- splice(b, m),
         {:ok, ts} <- splice(b, t),
         true <- ms == ts or apart?(b, ms, ts),
         {:ok, block} <- build(ms, ts, mine, theirs),
         true <- guard?(block, base, mine, theirs) do
      {:ok, block}
    else
      _ -> :clash
    end
  end

  defp text_block?(%{"_type" => "block", "children" => children}) when is_list(children),
    do: byte_size(Enum.map_join(children, &text/1)) <= TextRebase.max_bytes()

  defp text_block?(_block), do: false

  defp fields_same?(base, mine, theirs) do
    keys = Enum.uniq(Map.keys(base) ++ Map.keys(mine) ++ Map.keys(theirs)) -- @fixed
    Enum.all?(keys, &(base[&1] == mine[&1] and mine[&1] == theirs[&1]))
  end

  # [{grapheme, marks}], or :error for a child that is not a span.
  defp letters(block) do
    defs = defs(block)

    block["children"]
    |> Enum.reduce_while({:ok, []}, fn
      %{"_type" => "span", "text" => text} = span, {:ok, acc} when is_binary(text) ->
        tag = tag(span, defs)
        {:cont, {:ok, [Enum.map(String.graphemes(text), &{&1, tag}) | acc]}}

      _child, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, runs} -> {:ok, runs |> Enum.reverse() |> Enum.concat()}
      :error -> :error
    end
  end

  # A span's marks as they read (a def by its content), with its other fields.
  defp tag(span, defs) do
    marks = if is_list(span["marks"]), do: span["marks"], else: []
    named = Enum.map(marks, &if(is_map_key(defs, &1), do: {:def, defs[&1]}, else: {:dec, &1}))
    {Enum.sort(named), Map.drop(span, ~w(_key _type text marks))}
  end

  defp defs(block) do
    for %{"_key" => k} = d <- List.wrap(block["markDefs"]),
        into: %{},
        do: {k, Map.delete(d, "_key")}
  end

  # {from, to, letters}: the side's middle in place of base[from, to). The
  # prefix and suffix are the same on letters as on graphemes alone, or a
  # mark changed on text that did not (#28761 review): :error.
  defp splice(base, side) do
    {p, s} = ends(base, side)

    if {p, s} != ends(Enum.map(base, &elem(&1, 0)), Enum.map(side, &elem(&1, 0))),
      do: :error,
      else: splice(base, side, p, s)
  end

  defp splice(base, side, p, s) do
    {mid, put} =
      {Enum.slice(base, p, length(base) - s - p), Enum.slice(side, p, length(side) - s - p)}

    near = Enum.slice(base, max(p - 1, 0), length(mid) + if(p > 0, do: 2, else: 1))
    allowed = MapSet.new(near, &elem(&1, 1)) |> MapSet.put({[], %{}})

    cond do
      Enum.map(mid, &elem(&1, 0)) == Enum.map(put, &elem(&1, 0)) -> :error
      not marks_kept?(mid, put) -> :error
      Enum.all?(put, &MapSet.member?(allowed, elem(&1, 1))) -> {:ok, {p, length(base) - s, put}}
      true -> :error
    end
  end

  # Inside the splice, the text kept is as long on letters as on graphemes
  # alone: no base letter whose text stayed took other marks
  # (task-81d9efce3bbf6428). The edit script is the shortest, so its kept
  # letters are a longest common run; one tag in the splice needs none. Past
  # @diff_cap letters with marks mixed, the cost is not run: :error.
  @diff_cap 1_000
  defp marks_kept?(mid, put) do
    case MapSet.size(MapSet.new(mid ++ put, &elem(&1, 1))) do
      n when n <= 1 ->
        true

      _ ->
        length(mid) + length(put) <= @diff_cap and
          kept(mid, put) == kept(Enum.map(mid, &elem(&1, 0)), Enum.map(put, &elem(&1, 0)))
    end
  end

  defp kept(a, b) do
    for {:eq, xs} <- List.myers_difference(a, b), reduce: 0, do: (n -> n + length(xs))
  end

  defp ends(base, side) do
    p = prefix(base, side, 0)

    {p,
     min(prefix(Enum.reverse(base), Enum.reverse(side), 0), min(length(base), length(side)) - p)}
  end

  defp prefix([x | a], [x | b], n), do: prefix(a, b, n + 1)
  defp prefix(_a, _b, n), do: n

  # The two splices, widened to whole words, leave a base letter between.
  defp apart?(base, ms, ts) do
    gs = base |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    {{a, b}, {c, d}} = {widen(gs, ms), widen(gs, ts)}
    b < c or d < a
  end

  defp widen(gs, {p, e, _put}) do
    n = tuple_size(gs)
    from = if p > 0 and word?(gs, p - 1), do: edge(gs, p - 1, -1), else: p
    to = if e < n and word?(gs, e), do: edge(gs, e, 1) + 1, else: e
    {from, to}
  end

  defp edge(gs, i, step) do
    j = i + step
    if j >= 0 and j < tuple_size(gs) and word?(gs, j), do: edge(gs, j, step), else: i
  end

  # A word letter: any grapheme but a space and CJK punctuation (。、「」),
  # as `words/1` reads one. A joiner list left gaps: "example.com" to
  # "exampel.com" and "example.org" gave "exampel.org" (task-5d102d5baa016e0a).
  defp word?(gs, i), do: letter?(elem(gs, i))

  @apart ~r/\A(?:[\s\p{Z}]|(?=\p{P})[\x{3000}-\x{303F}\x{FF00}-\x{FFEF}])/u
  defp letter?(g), do: not Regex.match?(@apart, g)

  # Theirs with mine's splice put in (moved by theirs' when theirs' is first).
  defp build(same, same, _mine, theirs), do: {:ok, theirs}

  defp build({mp, me, put}, {tp, te, tput}, mine, theirs) do
    shift = if tp < mp, do: length(tput) - (te - tp), else: 0
    {a, b} = {mp + shift, me + shift}
    defs = Map.new(defs(theirs), fn {k, d} -> {d, k} end)

    keys =
      mine["children"]
      |> Enum.flat_map(&List.duplicate(&1["_key"], glen(&1)))
      |> Enum.slice(mp, length(put))

    with {:ok, new} <- new_spans(Enum.zip(put, keys), defs, theirs) do
      {:ok, Map.put(theirs, "children", cut(theirs, a, b, new))}
    end
  end

  # Mine's letters as spans in theirs' marks ({tag, span}); a def theirs
  # lacks is a clash.
  defp new_spans(letters, defs, theirs) do
    used = MapSet.new(theirs["children"], & &1["_key"])

    letters
    |> Enum.chunk_by(fn {{_g, tag}, _key} -> tag end)
    |> Enum.reduce_while({[], used}, fn [{{_, {named, extra} = tag}, key} | _] = run,
                                        {acc, used} ->
      marks =
        Enum.map(named, fn
          {:dec, m} -> m
          {:def, d} -> defs[d]
        end)

      key =
        if is_binary(key) and not MapSet.member?(used, key),
          do: key,
          else: fresh(theirs["_key"], used, 0)

      text = Enum.map_join(run, fn {{g, _}, _} -> g end)

      span =
        Map.merge(extra, %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks})

      if Enum.all?(marks, &is_binary/1),
        do: {:cont, {[{tag, span} | acc], MapSet.put(used, key)}},
        else: {:halt, :error}
    end)
    |> case do
      {spans, _used} -> {:ok, Enum.reverse(spans)}
      :error -> :error
    end
  end

  defp fresh(k, used, n) do
    key = "#{k}i#{n}"
    if MapSet.member?(used, key), do: fresh(k, used, n + 1), else: key
  end

  # Theirs' spans with letters [a, b) replaced by `new`: a span left or right
  # of the cut is kept as it is; the first and last it reaches keep their
  # maps with their text cut, and a cut inside one span with letters in its
  # own marks stays that span. A new run with the marks of the span beside
  # it joins that span.
  defp cut(theirs, a, b, new) do
    defs = defs(theirs)
    tag = &tag(&1, defs)

    {spans, _} =
      Enum.map_reduce(theirs["children"], 0, fn s, o ->
        n = glen(s)
        {{s, o, n}, o + n}
      end)

    {left, rest} = Enum.split_with(spans, fn {_s, o, n} -> o + n <= a end)
    {mid, right} = Enum.split_with(rest, fn {_s, o, _n} -> o < b end)
    {left, right} = {Enum.map(left, &elem(&1, 0)), Enum.map(right, &elem(&1, 0))}

    case mid do
      [] ->
        join(left, new, right, tag)

      [{f, fo, _} | _] ->
        {l, lo, _} = List.last(mid)
        {lt, rt} = {take(f, a - fo), drop(l, b - lo)}
        news = Enum.map(new, &elem(&1, 1))

        if f == l and Enum.all?(new, fn {t, _} -> t == tag.(f) end) do
          left ++ piece(f, lt <> Enum.map_join(news, & &1["text"]) <> rt) ++ right
        else
          # The right piece of a span split in two takes a key of its own.
          l =
            if f == l and lt != "",
              do: Map.put(l, "_key", fresh(theirs["_key"], used(theirs, news), 0)),
              else: l

          join(left ++ piece(f, lt), new, piece(l, rt) ++ right, tag)
        end
    end
  end

  # New runs between two lists of spans: the first joins the span before
  # it, the last the span after it, when their marks are equal.
  defp join(left, new, right, tag) do
    {left, new} =
      case {List.last(left), new} do
        {%{} = s, [{t, n} | rest]} ->
          if tag.(s) == t,
            do: {Enum.drop(left, -1) ++ [glue(s, "", n["text"])], rest},
            else: {left, new}

        _ ->
          {left, new}
      end

    {new, right} =
      case {List.last(new), right} do
        {{t, n}, [s | rest]} ->
          if tag.(s) == t,
            do: {Enum.drop(new, -1), [glue(s, n["text"], "") | rest]},
            else: {new, right}

        _ ->
          {new, right}
      end

    left ++ Enum.map(new, &elem(&1, 1)) ++ right
  end

  defp used(theirs, news), do: MapSet.new(theirs["children"] ++ news, & &1["_key"])
  defp put(s, text), do: Map.put(s, "text", text)
  defp piece(_s, ""), do: []
  defp piece(s, text), do: [put(s, text)]

  defp glue(span, before, after_), do: Map.put(span, "text", before <> span["text"] <> after_)
  defp take(s, n), do: s |> text() |> String.graphemes() |> Enum.take(max(n, 0)) |> Enum.join()
  defp drop(s, n), do: s |> text() |> String.graphemes() |> Enum.drop(max(n, 0)) |> Enum.join()

  @doc false
  # The count bound is defence in depth: with the snap, every word of the
  # result is a word of a side's own text over the place it changed, so
  # the count is mine + theirs - base exactly (#28761 review, check 5).
  # Tested directly for that reason.
  def guard?(block, base, mine, theirs) do
    texts = Enum.map(block["children"], &text/1)
    joined = Enum.join(texts)

    [w, wb, wm, wt] =
      Enum.map(
        [joined, all(base), all(mine), all(theirs)],
        &(&1 |> words() |> Enum.frequencies())
      )

    String.graphemes(joined) == Enum.flat_map(texts, &String.graphemes/1) and
      Enum.all?(w, fn {x, k} ->
        (is_map_key(wb, x) or is_map_key(wm, x) or is_map_key(wt, x)) and
          k <= Map.get(wm, x, 0) + Map.get(wt, x, 0) - Map.get(wb, x, 0)
      end)
  end

  defp all(block), do: Enum.map_join(block["children"], &text/1)

  # Maximal runs of word letters, on graphemes as `word?/2` reads them.
  defp words(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_by(&letter?/1)
    |> Enum.filter(&letter?(hd(&1)))
    |> Enum.map(&Enum.join/1)
  end

  defp text(%{"text" => t}) when is_binary(t), do: t
  defp text(_child), do: ""
  defp glen(child), do: child |> text() |> String.graphemes() |> length()
end
