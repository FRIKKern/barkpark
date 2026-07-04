defmodule Barkpark.Plugins.Sheets.Fmt do
  @moduledoc """
  The Sheets `"fmt"` hint vocabulary and its two-way xlsx number-format
  mapping (M5).

  A cell's `"fmt"` is a coarse SEMANTIC class, not a verbatim format
  string — six xlsx-mappable values (`"fixed"`, `"percent"`, `"currency"`,
  `"thousands"`, `"date"`, `"datetime"`) plus one DISPLAY-ONLY class,
  `"checkbox"` (a boolean rendered as a toggleable glyph in Studio — it has
  no xlsx number-format counterpart, so `num_format/1` returns nil for it and
  it never round-trips through export/import; booleans still snapshot/export
  as `TRUE`/`FALSE`). "General" is represented by OMITTING `"fmt"`.

  Import (`classify/2`) maps an xlsx `numFmtId` to a class: builtin ids
  through a fixed table, custom ids (≥ 164) by inspecting the format
  string (`classify_format/1`). Export (`num_format/1`) writes one
  CANONICAL format string per class. The canonical strings classify back
  to their own class, so `fmt` survives a sheet → xlsx → sheet round trip
  exactly. A format that classifies to no class imports as general
  (no `fmt`) — a documented lossy edge (e.g. fraction or scientific
  formats), never an error.
  """

  alias Barkpark.Plugins.Sheets.Core

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

  # Display-only fmt classes — no xlsx number-format counterpart, so they are
  # absent from @canonical and `num_format/1` returns nil for them. Still valid
  # `fmt` values (the session validates against `vocabulary/0`).
  @display_only ["checkbox"]

  @doc "The fmt classes: the six xlsx-mappable ones plus the display-only `checkbox`."
  @spec vocabulary() :: [String.t()]
  def vocabulary, do: (Map.keys(@canonical) ++ @display_only) |> Enum.sort()

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

  @doc """
  Render a cell value for DISPLAY under its `fmt` class — the read-surface
  twin of the xlsx `numFmt` written by `num_format/1`. Applied at the two
  presentation seams (`Core.display_value/1` for every snapshot surface and
  `SheetGrid.Cells.display/1` for the Studio grid) so an imported `25%`
  cell shows `"25.00%"` everywhere, not the raw `0.25`.

  Total — never raises. A value/class mismatch (a `"date"` fmt on a number,
  any fmt on a value the class can't render) falls through to the general
  path: numbers via `Core.number_to_display/1`, binaries verbatim, booleans
  `TRUE`/`FALSE`. Semantics are locked in `fmt_test.exs`; the web TS twin
  copies that vector table verbatim.

  Number classes use ties-away-from-zero integer math (`Kernel.round/1`,
  Excel half-up): `percent` → `0.00%` (no grouping); `fixed` → `0.00`
  (no grouping); `thousands` → comma-grouped integer; `currency` →
  `$`-prefixed, comma-grouped, two decimals, sign OUTSIDE the symbol.
  Date classes expect the ISO-8601 strings xlsx import stores: `date`
  keeps the date part, `datetime` renders `YYYY-MM-DD HH:MM:SS` (seconds,
  no subseconds); an unparseable string returns verbatim.
  """
  @spec display(term(), String.t() | nil) :: String.t()
  def display(true, _fmt), do: "TRUE"
  def display(false, _fmt), do: "FALSE"

  def display(v, "percent") when is_number(v) do
    {neg?, body} = format_number(v * 100, 2, false)
    sign(neg?) <> body <> "%"
  end

  def display(v, "fixed") when is_number(v) do
    {neg?, body} = format_number(v, 2, false)
    sign(neg?) <> body
  end

  def display(v, "thousands") when is_number(v) do
    {neg?, body} = format_number(v, 0, true)
    sign(neg?) <> body
  end

  def display(v, "currency") when is_number(v) do
    {neg?, body} = format_number(v, 2, true)
    sign(neg?) <> "$" <> body
  end

  def display(v, "date") when is_binary(v), do: date_part(v)
  def display(v, "datetime") when is_binary(v), do: datetime_part(v)

  # General / fallback path: any type/class mismatch lands here.
  def display(v, _fmt) when is_number(v), do: Core.number_to_display(v)
  def display(v, _fmt) when is_binary(v), do: v
  def display(_v, _fmt), do: ""

  # A number → {negative?, unsigned body} with `decimals` fixed places and
  # optional comma grouping of the integer part. Sign is returned separately
  # so callers place it (currency puts `$` between sign and body).
  defp format_number(v, decimals, group?) do
    scale = Integer.pow(10, decimals)
    scaled = Kernel.round(v * scale)
    neg? = scaled < 0
    scaled = abs(scaled)
    int_part = div(scaled, scale)
    int_str = if group?, do: group_thousands(Integer.to_string(int_part)), else: Integer.to_string(int_part)

    body =
      if decimals > 0 do
        frac = scaled |> rem(scale) |> Integer.to_string() |> String.pad_leading(decimals, "0")
        int_str <> "." <> frac
      else
        int_str
      end

    {neg?, body}
  end

  defp group_thousands(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &List.to_string/1)
  end

  defp sign(true), do: "-"
  defp sign(false), do: ""

  # `date`/`datetime` values are ISO-8601 strings (xlsx import). Validate via
  # NaiveDateTime then Date; an unparseable string returns verbatim.
  defp date_part(v) do
    case NaiveDateTime.from_iso8601(v) do
      {:ok, ndt} -> ndt |> NaiveDateTime.to_date() |> Date.to_iso8601()
      _ -> case Date.from_iso8601(v) do
             {:ok, d} -> Date.to_iso8601(d)
             _ -> v
           end
    end
  end

  defp datetime_part(v) do
    case NaiveDateTime.from_iso8601(v) do
      {:ok, ndt} -> ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
      _ -> case Date.from_iso8601(v) do
             {:ok, d} -> Date.to_iso8601(d)
             _ -> v
           end
    end
  end

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
