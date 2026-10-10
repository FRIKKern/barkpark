defmodule Barkpark.Search.FoldTest do
  @moduledoc """
  task-1429eb7cfc6217ea — the Norwegian fold is one rule on both sides:
  `Fold.fold/1` (the query) and the `bp_fold` SQL function (the stored title)
  must agree on every row of this table, upper and lower case.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Search.Fold

  @table [
    {"Ærlig", "aerlig"},
    {"ærlig", "aerlig"},
    {"aerlig", "aerlig"},
    {"AERLIG", "aerlig"},
    {"Økonomi", "okonomi"},
    {"økonomi", "okonomi"},
    {"okonomi", "okonomi"},
    {"oekonomi", "okonomi"},
    {"OEKONOMI", "okonomi"},
    {"Årsrapport", "arsrapport"},
    {"årsrapport", "arsrapport"},
    {"arsrapport", "arsrapport"},
    {"aarsrapport", "arsrapport"},
    {"AARSRAPPORT", "arsrapport"},
    {"Ålesund og Aalesund", "alesund og alesund"},
    {"BLÅBÆRSYLTETØY", "blabaersyltetoy"},
    {"aaa", "aa"}
  ]

  # Non-Norwegian, non-ASCII capitals are left as they are on both sides
  # (lower-casing is ASCII-only, so it cannot depend on the database locale).
  @parity_only ["Économie", "ÉÄÖ straße"]

  test "Fold.fold/1 maps each row as the table says" do
    for {input, want} <- @table do
      assert Fold.fold(input) == want, "fold(#{inspect(input)})"
    end
  end

  test "bp_fold in SQL equals Fold.fold/1 on every row, so index and query fold alike" do
    for input <- Enum.map(@table, &elem(&1, 0)) ++ @parity_only do
      %{rows: [[sql]]} = Repo.query!("SELECT bp_fold($1)", [input])
      assert sql == Fold.fold(input), "bp_fold(#{inspect(input)}) = #{inspect(sql)}"
    end
  end
end
