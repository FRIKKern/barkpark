defmodule Barkpark.Content.DiffMatchPatch.Make do
  @moduledoc """
  @sanity/diff-match-patch 3.2's `makePatches(a, b)` and `stringifyPatches`:
  the patch text that turns `a` into `b`, as the browser makes it. A
  translation step for step (`diff`, then `cleanupSemantic` and
  `cleanupEfficiency` when the diff has over two parts, then the hunks with
  a context margin of 4 grown until it is unique), on lists of UTF-16 code
  units. One difference: the diff runs without the library's line mode
  (`checkLines`), which changes only how a diff of texts over 100 units is
  found, not which edit it describes.

  `Barkpark.Content.DiffMatchPatch.apply/2` applies the text, so the pair is
  TanStack's `applyPatches(makePatches(base, mine), theirs)` (merge.ts
  `merge3`, task-881f16e32fffbe9a).
  """

  alias Barkpark.Content.DiffMatchPatch.Diff

  @margin 4
  @max_bits 32
  @edit_cost 4
  # What `encodeURI` leaves as it is besides the unreserved characters (the
  # space is the library's own `%20` → " ").
  @uri_kept ~c" ;,/?:@&=+$!*'()#"

  @doc "The patch text that turns `a` into `b` (both UTF-16 unit lists)."
  @spec text([non_neg_integer()], [non_neg_integer()]) :: String.t()
  def text(a, b) do
    diffs = Diff.diff(a, b)

    diffs =
      if length(diffs) > 2,
        do: diffs |> cleanup_semantic() |> cleanup_efficiency(),
        else: diffs

    a |> make(diffs) |> Enum.map_join(&stringify/1) |> String.replace("%20", " ")
  end

  # ── cleanupSemantic ──────────────────────────────────────────────────────

  defp cleanup_semantic(diffs) do
    {diffs, changed?} = eliminate(diffs, 0, [], nil, {0, 0, 0, 0}, false)
    diffs = if changed?, do: Diff.cleanup_merge(diffs), else: diffs
    diffs |> Diff.semantic_lossless() |> overlaps(1)
  end

  defp eliminate(diffs, p, _eqs, _last, _lens, changed?) when p >= length(diffs),
    do: {diffs, changed?}

  defp eliminate(diffs, p, eqs, last, {li1, ld1, li2, ld2}, changed?) do
    case Enum.at(diffs, p) do
      {:equal, text} ->
        eliminate(diffs, p + 1, [p | eqs], text, {li2, ld2, 0, 0}, changed?)

      {op, text} ->
        {li2, ld2} =
          if op == :insert, do: {li2 + length(text), ld2}, else: {li2, ld2 + length(text)}

        if last not in [nil, []] and length(last) <= max(li1, ld1) and
             length(last) <= max(li2, ld2) do
          [top | eqs] = eqs
          diffs = diffs |> List.insert_at(top, {:delete, last}) |> retag(top + 1, :insert)
          eqs = Enum.drop(eqs, 1)
          p = if eqs == [], do: -1, else: hd(eqs)
          eliminate(diffs, p + 1, eqs, nil, {0, 0, 0, 0}, true)
        else
          eliminate(diffs, p + 1, eqs, last, {li1, ld1, li2, ld2}, changed?)
        end
    end
  end

  defp overlaps(diffs, p) when p >= length(diffs), do: diffs

  defp overlaps(diffs, p) do
    case {Enum.at(diffs, p - 1), Enum.at(diffs, p)} do
      {{:delete, del}, {:insert, ins}} ->
        o1 = overlap(del, ins)
        o2 = overlap(ins, del)
        {dl, il} = {length(del), length(ins)}

        cond do
          o1 >= o2 and (o1 >= dl / 2 or o1 >= il / 2) ->
            diffs
            |> List.replace_at(p - 1, {:delete, Enum.take(del, dl - o1)})
            |> List.replace_at(p, {:insert, Enum.drop(ins, o1)})
            |> List.insert_at(p, {:equal, Enum.take(ins, o1)})
            |> overlaps(p + 3)

          o1 < o2 and (o2 >= dl / 2 or o2 >= il / 2) ->
            diffs
            |> List.replace_at(p - 1, {:insert, Enum.take(ins, il - o2)})
            |> List.replace_at(p, {:delete, Enum.drop(del, o2)})
            |> List.insert_at(p, {:equal, Enum.take(del, o2)})
            |> overlaps(p + 3)

          true ->
            overlaps(diffs, p + 2)
        end

      _ ->
        overlaps(diffs, p + 1)
    end
  end

  # `getCommonOverlap`: how much of the end of `a` starts `b`.
  defp overlap(a, b) when a == [] or b == [], do: 0

  defp overlap(a, b) do
    {la, lb} = {length(a), length(b)}
    a = if la > lb, do: Enum.drop(a, la - lb), else: a
    b = if la < lb, do: Enum.take(b, la), else: b
    n = min(la, lb)
    if a == b, do: n, else: overlap_walk(a, b, n, 0, 1)
  end

  defp overlap_walk(a, b, n, best, len) do
    case Diff.index_of(b, Enum.drop(a, max(n - len, 0)), 0) do
      -1 ->
        best

      found ->
        len = len + found

        if found == 0 or Enum.drop(a, max(n - len, 0)) == Enum.take(b, len),
          do: overlap_walk(a, b, n, len, len + 1),
          else: overlap_walk(a, b, n, best, len)
    end
  end

  # ── cleanupEfficiency ────────────────────────────────────────────────────

  defp cleanup_efficiency(diffs) do
    {diffs, changed?} = efficiency(diffs, 0, [], nil, {false, false, false, false}, false)
    if changed?, do: Diff.cleanup_merge(diffs), else: diffs
  end

  defp efficiency(diffs, p, _eqs, _last, _flags, changed?) when p >= length(diffs),
    do: {diffs, changed?}

  defp efficiency(diffs, p, eqs, last, {pre_i, pre_d, post_i, post_d}, changed?) do
    case Enum.at(diffs, p) do
      {:equal, text} ->
        if length(text) < @edit_cost and (post_i or post_d),
          do: efficiency(diffs, p + 1, [p | eqs], text, {post_i, post_d, false, false}, changed?),
          else: efficiency(diffs, p + 1, [], nil, {pre_i, pre_d, false, false}, changed?)

      {op, _text} ->
        {post_i, post_d} = if op == :delete, do: {post_i, true}, else: {true, post_d}
        count = Enum.count([pre_i, pre_d, post_i, post_d], & &1)

        if last not in [nil, []] and
             ((pre_i and pre_d and post_i and post_d) or
                (length(last) < @edit_cost / 2 and count == 3)) do
          [top | eqs] = eqs
          diffs = diffs |> List.insert_at(top, {:delete, last}) |> retag(top + 1, :insert)

          if pre_i and pre_d do
            efficiency(diffs, p + 1, [], nil, {pre_i, pre_d, true, true}, true)
          else
            eqs = Enum.drop(eqs, 1)
            p = if eqs == [], do: -1, else: hd(eqs)
            efficiency(diffs, p + 1, eqs, nil, {pre_i, pre_d, false, false}, true)
          end
        else
          efficiency(diffs, p + 1, eqs, last, {pre_i, pre_d, post_i, post_d}, changed?)
        end
    end
  end

  defp retag(diffs, at, op), do: List.update_at(diffs, at, fn {_, text} -> {op, text} end)

  # ── _makePatches ─────────────────────────────────────────────────────────

  defp make(_a, []), do: []

  defp make(a, diffs) do
    state = %{
      patch: new_patch(0, 0),
      n: 0,
      c1: 0,
      c2: 0,
      b1: 0,
      b2: 0,
      pre: a,
      post: a,
      out: []
    }

    last = length(diffs) - 1

    state =
      diffs
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{op, text} = diff, x}, s ->
        {len, bytes} = {length(text), utf8_bytes(text)}

        s =
          if s.n == 0 and op != :equal,
            do: %{
              s
              | patch: %{s.patch | start1: s.c1, start2: s.c2, b_start1: s.b1, b_start2: s.b2}
            },
            else: s

        s =
          case op do
            :insert ->
              p = s.patch

              %{
                s
                | patch: %{
                    p
                    | diffs: p.diffs ++ [diff],
                      length2: p.length2 + len,
                      b_length2: p.b_length2 + bytes
                  },
                  n: s.n + 1,
                  post: Enum.take(s.post, s.c2) ++ text ++ Enum.drop(s.post, s.c2)
              }

            :delete ->
              p = s.patch

              %{
                s
                | patch: %{
                    p
                    | diffs: p.diffs ++ [diff],
                      length1: p.length1 + len,
                      b_length1: p.b_length1 + bytes
                  },
                  n: s.n + 1,
                  post: Enum.take(s.post, s.c2) ++ Enum.drop(s.post, s.c2 + len)
              }

            :equal ->
              cond do
                len <= 2 * @margin and s.n > 0 and x != last ->
                  p = s.patch

                  %{
                    s
                    | patch: %{
                        p
                        | diffs: p.diffs ++ [diff],
                          length1: p.length1 + len,
                          length2: p.length2 + len,
                          b_length1: p.b_length1 + bytes,
                          b_length2: p.b_length2 + bytes
                      },
                      n: s.n + 1
                  }

                len >= 2 * @margin and s.n > 0 ->
                  %{
                    s
                    | out: [add_context(s.patch, s.pre) | s.out],
                      patch: new_patch(-1, -1),
                      n: 0,
                      pre: s.post,
                      c1: s.c2,
                      b1: s.b2
                  }

                true ->
                  s
              end
          end

        {c1, b1} = if op != :insert, do: {s.c1 + len, s.b1 + bytes}, else: {s.c1, s.b1}
        {c2, b2} = if op != :delete, do: {s.c2 + len, s.b2 + bytes}, else: {s.c2, s.b2}
        %{s | c1: c1, b1: b1, c2: c2, b2: b2}
      end)

    out = if state.n > 0, do: [add_context(state.patch, state.pre) | state.out], else: state.out
    Enum.reverse(out)
  end

  defp new_patch(s1, s2),
    do: %{
      diffs: [],
      start1: s1,
      start2: s2,
      b_start1: s1,
      b_start2: s2,
      length1: 0,
      length2: 0,
      b_length1: 0,
      b_length2: 0
    }

  defp add_context(patch, []), do: patch

  defp add_context(patch, text) do
    tlen = length(text)
    pad = grow(text, patch.start2, patch.length1, 0)
    pad = pad + @margin

    prefix_start = patch.start2 - pad

    prefix_start =
      if prefix_start >= 1 and low?(Enum.at(text, prefix_start)),
        do: prefix_start - 1,
        else: prefix_start

    prefix = slice(text, prefix_start, patch.start2)

    suffix_end = patch.start2 + patch.length1 + pad

    suffix_end =
      if suffix_end < tlen and low?(Enum.at(text, suffix_end)),
        do: suffix_end + 1,
        else: suffix_end

    suffix = slice(text, patch.start2 + patch.length1, suffix_end)

    diffs = if prefix == [], do: patch.diffs, else: [{:equal, prefix} | patch.diffs]
    diffs = if suffix == [], do: diffs, else: diffs ++ [{:equal, suffix}]
    {pl, pb, sl, sb} = {length(prefix), utf8_bytes(prefix), length(suffix), utf8_bytes(suffix)}

    %{
      patch
      | diffs: diffs,
        start1: patch.start1 - pl,
        start2: patch.start2 - pl,
        b_start1: patch.b_start1 - pb,
        b_start2: patch.b_start2 - pb,
        length1: patch.length1 + pl + sl,
        length2: patch.length2 + pl + sl,
        b_length1: patch.b_length1 + pb + sb,
        b_length2: patch.b_length2 + pb + sb
    }
  end

  # The padding that makes the hunk's text unique in `text` (the library
  # grows it by the margin while the pattern is under 32 - 2 * margin).
  defp grow(text, start, len, pad) do
    pattern = slice(text, start - pad, start + len + pad)

    if not unique?(text, pattern) and length(pattern) < @max_bits - 2 * @margin,
      do: grow(text, start, len, pad + @margin),
      else: pad
  end

  defp unique?(text, []), do: text == []

  defp unique?(text, pattern) do
    case Diff.index_of(text, pattern, 0) do
      -1 -> true
      first -> Diff.index_of(text, pattern, first + 1) == -1
    end
  end

  # JavaScript's `substring`: bounds clamped to the text, swapped when reversed.
  defp slice(list, from, to) do
    n = length(list)
    {from, to} = {min(max(from, 0), n), min(max(to, 0), n)}
    {from, to} = if from > to, do: {to, from}, else: {from, to}
    list |> Enum.drop(from) |> Enum.take(to - from)
  end

  defp low?(nil), do: false
  defp low?(unit), do: unit in 0xDC00..0xDFFF

  # ── stringifyPatch ───────────────────────────────────────────────────────

  defp stringify(p) do
    "@@ -#{coords(p.b_start1, p.b_length1)} +#{coords(p.b_start2, p.b_length2)} @@\n" <>
      Enum.map_join(p.diffs, fn {op, units} -> sign(op) <> encode(units) <> "\n" end)
  end

  defp coords(start, 0), do: "#{start},0"
  defp coords(start, 1), do: "#{start + 1}"
  defp coords(start, len), do: "#{start + 1},#{len}"

  defp sign(:insert), do: "+"
  defp sign(:delete), do: "-"
  defp sign(:equal), do: " "

  # `encodeURI`, as far as `DiffMatchPatch`'s `URI.decode` reads it back.
  defp encode(units) do
    bin = for u <- units, into: <<>>, do: <<u::16>>

    case :unicode.characters_to_binary(bin, {:utf16, :big}, :utf8) do
      s when is_binary(s) -> URI.encode(s, &(URI.char_unreserved?(&1) or &1 in @uri_kept))
      _ -> ""
    end
  end

  # `countUtf8Bytes`: a surrogate pair is one 4-byte character.
  defp utf8_bytes(units), do: utf8_bytes(units, 0)
  defp utf8_bytes([], n), do: n

  defp utf8_bytes([hi, lo | rest], n) when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF,
    do: utf8_bytes(rest, n + 4)

  defp utf8_bytes([u | rest], n) when u < 0x80, do: utf8_bytes(rest, n + 1)
  defp utf8_bytes([u | rest], n) when u < 0x800, do: utf8_bytes(rest, n + 2)
  defp utf8_bytes([_ | rest], n), do: utf8_bytes(rest, n + 3)
end
