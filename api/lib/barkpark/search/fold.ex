defmodule Barkpark.Search.Fold do
  @moduledoc """
  The Norwegian search fold (task-1429eb7cfc6217ea), the Elixir twin of the
  `bp_fold(text)` SQL function (migration 20261010073000).

  æ→ae, ø→o, å→a in either case, ASCII A–Z lower-cased, then aa→a and oe→o.
  "Ærlig" and "aerlig" fold to "aerlig"; "økonomi", "okonomi" and "oekonomi"
  to "okonomi"; "årsrapport", "arsrapport" and "aarsrapport" to "arsrapport".
  The retriever folds the query here and the stored title with `bp_fold`,
  so both sides go through one rule; `fold_test.exs` pins them equal.
  """

  @letters [{"Æ", "ae"}, {"æ", "ae"}, {"Ø", "o"}, {"ø", "o"}, {"Å", "a"}, {"å", "a"}]

  @spec fold(String.t()) :: String.t()
  def fold(text) when is_binary(text) do
    @letters
    |> Enum.reduce(text, fn {from, to}, acc -> String.replace(acc, from, to) end)
    |> String.downcase(:ascii)
    |> String.replace("aa", "a")
    |> String.replace("oe", "o")
  end

  # A folded word holds at most this many letters that unfold (a, o, ae), so a
  # word expands to at most 2^5 spellings plus their transliterations.
  @max_unfold_points 5

  @doc """
  The spellings of `word` the full-text index can hold, for the query side of
  the fold on every field (task-3c6d02392d430c98).

  The index stores words as written (Knausgård, Nesbø). `fold/1` maps several
  spellings to one, so a folded query word is unfolded again: each `a` may be
  `a` or `å`, each `o` may be `o` or `ø`, each `ae` may be `ae` or `æ`, and each
  spelling also comes with its ASCII transliteration (å→aa, ø→oe, æ→ae). The
  word as typed, lower-cased, is always first. "knausgard", "knausgaard" and
  "knausgård" all expand to a list that holds "knausgård" and "knausgaard";
  "nesbo" to one that holds "nesbø".

  A word with more than #{@max_unfold_points} unfold points expands only to
  itself, its fold and the fold's transliteration, so the list stays short.
  """
  @spec variants(String.t()) :: [String.t()]
  def variants(word) when is_binary(word) do
    typed = String.downcase(word)
    folded = fold(typed)
    points = unfold_points(folded)

    unfolded =
      if points <= @max_unfold_points,
        do: unfold(String.graphemes(folded)),
        else: [folded]

    Enum.uniq([typed | unfolded] ++ Enum.map(unfolded, &transliterate/1))
  end

  defp unfold_points(folded) do
    folded
    |> String.replace("ae", "#")
    |> String.graphemes()
    |> Enum.count(&(&1 in ["a", "o", "#"]))
  end

  defp unfold([]), do: [""]
  defp unfold(["a", "e" | rest]), do: for(h <- ["ae", "æ"], t <- unfold(rest), do: h <> t)
  defp unfold(["a" | rest]), do: for(h <- ["a", "å"], t <- unfold(rest), do: h <> t)
  defp unfold(["o" | rest]), do: for(h <- ["o", "ø"], t <- unfold(rest), do: h <> t)
  defp unfold([c | rest]), do: for(t <- unfold(rest), do: c <> t)

  defp transliterate(spelling) do
    spelling
    |> String.replace("å", "aa")
    |> String.replace("ø", "oe")
    |> String.replace("æ", "ae")
  end
end
