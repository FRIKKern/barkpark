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
end
