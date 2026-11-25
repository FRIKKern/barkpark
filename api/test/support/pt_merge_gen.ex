defmodule Barkpark.Test.PtMergeGen do
  @moduledoc """
  Seeded (base, mine, theirs) Portable Text triples for the merge fuzz
  (`portable_text_merge_fuzz_test.exs`, task-3fc3cc94b435a5b0,
  task-63cafe0ea4e7a187). Mine and theirs are each 0-3 edits of one base: a
  word replaced, put in or taken out, part of a word changed ("cart" to
  "carts" or "dart"), a mark added or taken off, a link put on a word, a
  block added, copied or taken out. Most edits fall on one block both sides
  share, so a block both changed in a certain line-up is common: the merge
  inside one block (task-266ffbe9cd115f3c) is reached there.

  Some seeds also have what a post from the editor has:

    * mine keyed by position (`p0`, `p0s0`, `p0m0`, as `from_html` keys
      new blocks), so a key the merge keeps names its side; or by position
      in the base's own names (`k0`), so two blocks of the merge can share
      a key (`unique_keys/1`);
    * blocks that draw the same, and empty ones, so a line-up can go more
      than one way (`unsure/4`);
    * Han and kana with no space between words.

  The pins hash this output, drawn with `:rand` (`exsss`) and
  `Enum.random/1`. An Elixir or OTP release that changes either moves every
  pin with no change to the merge; a plain regen is then the fix.
  """

  @latin ~w(one two three alpha beta the cat cart darts)
  @cjk ["かな", "漢字", "たべる", "東京", "ひと"]
  @other ["👨‍👩‍👧", "🇳🇴", "é", "。"]

  @doc "The triple for `seed`, the same on every run."
  def triple(seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    kind = Enum.random([:plain, :plain, :plain, :plain, :plain, :same, :cjk, :plain])
    base = base(kind)
    hot = pick(0..(length(base) - 1))
    mine = edit(base, "m", hot, kind)
    theirs = edit(base, "t", hot, kind)
    mine = if pick(1..2) == 1, do: by_position(mine, Enum.random(["k", "p"])), else: mine
    {base, mine, theirs}
  end

  defp base(:same) do
    w = words(pick(1..3), :plain)
    blocks = [w, w, [], words(pick(1..3), :plain)] |> Enum.take(pick(2..4)) |> Enum.shuffle()
    for {ws, i} <- Enum.with_index(blocks), do: block("k#{i}", ws, :plain)
  end

  defp base(kind),
    do: for(i <- 0..(pick(1..4) - 1), do: block("k#{i}", words(pick(1..5), kind), kind))

  defp edit(blocks, side, hot, kind) do
    Enum.reduce(1..Enum.random([0, 1, 1, 2, 2, 3])//1, {blocks, 0}, fn _, {bs, n} ->
      {one_edit(bs, side, n, hot, kind), n + 1}
    end)
    |> elem(0)
  end

  defp one_edit([], side, n, _hot, kind), do: [block("#{side}#{n}", words(2, kind), kind)]

  defp one_edit(blocks, side, n, hot, kind) do
    last = length(blocks) - 1
    i = if pick(1..5) > 1, do: min(hot, last), else: pick(0..last)

    case pick(1..22) do
      1 -> List.insert_at(blocks, i + 1, block("#{side}#{n}", words(pick(1..3), kind), kind))
      2 when last > 0 -> List.delete_at(blocks, i)
      3 -> List.insert_at(blocks, i + 1, Map.put(Enum.at(blocks, i), "_key", "#{side}#{n}"))
      k -> List.update_at(blocks, i, &change(&1, rem(k, 7) + 3, side, n, kind))
    end
  end

  defp change(block, k, side, n, kind) do
    j = pick(0..max(length(block["children"]) - 1, 0))

    case k do
      3 ->
        put_text(block, j, kind, &replace(&1, kind))

      4 ->
        put_text(block, j, kind, fn ws -> List.insert_at(ws, pick(0..length(ws)), word(kind)) end)

      5 ->
        put_text(block, j, kind, fn ws ->
          if length(ws) > 1, do: List.delete_at(ws, 0), else: ws
        end)

      6 ->
        mark(block, j, "strong")

      7 ->
        link(block, j, "#{side}d#{n}")

      8 ->
        put_text(block, j, kind, &part(&1))

      _ ->
        put_text(block, j, kind, fn ws -> ws ++ [word(kind)] end)
    end
  end

  defp replace(ws, kind), do: List.replace_at(ws, pick(0..(length(ws) - 1)), word(kind))

  # Part of one word: a letter put on its end, its first one changed, or its
  # last one taken off.
  defp part(ws) do
    List.update_at(ws, pick(0..(length(ws) - 1)), fn w ->
      case {pick(1..3), String.graphemes(w)} do
        {1, _} -> w <> "s"
        {2, [_ | rest]} -> Enum.join(["d" | rest])
        {_, [_, _ | _] = gs} -> Enum.join(Enum.drop(gs, -1))
        _ -> w <> "s"
      end
    end)
  end

  defp put_text(%{"children" => []} = block, _j, kind, f),
    do: Map.put(block, "children", [span("#{block["_key"]}s0", f.([word(kind)]), 0, kind)])

  defp put_text(block, j, kind, f) do
    update_span(block, j, fn s ->
      ws = split(s["text"], kind)

      Map.put(
        s,
        "text",
        join(f.(if ws == [], do: [word(kind)], else: ws), kind) <> tail(s["text"])
      )
    end)
  end

  defp mark(%{"children" => []} = block, _j, _m), do: block

  defp mark(block, j, m) do
    update_span(block, j, fn s ->
      marks = if m in s["marks"], do: List.delete(s["marks"], m), else: [m | s["marks"]]
      Map.put(s, "marks", marks)
    end)
  end

  defp link(%{"children" => []} = block, _j, _key), do: block

  defp link(block, j, key) do
    def = %{"_key" => key, "_type" => "link", "href" => "https://#{key}.example"}

    block
    |> Map.update!("markDefs", &(&1 ++ [def]))
    |> update_span(j, fn s -> Map.put(s, "marks", s["marks"] ++ [key]) end)
  end

  defp update_span(block, j, f), do: Map.update!(block, "children", &List.update_at(&1, j, f))

  # Keys by position, as `from_html` gives the blocks it builds: block
  # `<p><i>`, its spans `<p><i>s<j>`, its defs `<p><i>m<j>` and each mark
  # that names one. With `p` = "k" a key can be another base block's.
  defp by_position(blocks, p) do
    for {b, i} <- Enum.with_index(blocks) do
      defs = Enum.with_index(b["markDefs"])
      renamed = Map.new(defs, fn {d, j} -> {d["_key"], "#{p}#{i}m#{j}"} end)

      children =
        for {s, j} <- Enum.with_index(b["children"]),
            do: %{
              s
              | "_key" => "#{p}#{i}s#{j}",
                "marks" => Enum.map(s["marks"], &Map.get(renamed, &1, &1))
            }

      %{
        b
        | "_key" => "#{p}#{i}",
          "children" => children,
          "markDefs" => for({d, j} <- defs, do: %{d | "_key" => "#{p}#{i}m#{j}"})
      }
    end
  end

  defp block(key, ws, kind) do
    {a, b} = Enum.split(ws, div(length(ws) + 1, 2))

    spans =
      for {part, n} <- Enum.with_index([a, b]), part != [], do: span("#{key}s#{n}", part, n, kind)

    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => spans
    }
  end

  defp span(key, ws, n, kind) do
    %{
      "_type" => "span",
      "_key" => key,
      "text" => join(ws, kind) <> if(n == 0 and kind != :cjk, do: " ", else: ""),
      "marks" => if(n == 1, do: ["em"], else: [])
    }
  end

  # Han and kana run on with no space; the rest is split at spaces.
  defp split(text, :cjk), do: Regex.scan(~r/かな|漢字|たべる|東京|ひと|\S/u, text) |> List.flatten()
  defp split(text, _kind), do: String.split(text, " ", trim: true)
  defp join(ws, :cjk), do: Enum.join(ws)
  defp join(ws, _kind), do: Enum.join(ws, " ")
  defp tail(text), do: if(String.ends_with?(text, " "), do: " ", else: "")

  defp words(n, kind), do: for(_ <- 1..n//1, do: word(kind))
  defp word(:cjk), do: Enum.random(@cjk ++ @cjk ++ @other)
  defp word(_kind), do: Enum.random(@latin ++ @latin ++ @cjk ++ @other)
  defp pick(range), do: Enum.random(range)
end
