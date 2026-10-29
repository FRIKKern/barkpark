defmodule Barkpark.Content.DiffMatchPatch.Diff do
  @moduledoc """
  The diff `Barkpark.Content.DiffMatchPatch` maps a fuzzy-placed hunk through:
  @sanity/diff-match-patch 3.2's `diff` (common prefix and suffix, half match,
  Myers bisection, `cleanupMerge`, the surrogate-pair adjustment) and
  `cleanupSemanticLossless`, on lists of UTF-16 code units. A translation of
  that code, step for step, so an edit lands where Sanity lands it. The
  library's one-second deadline is left out: the inputs here are at most a
  few dozen units.
  """

  @type op :: :equal | :insert | :delete
  @type diff :: {op, [non_neg_integer()]}

  @doc "`diff(text1, text2, {checkLines: false})`."
  @spec diff([non_neg_integer()], [non_neg_integer()]) :: [diff]
  def diff(text1, text2), do: text1 |> do_diff(text2) |> adjust_surrogates()

  # ── doDiff / computeDiff ─────────────────────────────────────────────────

  defp do_diff(t1, t2) when t1 == t2, do: if(t1 == [], do: [], else: [{:equal, t1}])

  defp do_diff(t1, t2) do
    p = common_prefix(t1, t2)
    {prefix, t1, t2} = {Enum.take(t1, p), Enum.drop(t1, p), Enum.drop(t2, p)}
    s = common_suffix(t1, t2)
    suffix = Enum.drop(t1, length(t1) - s)
    t1 = Enum.take(t1, length(t1) - s)
    t2 = Enum.take(t2, length(t2) - s)

    diffs = compute(t1, t2)
    diffs = if prefix != [], do: [{:equal, prefix} | diffs], else: diffs
    diffs = if suffix != [], do: diffs ++ [{:equal, suffix}], else: diffs
    cleanup_merge(diffs)
  end

  defp compute([], t2), do: [{:insert, t2}]
  defp compute(t1, []), do: [{:delete, t1}]

  defp compute(t1, t2) do
    {long, short} = if length(t1) > length(t2), do: {t1, t2}, else: {t2, t1}

    case index_of(long, short, 0) do
      -1 ->
        cond do
          length(short) == 1 ->
            [{:delete, t1}, {:insert, t2}]

          hm = half_match(t1, t2) ->
            {t1a, t1b, t2a, t2b, mid} = hm
            do_diff(t1a, t2a) ++ [{:equal, mid}] ++ do_diff(t1b, t2b)

          true ->
            bisect(t1, t2)
        end

      i ->
        op = if length(t1) > length(t2), do: :delete, else: :insert

        [
          {op, Enum.take(long, i)},
          {:equal, short},
          {op, Enum.drop(long, i + length(short))}
        ]
    end
  end

  # ── half match ───────────────────────────────────────────────────────────

  defp half_match(t1, t2) do
    {long, short} = if length(t1) > length(t2), do: {t1, t2}, else: {t2, t1}
    ll = length(long)

    if ll < 4 or length(short) * 2 < ll do
      nil
    else
      hm1 = half_match_i(long, short, ceil_div(ll, 4))
      hm2 = half_match_i(long, short, ceil_div(ll, 2))

      hm =
        cond do
          hm1 && hm2 -> if length(elem(hm1, 4)) > length(elem(hm2, 4)), do: hm1, else: hm2
          hm1 -> hm1
          hm2 -> hm2
          true -> nil
        end

      case hm do
        nil ->
          nil

        {la, lb, sa, sb, mid} ->
          if length(t1) > length(t2), do: {la, lb, sa, sb, mid}, else: {sa, sb, la, lb, mid}
      end
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp half_match_i(long, short, i) do
    ll = length(long)
    seed = long |> Enum.drop(i) |> Enum.take(div(ll, 4))
    best = half_match_scan(long, short, i, seed, -1, {[], [], [], [], []})
    {_, _, _, _, common} = best
    if length(common) * 2 >= ll, do: best, else: nil
  end

  defp half_match_scan(long, short, i, seed, j, best) do
    case index_of(short, seed, j + 1) do
      -1 ->
        best

      j ->
        prefix = common_prefix(Enum.drop(long, i), Enum.drop(short, j))
        suffix = common_suffix(Enum.take(long, i), Enum.take(short, j))
        {_, _, _, _, common} = best

        best =
          if length(common) < suffix + prefix do
            {Enum.take(long, i - suffix), Enum.drop(long, i + prefix),
             Enum.take(short, j - suffix), Enum.drop(short, j + prefix),
             slice(short, j - suffix, j) ++ slice(short, j, j + prefix)}
          else
            best
          end

        half_match_scan(long, short, i, seed, j, best)
    end
  end

  # ── bisect ───────────────────────────────────────────────────────────────

  defp bisect(t1, t2) do
    a = List.to_tuple(t1)
    b = List.to_tuple(t2)
    n = tuple_size(a)
    m = tuple_size(b)
    max_d = ceil_div(n + m, 2)
    off = max_d
    vlen = 2 * max_d
    delta = n - m

    s = %{
      a: a,
      b: b,
      n: n,
      m: m,
      off: off,
      vlen: vlen,
      delta: delta,
      front: rem(delta, 2) != 0,
      v1: %{(off + 1) => 0},
      v2: %{(off + 1) => 0},
      k1start: 0,
      k1end: 0,
      k2start: 0,
      k2end: 0
    }

    case bisect_d(0, max_d, s) do
      {:split, x, y} -> bisect_split(t1, t2, x, y)
      :none -> [{:delete, t1}, {:insert, t2}]
    end
  end

  # JS arrays: -1 where initialised, `undefined` past the end, unless written.
  defp v(map, s, i) do
    case Map.fetch(map, i) do
      {:ok, x} -> x
      :error -> if i >= 0 and i < s.vlen, do: -1, else: :undef
    end
  end

  defp lt(:undef, _), do: false
  defp lt(_, :undef), do: false
  defp lt(a, b), do: a < b

  defp bisect_d(d, max_d, _s) when d >= max_d, do: :none

  defp bisect_d(d, max_d, s) do
    case k1_loop(-d + s.k1start, d, s) do
      {:split, _, _} = hit ->
        hit

      s ->
        case k2_loop(-d + s.k2start, d, s) do
          {:split, _, _} = hit -> hit
          s -> bisect_d(d + 1, max_d, s)
        end
    end
  end

  defp k1_loop(k1, d, s) when k1 > d - s.k1end, do: s

  defp k1_loop(k1, d, s) do
    ko = s.off + k1

    x1 =
      if k1 == -d or (k1 != d and lt(v(s.v1, s, ko - 1), v(s.v1, s, ko + 1))),
        do: v(s.v1, s, ko + 1),
        else: v(s.v1, s, ko - 1) + 1

    {x1, y1} = snake_forward(s, x1, x1 - k1)
    s = %{s | v1: Map.put(s.v1, ko, x1)}

    cond do
      x1 > s.n ->
        k1_loop(k1 + 2, d, %{s | k1end: s.k1end + 2})

      y1 > s.m ->
        k1_loop(k1 + 2, d, %{s | k1start: s.k1start + 2})

      s.front ->
        k2o = s.off + s.delta - k1

        if k2o >= 0 and k2o < s.vlen and v(s.v2, s, k2o) != -1 and x1 >= s.n - v(s.v2, s, k2o),
          do: {:split, x1, y1},
          else: k1_loop(k1 + 2, d, s)

      true ->
        k1_loop(k1 + 2, d, s)
    end
  end

  defp k2_loop(k2, d, s) when k2 > d - s.k2end, do: s

  defp k2_loop(k2, d, s) do
    ko = s.off + k2

    x2 =
      if k2 == -d or (k2 != d and lt(v(s.v2, s, ko - 1), v(s.v2, s, ko + 1))),
        do: v(s.v2, s, ko + 1),
        else: v(s.v2, s, ko - 1) + 1

    {x2, y2} = snake_backward(s, x2, x2 - k2)
    s = %{s | v2: Map.put(s.v2, ko, x2)}

    cond do
      x2 > s.n ->
        k2_loop(k2 + 2, d, %{s | k2end: s.k2end + 2})

      y2 > s.m ->
        k2_loop(k2 + 2, d, %{s | k2start: s.k2start + 2})

      not s.front ->
        k1o = s.off + s.delta - k2

        if k1o >= 0 and k1o < s.vlen and v(s.v1, s, k1o) != -1 do
          x1 = v(s.v1, s, k1o)
          y1 = s.off + x1 - k1o

          if x1 >= s.n - x2, do: {:split, x1, y1}, else: k2_loop(k2 + 2, d, s)
        else
          k2_loop(k2 + 2, d, s)
        end

      true ->
        k2_loop(k2 + 2, d, s)
    end
  end

  defp snake_forward(s, x, y) do
    if x < s.n and y < s.m and elem(s.a, x) == elem(s.b, y),
      do: snake_forward(s, x + 1, y + 1),
      else: {x, y}
  end

  defp snake_backward(s, x, y) do
    if x < s.n and y < s.m and elem(s.a, s.n - x - 1) == elem(s.b, s.m - y - 1),
      do: snake_backward(s, x + 1, y + 1),
      else: {x, y}
  end

  defp bisect_split(t1, t2, x, y) do
    do_diff(Enum.take(t1, x), Enum.take(t2, y)) ++ do_diff(Enum.drop(t1, x), Enum.drop(t2, y))
  end

  # ── cleanupMerge ─────────────────────────────────────────────────────────

  @doc false
  def cleanup_merge(diffs) do
    diffs = merge_pass(diffs ++ [{:equal, []}], 0, 0, 0, [], [])

    diffs =
      case List.last(diffs) do
        {_, []} -> List.delete_at(diffs, -1)
        _ -> diffs
      end

    case shift_pass(diffs, 1, false) do
      {diffs, true} -> cleanup_merge(diffs)
      {diffs, false} -> diffs
    end
  end

  defp merge_pass(diffs, p, _cd, _ci, _td, _ti) when p >= length(diffs), do: diffs

  defp merge_pass(diffs, p, cd, ci, td, ti) do
    case Enum.at(diffs, p) do
      {:insert, t} ->
        merge_pass(diffs, p + 1, cd, ci + 1, td, ti ++ t)

      {:delete, t} ->
        merge_pass(diffs, p + 1, cd + 1, ci, td ++ t, ti)

      {:equal, _} ->
        cond do
          cd + ci > 1 ->
            {diffs, p, td, ti} =
              if cd != 0 and ci != 0,
                do: factor_common(diffs, p, cd, ci, td, ti),
                else: {diffs, p, td, ti}

            p = p - (cd + ci)
            diffs = Enum.take(diffs, p) ++ Enum.drop(diffs, p + cd + ci)

            {diffs, p} =
              if td != [], do: {List.insert_at(diffs, p, {:delete, td}), p + 1}, else: {diffs, p}

            {diffs, p} =
              if ti != [], do: {List.insert_at(diffs, p, {:insert, ti}), p + 1}, else: {diffs, p}

            merge_pass(diffs, p + 1, 0, 0, [], [])

          p != 0 and match?({:equal, _}, Enum.at(diffs, p - 1)) ->
            {:equal, prev} = Enum.at(diffs, p - 1)
            {:equal, cur} = Enum.at(diffs, p)
            diffs = diffs |> List.replace_at(p - 1, {:equal, prev ++ cur}) |> List.delete_at(p)
            merge_pass(diffs, p, 0, 0, [], [])

          true ->
            merge_pass(diffs, p + 1, 0, 0, [], [])
        end
    end
  end

  defp factor_common(diffs, p, cd, ci, td, ti) do
    {diffs, p, td, ti} =
      case common_prefix(ti, td) do
        0 ->
          {diffs, p, td, ti}

        cl ->
          head = Enum.take(ti, cl)
          at = p - cd - ci - 1

          {diffs, p} =
            if p - cd - ci > 0 and match?({:equal, _}, Enum.at(diffs, at)) do
              {:equal, t} = Enum.at(diffs, at)
              {List.replace_at(diffs, at, {:equal, t ++ head}), p}
            else
              {[{:equal, head} | diffs], p + 1}
            end

          {diffs, p, Enum.drop(td, cl), Enum.drop(ti, cl)}
      end

    case common_suffix(ti, td) do
      0 ->
        {diffs, p, td, ti}

      cl ->
        {:equal, t} = Enum.at(diffs, p)
        diffs = List.replace_at(diffs, p, {:equal, Enum.drop(ti, length(ti) - cl) ++ t})
        {diffs, p, Enum.take(td, length(td) - cl), Enum.take(ti, length(ti) - cl)}
    end
  end

  # A single edit between two equalities slides left or right when it can
  # take one of them in whole.
  defp shift_pass(diffs, p, changed) do
    if p >= length(diffs) - 1 do
      {diffs, changed}
    else
      case {Enum.at(diffs, p - 1), Enum.at(diffs, p), Enum.at(diffs, p + 1)} do
        {{:equal, prev}, {op, cur}, {:equal, next}} ->
          cond do
            ends_with?(cur, prev) ->
              cur2 = prev ++ Enum.take(cur, length(cur) - length(prev))

              diffs =
                diffs
                |> List.replace_at(p, {op, cur2})
                |> List.replace_at(p + 1, {:equal, prev ++ next})
                |> List.delete_at(p - 1)

              shift_pass(diffs, p + 1, true)

            starts_with?(cur, next) ->
              diffs =
                diffs
                |> List.replace_at(p - 1, {:equal, prev ++ next})
                |> List.replace_at(p, {op, Enum.drop(cur, length(next)) ++ next})
                |> List.delete_at(p + 1)

              shift_pass(diffs, p + 1, true)

            true ->
              shift_pass(diffs, p + 1, changed)
          end

        _ ->
          shift_pass(diffs, p + 1, changed)
      end
    end
  end

  defp ends_with?(list, suffix),
    do:
      length(suffix) <= length(list) and Enum.drop(list, length(list) - length(suffix)) == suffix

  defp starts_with?(list, prefix),
    do: length(prefix) <= length(list) and Enum.take(list, length(prefix)) == prefix

  # ── adjustDiffForSurrogatePairs ──────────────────────────────────────────

  defp high?(u), do: u >= 0xD800 and u <= 0xDBFF
  defp low?(u), do: u >= 0xDC00 and u <= 0xDFFF

  defp adjust_surrogates(diffs) do
    diffs = adjust_at(diffs, 0)
    remove_empty_once(diffs, 0)
  end

  defp adjust_at(diffs, i) when i >= length(diffs), do: diffs

  defp adjust_at(diffs, i) do
    diffs =
      case Enum.at(diffs, i) do
        {_op, []} ->
          diffs

        {op, [first | _] = text} ->
          diffs =
            if high?(List.last(text)) and op == :equal, do: deisolate(diffs, i, 1), else: diffs

          if low?(first) and op == :equal, do: deisolate(diffs, i, -1), else: diffs
      end

    adjust_at(diffs, i + 1)
  end

  # JS splices out an empty diff and steps past the next one.
  defp remove_empty_once(diffs, i) when i >= length(diffs), do: diffs

  defp remove_empty_once(diffs, i) do
    case Enum.at(diffs, i) do
      {_op, []} -> remove_empty_once(List.delete_at(diffs, i), i + 1)
      _ -> remove_empty_once(diffs, i + 1)
    end
  end

  defp split_char(data, 1), do: {Enum.take(data, length(data) - 1), List.last(data)}
  defp split_char([c | rest], -1), do: {rest, c}

  defp combine(data, c, 1), do: data ++ [c]
  defp combine(data, c, -1), do: [c | data]

  defp text_at(diffs, i), do: elem(Enum.at(diffs, i), 1)
  defp set_text(diffs, i, t), do: List.update_at(diffs, i, fn {op, _} -> {op, t} end)

  defp deisolate(diffs, i, dir) do
    inv = -dir

    case scan_neighbours(diffs, i + dir, dir, nil, nil) do
      {:equal_first, j} ->
        {rest, c} = split_char(text_at(diffs, i), dir)
        diffs |> set_text(i, rest) |> set_text(j, combine(text_at(diffs, j), c, inv))

      {j, ins, del} ->
        shared =
          ins != nil and del != nil and
            if(dir == 1,
              do: List.last(text_at(diffs, ins)) == List.last(text_at(diffs, del)),
              else: hd(text_at(diffs, ins)) == hd(text_at(diffs, del))
            )

        if shared do
          {ins_text, ins_char} = split_char(text_at(diffs, ins), inv)
          {del_text, _} = split_char(text_at(diffs, del), inv)

          diffs
          |> set_text(ins, ins_text)
          |> set_text(del, del_text)
          |> set_text(i, combine(text_at(diffs, i), ins_char, dir))
        else
          {text, c} = split_char(text_at(diffs, i), dir)
          diffs = set_text(diffs, i, text)

          {diffs, del} =
            if ins == nil do
              diffs = List.insert_at(diffs, j, {:insert, [c]})
              {diffs, if(del != nil and del >= j, do: del + 1, else: del)}
            else
              {set_text(diffs, ins, combine(text_at(diffs, ins), c, inv)), del}
            end

          if del == nil,
            do: List.insert_at(diffs, j, {:delete, [c]}),
            else: set_text(diffs, del, combine(text_at(diffs, del), c, inv))
        end
    end
  end

  defp scan_neighbours(diffs, j, dir, ins, del) do
    cond do
      j < 0 or j >= length(diffs) or (ins != nil and del != nil) ->
        {j, ins, del}

      true ->
        case Enum.at(diffs, j) do
          {_op, []} -> scan_neighbours(diffs, j + dir, dir, ins, del)
          {:insert, _} -> scan_neighbours(diffs, j + dir, dir, ins || j, del)
          {:delete, _} -> scan_neighbours(diffs, j + dir, dir, ins, del || j)
          {:equal, _} when ins == nil and del == nil -> {:equal_first, j}
          {:equal, _} -> {j, ins, del}
        end
    end
  end

  # ── cleanupSemanticLossless ──────────────────────────────────────────────

  @doc "`cleanupSemanticLossless`."
  @spec semantic_lossless([diff]) :: [diff]
  def semantic_lossless(diffs), do: lossless(diffs, 1)

  defp lossless(diffs, p) do
    if p >= length(diffs) - 1 do
      diffs
    else
      case {Enum.at(diffs, p - 1), Enum.at(diffs, p), Enum.at(diffs, p + 1)} do
        {{:equal, eq1}, {op, edit}, {:equal, eq2}} ->
          {eq1, edit, eq2} =
            case common_suffix(eq1, edit) do
              0 ->
                {eq1, edit, eq2}

              off ->
                common = Enum.drop(edit, length(edit) - off)

                {Enum.take(eq1, length(eq1) - off), common ++ Enum.take(edit, length(edit) - off),
                 common ++ eq2}
            end

          best = {eq1, edit, eq2, score(eq1, edit) + score(edit, eq2)}
          {b1, bedit, b2, _} = slide(eq1, edit, eq2, best)

          if elem(Enum.at(diffs, p - 1), 1) != b1 do
            {diffs, p} =
              if b1 != [],
                do: {List.replace_at(diffs, p - 1, {:equal, b1}), p},
                else: {List.delete_at(diffs, p - 1), p - 1}

            diffs = List.replace_at(diffs, p, {op, bedit})

            {diffs, p} =
              if b2 != [],
                do: {List.replace_at(diffs, p + 1, {:equal, b2}), p},
                else: {List.delete_at(diffs, p + 1), p - 1}

            lossless(diffs, p + 1)
          else
            lossless(diffs, p + 1)
          end

        _ ->
          lossless(diffs, p + 1)
      end
    end
  end

  defp slide(eq1, [e | erest], [e | eq2rest], best) do
    eq1 = eq1 ++ [e]
    edit = erest ++ [e]
    eq2 = eq2rest
    sc = score(eq1, edit) + score(edit, eq2)
    best = if sc >= elem(best, 3), do: {eq1, edit, eq2, sc}, else: best
    slide(eq1, edit, eq2, best)
  end

  defp slide(_eq1, _edit, _eq2, best), do: best

  defp score([], _), do: 6
  defp score(_, []), do: 6

  defp score(one, two) do
    c1 = List.last(one)
    c2 = hd(two)
    na1 = not alnum?(c1)
    na2 = not alnum?(c2)
    ws1 = na1 and space?(c1)
    ws2 = na2 and space?(c2)
    lb1 = ws1 and c1 in [?\r, ?\n]
    lb2 = ws2 and c2 in [?\r, ?\n]
    bl1 = lb1 and blank_end?(one)
    bl2 = lb2 and blank_start?(two)

    cond do
      bl1 or bl2 -> 5
      lb1 or lb2 -> 4
      na1 and not ws1 and ws2 -> 3
      ws1 or ws2 -> 2
      na1 or na2 -> 1
      true -> 0
    end
  end

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9

  # JavaScript's \s.
  defp space?(c),
    do:
      c in [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] or
        c in 0x2000..0x200A

  defp blank_end?(t) do
    case Enum.reverse(t) do
      [?\n, ?\n | _] -> true
      [?\n, ?\r, ?\n | _] -> true
      _ -> false
    end
  end

  defp blank_start?(t) do
    case t do
      [?\n, ?\n | _] -> true
      [?\r, ?\n, ?\n | _] -> true
      [?\n, ?\r, ?\n | _] -> true
      [?\r, ?\n, ?\r, ?\n | _] -> true
      _ -> false
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp common_prefix([a | ra], [a | rb]), do: 1 + common_prefix(ra, rb)
  defp common_prefix(_, _), do: 0

  defp common_suffix(a, b), do: common_prefix(Enum.reverse(a), Enum.reverse(b))

  defp slice(list, from, to) when to <= from, do: Enum.take(list, 0)
  defp slice(list, from, to), do: list |> Enum.drop(from) |> Enum.take(to - from)

  @doc false
  def index_of(list, pattern, from) do
    plen = length(pattern)
    tup = List.to_tuple(list)
    last = tuple_size(tup) - plen

    if plen == 0 do
      if from <= tuple_size(tup), do: max(from, 0), else: -1
    else
      Enum.find(max(from, 0)..max(last, -1)//1, -1, fn i ->
        pattern |> Enum.with_index(i) |> Enum.all?(fn {c, k} -> elem(tup, k) == c end)
      end)
    end
  end
end
