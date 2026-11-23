defmodule Barkpark.Test.CarriedWords do
  @moduledoc """
  Carried, not printed: the one list of words a fixture's BPML printout lacks
  because an item with an id holds a `text` the reader does not show. A push
  carries that text back from the stored item by its id (`ListItems.carry/2`);
  `BulldocsBpmlFixtureRoundTripTest` proves it byte-equal after an edit.

  Every words check reads this list (`EveryFixtureWordsTest`,
  `BpmlListItemsTest`), so it is closed: a printout that lacks a word not on
  it fails, and there is no other list of known missing words.
  """

  @carried %{
    "nested-list-carriers" => [
      {"Inactive", 1, 0},
      {"fallback", 2, 1},
      {"parent", 2, 1}
    ]
  }

  @doc "Document name => `[{word, in source, in printout}]` carried, not printed."
  @spec all() :: %{String.t() => [{String.t(), pos_integer(), non_neg_integer()}]}
  def all, do: @carried

  @doc "The carried words of one document; `[]` for a document not on the list."
  @spec of(String.t()) :: [{String.t(), pos_integer(), non_neg_integer()}]
  def of(name), do: Map.get(@carried, name, [])
end
