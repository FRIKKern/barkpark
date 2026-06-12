defmodule Barkpark.Plugins.Sheets.Fmt do
  @moduledoc """
  The Sheets `"fmt"` hint vocabulary and its two-way xlsx number-format
  mapping (M5).

  A cell's `"fmt"` is a coarse SEMANTIC class, not a verbatim format
  string — six values: `"fixed"`, `"percent"`, `"currency"`, `"thousands"`,
  `"date"`, `"datetime"`. "General" is represented by OMITTING `"fmt"`.

  Import (`classify/2`) maps an xlsx `numFmtId` to a class: builtin ids
  through a fixed table, custom ids (≥ 164) by inspecting the format
  string (`classify_format/1`). Export (`num_format/1`) writes one
  CANONICAL format string per class. The canonical strings classify back
  to their own class, so `fmt` survives a sheet → xlsx → sheet round trip
  exactly. A format that classifies to no class imports as general
  (no `fmt`) — a documented lossy edge (e.g. fraction or scientific
  formats), never an error.
  """

  # Builtin numFmtId → class (ECMA-376 §18.8.30). Ids absent from the table
  # (0 general, 11–13 scientific/fractions, 48–49 text, …) are general.
  @builtin %{
    1 => "fixed",
    2 => "fixed",
    3 => "thousands",
    4 => "thousands",
    5 => "currency",
    6 => "currency",
    7 => "currency",
    8 => "currency",
    9 => "percent",
    10 => "percent",
    14 => "date",
    15 => "date",
    16 => "date",
    17 => "date",
    18 => "datetime",
    19 => "datetime",
    20 => "datetime",
    21 => "datetime",
    22 => "datetime",
    37 => "thousands",
    38 => "thousands",
    39 => "thousands",
    40 => "thousands",
    44 => "currency",
    45 => "datetime",
    46 => "datetime",
    47 => "datetime"
  }

  # One canonical xlsx format string per class — what export writes.
  @canonical %{
    "fixed" => "0.00",
    "percent" => "0.00%",
    "currency" => "$#,##0.00",
    "thousands" => "#,##0",
    "date" => "yyyy-mm-dd",
    "datetime" => "yyyy-mm-dd h:mm:ss"
  }

  @doc "The six fmt classes."
  @spec vocabulary() :: [String.t()]
  def vocabulary, do: Map.keys(@canonical) |> Enum.sort()

  @doc """
  numFmtId (+ the workbook's custom `numFmtId => formatCode` map) → fmt
  class, or `nil` for general/unknown.
  """
  @spec classify(term(), map()) :: String.t() | nil
  def classify(nil, _custom), do: nil

  def classify(id, custom) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> classify(n, custom)
      _ -> nil
    end
  end

  def classify(id, custom) when is_integer(id) do
    @builtin[id] || classify_format(custom[Integer.to_string(id)])
  end

  @doc """
  Classify a raw format-code string. Order matters: percent and currency
  markers win over date letters, date letters win over digit patterns.
  Quoted literals and `[…]` sections are stripped before letter detection
  (`[Red]`/`"kr"` must not read as date letters) but kept for the currency
  probe (symbols often live inside `[$kr-414]`).
  """
  @spec classify_format(term()) :: String.t() | nil
  def classify_format(code) when is_binary(code) do
    s = String.downcase(code)
    bare = String.replace(s, ~r/\[[^\]]*\]|"[^"]*"/, "")

    cond do
      String.contains?(bare, "%") -> "percent"
      currency?(s) -> "currency"
      date_like?(bare) -> date_kind(bare)
      String.contains?(bare, "#,##") -> "thousands"
      String.contains?(bare, "0.0") -> "fixed"
      true -> nil
    end
  end

  def classify_format(_), do: nil

  @doc "fmt class → the canonical xlsx format string (nil for general/unknown)."
  @spec num_format(term()) :: String.t() | nil
  def num_format(fmt), do: @canonical[fmt]

  defp currency?(s), do: String.contains?(s, ["$", "€", "£", "¥", "kr"])

  defp date_like?(bare),
    do: String.contains?(bare, "y") or String.contains?(bare, "d") or String.contains?(bare, "h")

  defp date_kind(bare) do
    date? = String.contains?(bare, "y") or String.contains?(bare, "d")
    time? = String.contains?(bare, "h")

    cond do
      date? and time? -> "datetime"
      date? -> "date"
      # time-only formats land on datetime — the model has no time-only type
      true -> "datetime"
    end
  end
end
