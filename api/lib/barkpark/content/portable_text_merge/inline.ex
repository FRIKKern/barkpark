defmodule Barkpark.Content.PortableTextMerge.Inline do
  @moduledoc """
  The merge inside one block (task-266ffbe9cd115f3c, task-da701626f5be2143,
  plan /papers/pt-merge-inside-one-block rev 4, part 2): a text block both
  sides changed, each in a gap of one block for one, merges when each side
  changed its text in one place and the places are apart. Called only from
  `PortableTextMerge`'s `pick/4`.

    * Letters: one grapheme each, tagged with its span's marks (a decorator
      by name, an annotation by its def without `_key`) and its other span
      fields. A child that is not a span, or a block field any side changed,
      is a clash.
    * One splice per side, as `TextRebase` reads a text: the common prefix
      and suffix of the base's letters and the side's, and the middle of the
      base replaced by the side's. A letter is its grapheme and its marks,
      so a mark put on or taken off, or a link's def changed, is part of
      the splice (task-07d2ca9aa7667208): a bold on "one" merges with an
      edit of "three"; a bold across the other side's edit clashes.
    * Apart: each splice widened to whole words (a run of graphemes with no
      space and no CJK punctuation between them: "example.com", "a/b",
      "x-1", "3.14", "don't" and a space-less Han and kana run are each one
      word, "two。かな" two) leaves at least one base letter between them. Two edits in one word, touching ranges and two
      inserts at one point are a clash: "cart" to "carts" and "dart" would
      give "darts".
    * Built from theirs, as the store holds it: only mine's splice is
      replaced, so every span outside it is theirs' map byte for byte.
      Letters put in join the span they touch when the marks are equal,
      else a new span with mine's span key or, when theirs has it, a fresh
      one unique in the block (a span's key is read only under its block).
    * Defs: theirs' stay, used or not. A link of mine's letters is theirs'
      def with that content, else mine's def added under mine's key (a
      fresh one when theirs holds it); two of mine's links with one content
      stay two. A def of theirs goes only when its last use was in the text
      mine's splice replaced.
    * A guard on the result: each word is a word of base, mine or theirs,
      at most count(mine) + count(theirs) - count(base) times, and the text
      splits into the graphemes it was built from (no flag made at a join).
      Otherwise a clash. The snap and the guard read words alike, so each
      alone refuses a word made of two edits; the count bound is defence
      in depth behind the snap. One edit both sides made is theirs, a
      side's own text, and is not guarded.

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
         # One edit both made: theirs, a side's own text (task-3d00496b0292f20b).
         true <- ms == ts or guard?(block, base, mine, theirs) do
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

  # {from, to, letters}: the side's middle in place of base[from, to), on
  # letters. A mark changed on text that did not lies inside it, where
  # `marks_kept?/2` reads it; ends taken on graphemes as well refused a bold
  # word deleted before a word that starts alike (task-3d00496b0292f20b).
  defp splice(base, side) do
    {p, s} = ends(base, side)
    splice(base, side, p, s)
  end

  # A letter is its grapheme and its marks, so a mark put on, taken off or
  # a link's def changed is part of the side's splice (task-07d2ca9aa7667208).
  # A splice of no letters (spans cut another way, nothing drawn changed):
  # :error, as before.
  defp splice(base, side, p, s) do
    {mid, put} =
      {Enum.slice(base, p, length(base) - s - p), Enum.slice(side, p, length(side) - s - p)}

    if mid == put, do: :error, else: {:ok, {p, length(base) - s, put}}
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
  # One byte: read from a table made of `@apart` itself, so the two agree;
  # a regex per grapheme cost a capped block's guard 3x (task-da701626).
  @ascii_apart for c <- 0..127, Regex.match?(@apart, <<c>>), do: c
  defp letter?(<<c>>) when c < 128, do: c not in @ascii_apart
  defp letter?(g), do: not Regex.match?(@apart, g)

  # Theirs with mine's splice put in (moved by theirs' when theirs' is first).
  defp build(same, same, _mine, theirs), do: {:ok, theirs}

  defp build({mp, me, put}, {tp, te, tput}, mine, theirs) do
    shift = if tp < mp, do: length(tput) - (te - tp), else: 0
    {a, b} = {mp + shift, me + shift}

    spans =
      mine["children"]
      |> Enum.flat_map(&List.duplicate(&1, glen(&1)))
      |> Enum.slice(mp, length(put))

    {new, added} = new_spans(Enum.zip(put, spans), defs(mine), theirs)
    children = cut(theirs, a, b, new)

    block = Map.put(theirs, "children", children)

    if added == [] and not is_map_key(theirs, "markDefs"),
      do: {:ok, block},
      else: {:ok, Map.put(block, "markDefs", mark_defs(theirs, added, children))}
  end

  # Mine's letters as spans in theirs' marks ({look, span}). A link is read
  # by its def: theirs' def with that content, else mine's added under
  # mine's key (a fresh one when theirs holds it). Two of mine's links with
  # one content stay two (`marks/4`).
  #
  # The state carries the fresh-key counters (`ns`, `nd`) and the keys
  # taken so far (`took`), so each run costs the same however many came
  # before (#28802 review: mine and theirs share base's span keys, and a
  # walk from 0 per run grew with the square of the runs).
  defp new_spans(letters, mdefs, theirs) do
    used = MapSet.new(theirs["children"] ++ List.wrap(theirs["markDefs"]), & &1["_key"])

    tdefs =
      defs(theirs) |> Enum.sort() |> Enum.reduce(%{}, fn {k, d}, m -> Map.put_new(m, d, k) end)

    st = %{used: used, taken: %{}, took: MapSet.new(), added: [], ns: 0, nd: 0}

    {spans, %{added: added}} =
      letters
      |> Enum.chunk_by(fn {{_g, tag}, ms} -> {tag, link_keys(ms, mdefs)} end)
      |> Enum.map_reduce(st, fn [{{_, {_named, extra}}, ms} | _] = run, st ->
        {marks, st} = marks(ms, mdefs, tdefs, theirs["_key"], st)

        {key, st} =
          if is_binary(ms["_key"]) and not MapSet.member?(st.used, ms["_key"]) do
            {ms["_key"], st}
          else
            {key, n} = fresh(theirs["_key"], st.used, st.ns)
            {key, %{st | ns: n}}
          end

        text = Enum.map_join(run, fn {{g, _}, _} -> g end)

        span =
          Map.merge(extra, %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks})

        {{look(span), span}, %{st | used: MapSet.put(st.used, key)}}
      end)

    {spans, Enum.reverse(added)}
  end

  defp link_keys(span, mdefs), do: Enum.filter(List.wrap(span["marks"]), &is_map_key(mdefs, &1))

  # Each of mine's marks as theirs' mark key. `taken`: mine's link key => the
  # key it took (`took`, the keys taken), so one link of mine stays one, and
  # a second link of mine with the same content takes a def of its own. A
  # def key mine holds for another link of its own with that content is not
  # taken by content either: mine's link outside the splice keeps that key,
  # and the two would become one. Mine holding it for a link of another
  # content (mine re-keyed its defs) does not refuse it: one link of mine
  # would come out as two (task-336c3a9b3baa9d0e).
  defp marks(span, mdefs, tdefs, bkey, st) do
    span["marks"]
    |> List.wrap()
    |> Enum.map_reduce(st, fn mk, st ->
      k = is_map_key(mdefs, mk) && tdefs[mdefs[mk]]

      cond do
        not is_map_key(mdefs, mk) ->
          {mk, st}

        is_map_key(st.taken, mk) ->
          {st.taken[mk], st}

        k && not MapSet.member?(st.took, k) && (k == mk or mdefs[k] != mdefs[mk]) ->
          {k, %{st | taken: Map.put(st.taken, mk, k), took: MapSet.put(st.took, k)}}

        true ->
          {k, st} =
            if MapSet.member?(st.used, mk) do
              {k, n} = fresh(bkey <> "d", st.used, st.nd)
              {k, %{st | nd: n}}
            else
              {mk, st}
            end

          {k,
           %{
             st
             | used: MapSet.put(st.used, k),
               taken: Map.put(st.taken, mk, k),
               took: MapSet.put(st.took, k),
               added: [Map.put(mdefs[mk], "_key", k) | st.added]
           }}
      end
    end)
  end

  # Theirs' defs stay, used or not, with mine's added; a def is dropped
  # only when its last use was in theirs' text mine's splice replaced.
  defp mark_defs(theirs, added, children) do
    before = used_marks(theirs["children"])
    now = used_marks(children)

    for(
      %{"_key" => k} = d <- List.wrap(theirs["markDefs"]),
      not (MapSet.member?(before, k) and not MapSet.member?(now, k)),
      do: d
    ) ++ added
  end

  defp used_marks(children),
    do: MapSet.new(Enum.flat_map(children, &List.wrap(&1["marks"])))

  # What a span draws besides its text: its marks, as keys, and its fields.
  defp look(span),
    do: {Enum.sort(List.wrap(span["marks"])), Map.drop(span, ~w(_key _type text marks))}

  # The first free `<k>i<n>` from `n` on, and the counter to start from next.
  defp fresh(k, used, n) do
    key = "#{k}i#{n}"
    if MapSet.member?(used, key), do: fresh(k, used, n + 1), else: {key, n + 1}
  end

  # Theirs' spans with letters [a, b) replaced by `new`: a span left or right
  # of the cut is kept as it is; the first and last it reaches keep their
  # maps with their text cut, and a cut inside one span with letters in its
  # own marks stays that span. A new run with the marks of the span beside
  # it joins that span.
  defp cut(theirs, a, b, new) do
    tag = &look/1

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
              do: Map.put(l, "_key", elem(fresh(theirs["_key"], used(theirs, news), 0), 0)),
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

  # Maximal runs of word letters, on graphemes as `word?/2` reads them. An
  # ASCII text splits on the same bytes natively: each of its graphemes is
  # one byte but "\r\n", and both of those part words.
  @ascii_seps Enum.map(@ascii_apart, &<<&1>>)
  defp words(text) do
    if Regex.match?(~r/[^\x00-\x7F]/, text),
      do: grapheme_words(text),
      else: :binary.split(text, @ascii_seps, [:global, :trim_all])
  end

  defp grapheme_words(text) do
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
