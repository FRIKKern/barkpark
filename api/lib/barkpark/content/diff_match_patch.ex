defmodule Barkpark.Content.DiffMatchPatch do
  @moduledoc """
  Sanity's `diffMatchPatch` patch operation: apply a diff-match-patch patch
  (`patch_toText` form) to a string, as Sanity's mutate API does
  (task-88240409d3fc3c51, two editors typing in one Portable Text span).

  A port of what `applyPatches` in @sanity/diff-match-patch 3.2 does:
  `parsePatch` (the `@@` header counts UTF-8 bytes, as Sanity writes it),
  padding, `splitMax`, `match` with bitap (`threshold` 0.5, `distance` 1000),
  `xIndex`, `levenshtein` and the 0.4 delete threshold, with a margin of 4 and
  32 match bits. Text is worked on as UTF-16 code units, as in JavaScript, so
  a patch made in the browser lands where it was made.

  Each hunk is placed at its expected offset (moved by the hunks before it)
  when the text there still matches, else at the best fuzzy match nearby; a
  hunk that matches nowhere is skipped, so concurrent edits elsewhere in the
  same string survive. When a hunk lands on text its context no longer
  matches, the edit is mapped through diff-match-patch's own diff
  (`Barkpark.Content.DiffMatchPatch.Diff`), so it lands where Sanity lands it.
  Pinned to vectors made with @sanity/diff-match-patch (`makePatches`, then
  `applyPatches` on text another edit had changed): the same text and hunk
  results on every one it can apply. Where that library throws on a header
  offset after an earlier hunk's deletion (its offset walker only moves
  forward), this applies the patch.
  """

  import Bitwise

  alias Barkpark.Content.DiffMatchPatch.Diff

  @margin 4
  @max_bits 32
  @threshold 0.5
  @distance 1000
  @delete_threshold 0.4

  # One request must never hold a CPU (bitap is O(text x pattern) and the
  # fuzzy diff O(n x d)). Measured at these limits on a 2026 laptop: 100
  # hunks re-matched by bitap on a 20,000-unit text, about 0.3 s; a fuzzy
  # diff over the full unit budget, see the test. Past one, `apply/2`
  # answers `{:error, :limit, message}` and the mutate route a 422.
  @max_patch_bytes 32_768
  @max_hunks 100
  @max_text_units 20_000
  @max_fuzzy_units 2_000

  @type op :: :equal | :insert | :delete
  @type units :: [non_neg_integer()]

  @doc """
  Apply `patch_text` to `text`. Returns `{:ok, new_text, applied}` with one
  boolean per hunk, or `:error` when the patch text does not parse or the
  result is not valid text.
  """
  @spec apply(String.t(), String.t()) ::
          {:ok, String.t(), [boolean()]} | :error | {:error, :limit, String.t()}
  def apply(patch_text, text) when is_binary(patch_text) and is_binary(text) do
    if Process.get(:dmp_budget),
      do: do_apply(patch_text, text),
      else: with_budget(fn -> do_apply(patch_text, text) end)
  end

  def apply(_patch_text, _text), do: :error

  defp do_apply(patch_text, text) do
    with :ok <-
           spend(
             :bytes,
             byte_size(patch_text),
             @max_patch_bytes,
             "the patch text is over #{@max_patch_bytes} bytes"
           ),
         {:ok, patches} <- from_text(patch_text),
         :ok <-
           spend(:hunks, length(patches), @max_hunks, "the patch has over #{@max_hunks} hunks"),
         {:ok, units} <- to_units(text),
         :ok <-
           spend(
             :units,
             length(units),
             @max_text_units,
             "the text is over #{@max_text_units} UTF-16 units"
           ),
         {:ok, patches} <- to_unit_offsets(patches, text) do
      {result, applied} = patch_apply(patches, units)

      case from_units(result) do
        {:ok, string} -> {:ok, string, applied}
        :error -> :error
      end
    end
  catch
    {:dmp_limit, message} -> {:error, :limit, message}
  end

  @doc "The limits one `apply/2` call, or one `with_budget/1`, works within."
  def limits,
    do: %{
      patch_bytes: @max_patch_bytes,
      hunks: @max_hunks,
      text_units: @max_text_units,
      fuzzy_units: @max_fuzzy_units
    }

  @doc """
  Run `fun` with one budget for every `apply/2` inside it: the patch bytes,
  hunks, text units and long-hunk diff units of all of them count against the
  limits of one call. The mutate route wraps all of a patch's
  `diffMatchPatch` paths in it, so many paths cost no more than one.
  """
  def with_budget(fun) do
    Process.put(:dmp_budget, %{bytes: 0, hunks: 0, units: 0, fuzzy: 0})

    try do
      fun.()
    after
      Process.delete(:dmp_budget)
    end
  end

  defp spend(kind, n, max, message) do
    budget = Process.get(:dmp_budget)
    used = Map.fetch!(budget, kind) + n

    if used <= max do
      Process.put(:dmp_budget, Map.put(budget, kind, used))
      :ok
    else
      {:error, :limit, message}
    end
  end

  # ── text as UTF-16 code units ──────────────────────────────────────────────

  defp to_units(string) do
    case :unicode.characters_to_binary(string, :utf8, {:utf16, :big}) do
      bin when is_binary(bin) -> {:ok, for(<<u::16 <- bin>>, do: u)}
      _ -> :error
    end
  end

  defp from_units(units) do
    bin = for u <- units, into: <<>>, do: <<u::16>>

    case :unicode.characters_to_binary(bin, {:utf16, :big}, :utf8) do
      s when is_binary(s) -> {:ok, s}
      _ -> :error
    end
  end

  # ── patch_fromText ─────────────────────────────────────────────────────────

  @header ~r/\A@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@\z/

  @doc false
  def from_text(""), do: {:ok, []}

  def from_text(text) do
    text |> String.split("\n") |> parse_patches([])
  end

  defp parse_patches([], acc), do: {:ok, Enum.reverse(acc)}
  defp parse_patches(["" | rest], acc), do: parse_patches(rest, acc)

  defp parse_patches([line | rest], acc) do
    case Regex.run(@header, line) do
      [_, s1, l1, s2, l2] ->
        {start1, length1} = coords(s1, l1)
        {start2, length2} = coords(s2, l2)

        case parse_lines(rest, []) do
          {:ok, diffs, rest} ->
            # The header counts UTF-8 bytes; the lengths `patch_apply` uses
            # count UTF-16 units, so each diff takes off its difference.
            {length1, length2} =
              Enum.reduce(diffs, {length1, length2}, fn {op, units}, {l1, l2} ->
                extra = utf8_size(units) - length(units)

                case op do
                  :delete -> {l1 - extra, l2}
                  :insert -> {l1, l2 - extra}
                  :equal -> {l1 - extra, l2 - extra}
                end
              end)

            patch = %{
              start1: start1,
              start2: start2,
              length1: length1,
              length2: length2,
              diffs: diffs
            }

            parse_patches(rest, [patch | acc])

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp coords(start, ""), do: {String.to_integer(start) - 1, 1}
  defp coords(start, "0"), do: {String.to_integer(start), 0}
  defp coords(start, len), do: {String.to_integer(start) - 1, String.to_integer(len)}

  defp parse_lines([], acc), do: {:ok, Enum.reverse(acc), []}
  defp parse_lines(["@" <> _ | _] = rest, acc), do: {:ok, Enum.reverse(acc), rest}
  defp parse_lines(["" | rest], acc), do: parse_lines(rest, acc)

  defp parse_lines([<<sign::utf8, encoded::binary>> | rest], acc) when sign in [?\s, ?-, ?+] do
    with {:ok, decoded} <- decode(encoded),
         {:ok, units} <- to_units(decoded) do
      op =
        case sign do
          ?\s -> :equal
          ?- -> :delete
          ?+ -> :insert
        end

      parse_lines(rest, [{op, units} | acc])
    end
  end

  defp parse_lines(_lines, _acc), do: :error

  defp decode(encoded) do
    {:ok, URI.decode(encoded)}
  rescue
    ArgumentError -> :error
  end

  defp utf8_size(units) do
    case from_units(units) do
      {:ok, s} -> byte_size(s)
      :error -> length(units)
    end
  end

  # Sanity's patch text gives `start1`/`start2` as UTF-8 byte offsets into the
  # text it was made from (@sanity/diff-match-patch's
  # `adjustIndiciesToUcs2`): each becomes a UTF-16 offset into `text`. An
  # offset past the end is the end; one inside a character fails the patch.
  defp to_unit_offsets(patches, text) do
    Enum.reduce_while(patches, {:ok, []}, fn p, {:ok, acc} ->
      with {:ok, s1} <- unit_offset(text, p.start1),
           {:ok, s2} <- unit_offset(text, p.start2) do
        {:cont, {:ok, [%{p | start1: s1, start2: s2} | acc]}}
      else
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp unit_offset(text, target), do: unit_offset(text, target, 0, 0)

  defp unit_offset(_text, target, bytes, units) when bytes == target, do: {:ok, units}
  defp unit_offset(_text, target, bytes, _units) when bytes > target, do: :error
  defp unit_offset(<<>>, _target, _bytes, units), do: {:ok, units}

  defp unit_offset(<<cp::utf8, rest::binary>>, target, bytes, units) do
    size = byte_size(<<cp::utf8>>)
    unit_offset(rest, target, bytes + size, units + if(cp > 0xFFFF, do: 2, else: 1))
  end

  defp unit_offset(_text, _target, _bytes, _units), do: :error

  # ── patch_apply ────────────────────────────────────────────────────────────

  defp patch_apply([], text), do: {text, []}

  defp patch_apply(patches, text) do
    padding = Enum.to_list(1..@margin)
    patches = patches |> add_padding(padding) |> split_max()
    text = padding ++ text ++ padding

    {text, _delta, applied} =
      Enum.reduce(patches, {text, 0, []}, fn patch, {text, delta, applied} ->
        {text, delta, ok?} = apply_hunk(patch, text, delta)
        {text, delta, [ok? | applied]}
      end)

    inner = text |> Enum.drop(@margin) |> Enum.take(length(text) - 2 * @margin)
    {inner, Enum.reverse(applied)}
  end

  defp apply_hunk(patch, text, delta) do
    expected = patch.start2 + delta
    text1 = text1(patch.diffs)
    len1 = length(text1)

    {start_loc, end_loc} =
      if len1 > @max_bits do
        start_loc = match_main(text, Enum.take(text1, @max_bits), expected)

        if start_loc == -1 do
          {-1, -1}
        else
          end_loc =
            match_main(text, Enum.drop(text1, len1 - @max_bits), expected + len1 - @max_bits)

          if end_loc == -1 or start_loc >= end_loc, do: {-1, -1}, else: {start_loc, end_loc}
        end
      else
        {match_main(text, text1, expected), -1}
      end

    if start_loc == -1 do
      {text, delta - (patch.length2 - patch.length1), false}
    else
      delta = start_loc - expected

      text2 =
        if end_loc == -1,
          do: slice(text, start_loc, start_loc + len1),
          else: slice(text, start_loc, end_loc + @max_bits)

      if text1 == text2 do
        {take(text, start_loc) ++ text2(patch.diffs) ++ Enum.drop(text, start_loc + len1), delta,
         true}
      else
        fuzzy_apply(patch, text, text1, text2, start_loc, delta)
      end
    end
  end

  defp fuzzy_apply(patch, text, text1, text2, start_loc, delta) do
    len1 = length(text1)

    # A hunk of up to 32 units diffs at most 64 units; a longer one (a
    # deleted stretch past `split_max/1`) can diff thousands. Those count
    # against one budget per call.
    if len1 > @max_bits do
      with {:error, :limit, message} <-
             spend(
               :fuzzy,
               len1 + length(text2),
               @max_fuzzy_units,
               "re-placing a long hunk on changed text needs over #{@max_fuzzy_units} units of diff"
             ),
           do: throw({:dmp_limit, message})
    end

    diffs = Diff.diff(text1, text2)

    if len1 > @max_bits and levenshtein(diffs) / len1 > @delete_threshold do
      {text, delta, false}
    else
      diffs = Diff.semantic_lossless(diffs)

      {text, _index1} =
        Enum.reduce(patch.diffs, {text, 0}, fn
          {:equal, data}, {text, index1} ->
            {text, index1 + length(data)}

          {:insert, data}, {text, index1} ->
            at = start_loc + x_index(diffs, index1)
            {take(text, at) ++ data ++ Enum.drop(text, at), index1 + length(data)}

          {:delete, data}, {text, index1} ->
            from = start_loc + x_index(diffs, index1)
            to = start_loc + x_index(diffs, index1 + length(data))
            {take(text, from) ++ Enum.drop(text, to), index1}
        end)

      {text, delta, true}
    end
  end

  defp text1(diffs), do: Enum.flat_map(diffs, fn {op, u} -> if op == :insert, do: [], else: u end)
  defp text2(diffs), do: Enum.flat_map(diffs, fn {op, u} -> if op == :delete, do: [], else: u end)

  defp take(_list, n) when n <= 0, do: []
  defp take(list, n), do: Enum.take(list, n)

  defp slice(_list, from, to) when to <= from, do: []
  defp slice(list, from, to), do: list |> Enum.drop(max(from, 0)) |> Enum.take(to - max(from, 0))

  # ── diff_xIndex / diff_levenshtein ─────────────────────────────────────────

  defp x_index(diffs, loc), do: x_index(diffs, loc, 0, 0, 0, 0)

  defp x_index([], loc, _c1, _c2, last1, last2), do: last2 + (loc - last1)

  defp x_index([{op, u} | rest], loc, c1, c2, last1, last2) do
    n1 = if op != :insert, do: c1 + length(u), else: c1
    n2 = if op != :delete, do: c2 + length(u), else: c2

    cond do
      n1 <= loc -> x_index(rest, loc, n1, n2, n1, n2)
      op == :delete -> last2
      true -> last2 + (loc - last1)
    end
  end

  defp levenshtein(diffs) do
    {total, ins, del} =
      Enum.reduce(diffs, {0, 0, 0}, fn
        {:insert, u}, {t, i, d} -> {t, i + length(u), d}
        {:delete, u}, {t, i, d} -> {t, i, d + length(u)}
        {:equal, _}, {t, i, d} -> {t + max(i, d), 0, 0}
      end)

    total + max(ins, del)
  end

  # ── match_main / match_bitap ───────────────────────────────────────────────

  defp match_main(text, pattern, loc) do
    tlen = length(text)
    loc = loc |> max(0) |> min(tlen)

    cond do
      text == pattern -> 0
      text == [] -> -1
      slice(text, loc, loc + length(pattern)) == pattern -> loc
      true -> bitap(List.to_tuple(text), pattern, loc)
    end
  end

  defp bitap(text, pattern, loc) do
    plen = length(pattern)
    tlen = tuple_size(text)
    alphabet = alphabet(pattern)
    score = fn e, x -> e / plen + abs(loc - x) / @distance end

    threshold =
      case index_of(text, pattern, loc) do
        -1 ->
          @threshold

        best ->
          t = min(score.(0, best), @threshold)

          case last_index_of(text, pattern, loc + plen) do
            -1 -> t
            best -> min(score.(0, best), t)
          end
      end

    match_mask = 1 <<< (plen - 1)

    bitap_rounds(0, %{
      text: text,
      tlen: tlen,
      plen: plen,
      loc: loc,
      alphabet: alphabet,
      score: score,
      threshold: threshold,
      match_mask: match_mask,
      bin_max: plen + tlen,
      best: -1,
      last_rd: %{}
    })
  end

  defp bitap_rounds(d, s) when d >= s.plen, do: s.best

  defp bitap_rounds(d, s) do
    bin_mid = bin_search(d, s, 0, s.bin_max, s.bin_max)
    start = max(1, s.loc - bin_mid + 1)
    finish = min(s.loc + bin_mid, s.tlen) + s.plen
    rd = %{(finish + 1) => (1 <<< d) - 1}

    {rd, threshold, best} = bitap_scan(finish, start, d, rd, s.threshold, s.best, s)
    s = %{s | bin_max: bin_mid, threshold: threshold, best: best}

    if s.score.(d + 1, s.loc) > threshold,
      do: best,
      else: bitap_rounds(d + 1, %{s | last_rd: rd})
  end

  # The binary search for how far from `loc` a match with `d` errors may be.
  defp bin_search(d, s, bin_min, bin_max, bin_mid) do
    if bin_min < bin_mid do
      {bin_min, bin_max} =
        if s.score.(d, s.loc + bin_mid) <= s.threshold,
          do: {bin_mid, bin_max},
          else: {bin_min, bin_mid}

      bin_search(d, s, bin_min, bin_max, div(bin_max - bin_min, 2) + bin_min)
    else
      bin_mid
    end
  end

  defp bitap_scan(j, start, _d, rd, threshold, best, _s) when j < start, do: {rd, threshold, best}

  defp bitap_scan(j, start, d, rd, threshold, best, s) do
    char_match =
      if s.tlen <= j - 1, do: 0, else: Map.get(s.alphabet, elem(s.text, j - 1), 0)

    next = Map.get(rd, j + 1, 0)

    value =
      if d == 0 do
        (next <<< 1 ||| 1) &&& char_match
      else
        last_next = Map.get(s.last_rd, j + 1, 0)
        last_here = Map.get(s.last_rd, j, 0)

        ((next <<< 1 ||| 1) &&& char_match) ||| ((last_next ||| last_here) <<< 1 ||| 1) |||
          last_next
      end

    rd = Map.put(rd, j, value)

    if (value &&& s.match_mask) != 0 do
      sc = s.score.(d, j - 1)

      if sc <= threshold do
        best = j - 1

        if best > s.loc,
          do: bitap_scan(j - 1, max(1, 2 * s.loc - best), d, rd, sc, best, s),
          else: {rd, sc, best}
      else
        bitap_scan(j - 1, start, d, rd, threshold, best, s)
      end
    else
      bitap_scan(j - 1, start, d, rd, threshold, best, s)
    end
  end

  defp alphabet(pattern) do
    len = length(pattern)

    pattern
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {c, i}, acc ->
      Map.update(acc, c, 1 <<< (len - i - 1), &(&1 ||| 1 <<< (len - i - 1)))
    end)
  end

  defp index_of(text, pattern, from) do
    plen = length(pattern)
    last = tuple_size(text) - plen
    Enum.find(max(from, 0)..max(last, -1)//1, -1, &at?(text, pattern, &1))
  end

  defp last_index_of(text, pattern, from) do
    plen = length(pattern)
    first = min(from, tuple_size(text) - plen)
    if first < 0, do: -1, else: Enum.find(first..0//-1, -1, &at?(text, pattern, &1))
  end

  defp at?(text, pattern, i) do
    pattern
    |> Enum.with_index(i)
    |> Enum.all?(fn {c, k} -> elem(text, k) == c end)
  end

  # ── patch_addPadding ───────────────────────────────────────────────────────

  defp add_padding(patches, padding) do
    patches = Enum.map(patches, &%{&1 | start1: &1.start1 + @margin, start2: &1.start2 + @margin})
    [first | _] = patches
    first = pad_front(first, padding)
    patches = List.replace_at(patches, 0, first)
    last = pad_back(List.last(patches), padding)
    List.replace_at(patches, -1, last)
  end

  defp pad_front(%{diffs: [{:equal, u} | rest]} = p, padding) when length(u) < @margin do
    extra = @margin - length(u)

    %{
      p
      | diffs: [{:equal, Enum.drop(padding, length(u)) ++ u} | rest],
        start1: p.start1 - extra,
        start2: p.start2 - extra,
        length1: p.length1 + extra,
        length2: p.length2 + extra
    }
  end

  defp pad_front(%{diffs: [{:equal, _} | _]} = p, _padding), do: p

  defp pad_front(p, padding) do
    %{
      p
      | diffs: [{:equal, padding} | p.diffs],
        start1: p.start1 - @margin,
        start2: p.start2 - @margin,
        length1: p.length1 + @margin,
        length2: p.length2 + @margin
    }
  end

  defp pad_back(%{diffs: diffs} = p, padding) do
    case List.last(diffs) do
      {:equal, u} when length(u) < @margin ->
        extra = @margin - length(u)

        %{
          p
          | diffs: List.replace_at(diffs, -1, {:equal, u ++ Enum.take(padding, extra)}),
            length1: p.length1 + extra,
            length2: p.length2 + extra
        }

      {:equal, _} ->
        p

      _ ->
        %{
          p
          | diffs: diffs ++ [{:equal, padding}],
            length1: p.length1 + @margin,
            length2: p.length2 + @margin
        }
    end
  end

  # ── patch_splitMax ─────────────────────────────────────────────────────────

  defp split_max(patches), do: Enum.flat_map(patches, &split_one/1)

  defp split_one(%{length1: l1} = patch) when l1 <= @max_bits, do: [patch]

  defp split_one(big) do
    split_loop(big.diffs, big.start1, big.start2, [], [])
  end

  defp split_loop([], _start1, _start2, _precontext, acc), do: Enum.reverse(acc)

  defp split_loop(big_diffs, start1, start2, precontext, acc) do
    pre = length(precontext)

    patch = %{
      start1: start1 - pre,
      start2: start2 - pre,
      length1: pre,
      length2: pre,
      diffs: if(precontext == [], do: [], else: [{:equal, precontext}])
    }

    {patch, big_diffs, start1, start2, empty?} =
      fill(patch, big_diffs, start1, start2, true)

    precontext =
      patch.diffs |> text2() |> then(&Enum.drop(&1, max(length(&1) - @margin, 0)))

    post = big_diffs |> text1() |> Enum.take(@margin)

    patch =
      if post == [] do
        patch
      else
        diffs =
          case List.last(patch.diffs) do
            {:equal, u} -> List.replace_at(patch.diffs, -1, {:equal, u ++ post})
            _ -> patch.diffs ++ [{:equal, post}]
          end

        %{
          patch
          | diffs: diffs,
            length1: patch.length1 + length(post),
            length2: patch.length2 + length(post)
        }
      end

    acc = if empty?, do: acc, else: [patch | acc]
    split_loop(big_diffs, start1, start2, precontext, acc)
  end

  defp fill(patch, [], start1, start2, empty?), do: {patch, [], start1, start2, empty?}

  defp fill(patch, big_diffs, start1, start2, empty?)
       when patch.length1 >= @max_bits - @margin,
       do: {patch, big_diffs, start1, start2, empty?}

  defp fill(patch, [{:insert, u} | rest], start1, start2, _empty?) do
    patch = %{patch | length2: patch.length2 + length(u), diffs: patch.diffs ++ [{:insert, u}]}
    fill(patch, rest, start1, start2 + length(u), false)
  end

  defp fill(%{diffs: [{:equal, _}]} = patch, [{:delete, u} | rest], start1, start2, _empty?)
       when length(u) > 2 * @max_bits do
    patch = %{patch | length1: patch.length1 + length(u), diffs: patch.diffs ++ [{:delete, u}]}
    fill(patch, rest, start1 + length(u), start2, false)
  end

  defp fill(patch, [{op, u} | rest], start1, start2, empty?) do
    part = Enum.take(u, max(@max_bits - patch.length1 - @margin, 0))
    n = length(part)
    patch = %{patch | length1: patch.length1 + n, diffs: patch.diffs ++ [{op, part}]}

    {patch, start2, empty?} =
      if op == :equal,
        do: {%{patch | length2: patch.length2 + n}, start2 + n, empty?},
        else: {patch, start2, false}

    rest = if part == u, do: rest, else: [{op, Enum.drop(u, n)} | rest]
    fill(patch, rest, start1 + n, start2, empty?)
  end
end
