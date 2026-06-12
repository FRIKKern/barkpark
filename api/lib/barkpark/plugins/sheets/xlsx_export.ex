defmodule Barkpark.Plugins.Sheets.XlsxExport do
  @moduledoc """
  Sheet-document content → xlsx binary (via `elixlsx`) — the export half of
  the Sheets plugin's conversion layer (M5).

  ## Mapping (the round-trip contract with `XlsxImport`)

    * every tab → one worksheet (name preserved, xlsx's 31-char cap applied;
      unnamed tabs become `Sheet<n>`)
    * formula cells write `<f>` (the stored `"f"`, no leading `"="`) plus
      the cached `"v"` when it is numeric — Excel recomputes on open,
      Barkpark's engine recomputes on (re-)import-save
    * `"t"` `"date"`/`"datetime"` ISO-8601 values → xlsx serials (via
      elixlsx's epoch math, which matches the 1900 system the import side
      reads); naive — any zone information was already normalized away
    * `"fmt"` → the canonical number format per class
      (`Barkpark.Plugins.Sheets.Fmt.num_format/1`); date/datetime cells
      always get a date-class format so the serial round-trips as a date
    * `"col_widths"` px → width units (px / 7 — exact inverse of import)
    * tab `"merges"` → `<mergeCells>`
    * cell `"s"` → bold / italic / solid bg fill / horizontal alignment
    * `"frozen_rows"`/`"frozen_cols"` → a frozen pane

  Error cells (`"t" => "e"`) export their error string as text. Row heights
  and `"locale"` are not represented in the export (documented; locale is a
  document-level setting with no xlsx twin).
  """

  alias Barkpark.Plugins.Sheets.Fmt
  alias Barkpark.Sheets, as: Core
  alias Elixlsx.{Sheet, Workbook}

  @px_per_width_unit 7
  @hex_color ~r/^#[0-9a-fA-F]{6}$/

  @doc """
  Build the xlsx binary for a sheet document's content.

  Returns `{:ok, binary}` or `{:error, message}` (a content shape elixlsx
  cannot encode is reported, never raised).
  """
  @spec to_binary(map(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def to_binary(content, filename \\ "sheet.xlsx") do
    tabs =
      case content do
        %{"tabs" => tabs} when is_list(tabs) -> tabs
        _ -> []
      end

    sheets =
      case tabs do
        # one empty row, not zero rows — elixlsx's row emission assumes ≥ 1
        [] -> [%Sheet{name: "Sheet1", rows: [[]]}]
        tabs -> tabs |> Enum.with_index(1) |> Enum.map(&build_sheet/1)
      end

    case Elixlsx.write_to_memory(%Workbook{sheets: sheets}, filename) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, "xlsx encode failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "xlsx encode failed: #{Exception.message(e)}"}
  end

  defp build_sheet({tab, index}) when is_map(tab) do
    cells =
      for {addr, cell} <- Map.get(tab, "cells") || %{},
          is_map(cell),
          {:ok, pos} <- [Core.parse_ref(addr)],
          do: {pos, cell}

    {max_col, max_row} =
      Enum.reduce(cells, {0, 0}, fn {{c, r}, _cell}, {mc, mr} -> {max(mc, c), max(mr, r)} end)

    by_pos = Map.new(cells)

    rows =
      case max_row do
        0 ->
          [[]]

        max_row ->
          for r <- 1..max_row do
            for c <- 1..max_col, do: encode_cell(Map.get(by_pos, {c, r}))
          end
      end

    %Sheet{
      name: sheet_name(tab, index),
      rows: rows,
      col_widths: encode_col_widths(Map.get(tab, "col_widths")),
      merge_cells: encode_merges(Map.get(tab, "merges")),
      pane_freeze: encode_pane(tab)
    }
  end

  defp build_sheet({_tab, index}), do: %Sheet{name: "Sheet#{index}", rows: []}

  defp sheet_name(tab, index) do
    case Map.get(tab, "name") do
      name when is_binary(name) and name != "" -> String.slice(name, 0, 31)
      _ -> "Sheet#{index}"
    end
  end

  # ── cells ──────────────────────────────────────────────────────────────────

  defp encode_cell(nil), do: nil

  defp encode_cell(cell) do
    props = style_props(Map.get(cell, "s")) ++ fmt_props(cell)

    case {cell_content(cell), props} do
      {nil, []} -> nil
      {nil, props} -> [:empty | props]
      {content, []} -> content
      {content, props} -> [content | props]
    end
  end

  defp cell_content(%{"f" => f} = cell) when is_binary(f) and f != "" do
    formula = f |> strip_eq() |> escape_xml()

    case Map.get(cell, "v") do
      v when is_number(v) -> {:formula, formula, value: v}
      _ -> {:formula, formula}
    end
  end

  defp cell_content(%{"t" => "date", "v" => v}) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, date} -> {Date.to_erl(date), {0, 0, 0}}
      _ -> v
    end
  end

  defp cell_content(%{"t" => "datetime", "v" => v}) when is_binary(v) do
    case parse_naive(v) do
      {:ok, ndt} -> NaiveDateTime.to_erl(ndt)
      _ -> v
    end
  end

  defp cell_content(%{"v" => v}) when is_number(v) or is_boolean(v), do: v
  defp cell_content(%{"v" => v}) when is_binary(v) and v != "", do: v
  defp cell_content(_cell), do: nil

  defp strip_eq(f) do
    case String.trim(f) do
      "=" <> rest -> rest
      other -> other
    end
  end

  # elixlsx writes `<f>` content verbatim — escape XML metacharacters here;
  # the XML parser on the consuming side restores them (round-trip safe).
  defp escape_xml(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp parse_naive(v) do
    case NaiveDateTime.from_iso8601(v) do
      {:ok, ndt} ->
        {:ok, ndt}

      _ ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _offset} -> {:ok, DateTime.to_naive(dt)}
          _ -> :error
        end
    end
  end

  # Date/datetime content MUST carry a date-class number format — elixlsx
  # only converts erlang tuples to serials when the cell style "is a date".
  defp fmt_props(%{"t" => "date"} = cell), do: [num_format: date_format(cell, "date")]
  defp fmt_props(%{"t" => "datetime"} = cell), do: [num_format: date_format(cell, "datetime")]

  defp fmt_props(cell) do
    case Fmt.num_format(Map.get(cell, "fmt")) do
      nil -> []
      format -> [num_format: format]
    end
  end

  defp date_format(cell, default) do
    fmt =
      case Map.get(cell, "fmt") do
        f when f in ["date", "datetime"] -> f
        _ -> default
      end

    Fmt.num_format(fmt)
  end

  defp style_props(%{} = s) do
    bg = Map.get(s, "bg")
    al = Map.get(s, "al")

    List.flatten([
      if(Map.get(s, "b") == true, do: [bold: true], else: []),
      if(Map.get(s, "i") == true, do: [italic: true], else: []),
      if(is_binary(bg) and Regex.match?(@hex_color, bg), do: [bg_color: bg], else: []),
      if(al in ["left", "center", "right"],
        do: [align_horizontal: String.to_existing_atom(al)],
        else: []
      )
    ])
  end

  defp style_props(_), do: []

  # ── sheet-level layout ─────────────────────────────────────────────────────

  defp encode_col_widths(widths) when is_map(widths) do
    for {key, px} <- widths,
        col = parse_col(key),
        col != nil,
        is_number(px) and px > 0,
        into: %{},
        do: {col, Float.round(px / @px_per_width_unit, 4)}
  end

  defp encode_col_widths(_), do: %{}

  defp parse_col(key) when is_integer(key) and key >= 1, do: key

  defp parse_col(key) when is_binary(key) do
    case Integer.parse(key) do
      {n, ""} when n >= 1 -> n
      _ -> nil
    end
  end

  defp parse_col(_), do: nil

  defp encode_merges(merges) when is_list(merges) do
    for m <- merges,
        is_binary(m),
        [a, b] <- [String.split(m, ":")],
        match?({:ok, _}, Core.parse_ref(a)) and match?({:ok, _}, Core.parse_ref(b)),
        do: {a, b}
  end

  defp encode_merges(_), do: []

  defp encode_pane(tab) do
    rows = frozen_int(Map.get(tab, "frozen_rows"))
    cols = frozen_int(Map.get(tab, "frozen_cols"))

    if rows > 0 or cols > 0, do: {rows, cols}, else: nil
  end

  defp frozen_int(n) when is_integer(n) and n > 0, do: n

  defp frozen_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> 0
    end
  end

  defp frozen_int(_), do: 0
end
