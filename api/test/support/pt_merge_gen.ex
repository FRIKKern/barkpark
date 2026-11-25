defmodule Barkpark.Test.PtMergeGen do
  @moduledoc """
  Seeded (base, mine, theirs) Portable Text triples for the merge fuzz
  (`portable_text_merge_fuzz_test.exs`, task-3fc3cc94b435a5b0). Mine and
  theirs are each 0-3 edits of one base: a word replaced, put in or taken
  out, a mark added or taken off, a link put on a word, a block added or
  taken out. Words come from Latin, CJK and emoji pools, so a block both
  sides edited is common, which the merge inside one block
  (task-266ffbe9cd115f3c) needs to be reached.
  """

  @words ~w(one two three alpha beta the cat cart darts) ++
           ["かな", "漢字", "たべる", "👨‍👩‍👧", "🇳🇴", "é", "。"]

  @doc "The triple for `seed`, the same on every run."
  def triple(seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    base = for i <- 0..(pick(1..4) - 1), do: block("k#{i}", words(pick(1..5)))
    {base, edit(base, "m"), edit(base, "t")}
  end

  defp edit(blocks, side) do
    Enum.reduce(1..pick(0..3)//1, {blocks, 0}, fn _, {bs, n} -> {one_edit(bs, side, n), n + 1} end)
    |> elem(0)
  end

  defp one_edit([], side, n), do: [block("#{side}#{n}", words(2))]

  defp one_edit(blocks, side, n) do
    i = pick(0..(length(blocks) - 1))

    case pick(1..14) do
      1 -> List.insert_at(blocks, i + 1, block("#{side}#{n}", words(pick(1..3))))
      2 when length(blocks) > 1 -> List.delete_at(blocks, i)
      k -> List.update_at(blocks, i, &change(&1, rem(k, 6) + 3, side, n))
    end
  end

  defp change(block, k, side, n) do
    spans = block["children"]
    j = pick(0..(length(spans) - 1))

    case k do
      3 -> put_text(block, j, fn ws -> replace(ws) end)
      4 -> put_text(block, j, fn ws -> List.insert_at(ws, pick(0..length(ws)), word()) end)
      5 -> put_text(block, j, fn ws -> if length(ws) > 1, do: List.delete_at(ws, 0), else: ws end)
      6 -> mark(block, j, "strong")
      7 -> link(block, j, "#{side}d#{n}")
      _ -> put_text(block, j, fn ws -> ws ++ [word()] end)
    end
  end

  defp replace(ws), do: List.replace_at(ws, pick(0..(length(ws) - 1)), word())

  defp put_text(block, j, f) do
    update_span(block, j, fn s ->
      ws = String.split(s["text"], " ", trim: true)
      Map.put(s, "text", Enum.join(f.(if ws == [], do: [word()], else: ws), " "))
    end)
  end

  defp mark(block, j, m) do
    update_span(block, j, fn s ->
      marks = if m in s["marks"], do: List.delete(s["marks"], m), else: [m | s["marks"]]
      Map.put(s, "marks", marks)
    end)
  end

  defp link(block, j, key) do
    def = %{"_key" => key, "_type" => "link", "href" => "https://#{key}.example"}

    block
    |> Map.update!("markDefs", &(&1 ++ [def]))
    |> update_span(j, fn s -> Map.put(s, "marks", s["marks"] ++ [key]) end)
  end

  defp update_span(block, j, f), do: Map.update!(block, "children", &List.update_at(&1, j, f))

  defp block(key, ws) do
    {a, b} = Enum.split(ws, div(length(ws) + 1, 2))
    spans = for {part, n} <- Enum.with_index([a, b]), part != [], do: span("#{key}s#{n}", part, n)

    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => spans
    }
  end

  defp span(key, ws, n) do
    text = Enum.join(ws, " ") <> if(n == 0, do: " ", else: "")

    %{
      "_type" => "span",
      "_key" => key,
      "text" => text,
      "marks" => if(n == 1, do: ["em"], else: [])
    }
  end

  defp words(n), do: for(_ <- 1..n, do: word())
  defp word, do: Enum.random(@words)
  defp pick(range), do: Enum.random(range)
end
