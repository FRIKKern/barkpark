defmodule Barkpark.Plugins.Sheets.XlsxExport do
  @moduledoc """
  Sheet-document content → xlsx binary (via `elixlsx`) — the export half of
  the Sheets plugin's conversion layer (M5).

  ## Mapping (the round-trip contract with `XlsxImport`)

    * every tab → one worksheet (name preserved, illegal `[]:*?/\` chars
      replaced with a space, xlsx's 31-char cap applied, then deduped
      case-insensitively with a ` 2`/` 3`… suffix; unnamed tabs become
      `Sheet<n>`)
    * engine function names Excel does not know are translated to their Excel
      spelling (`AVG` → `AVERAGE`); string literals are left untouched
    * formula cells write `<f>` (the stored `"f"`, no leading `"="`) plus
      the cached `"v"` when it is numeric — Excel recomputes on open,
      Barkpark's engine recomputes on (re-)import-save
    * engine-only functions with no Excel twin (`SPARKLINE`, `COUNTUNIQUE`)
      would open as `#NAME?`, so their computed value is exported as a plain
      literal instead of a formula (the CSV posture); a re-import reads a value
      cell, not the formula
    * `"t"` `"date"`/`"datetime"` ISO-8601 values → xlsx serials (via
      elixlsx's epoch math, which matches the 1900 system the import side
      reads); naive — any zone information was already normalized away
    * `"fmt"` → the canonical number format per class
      (`Barkpark.Plugins.Sheets.Fmt.num_format/1`); date/datetime cells
      always get a date-class format so the serial round-trips as a date
    * `"col_widths"` px → width units (px / 7 — exact inverse of import)
    * `"row_heights"` px → points (px × 0.75 — exact inverse of import),
      emitted as `<row ht customHeight="1">`; a height set past the last
      occupied cell extends the sheet's row extent so elixlsx still emits it
    * tab `"merges"` → `<mergeCells>`
    * cell `"s"` → bold / italic / solid bg fill / horizontal alignment
    * `"frozen_rows"`/`"frozen_cols"` → a frozen pane

  Error cells (`"t" => "e"`) export their error string as text. `"locale"`
  is not represented in the export (documented; locale is a document-level
  setting with no xlsx twin).
  """

  alias Barkpark.Plugins.Sheets.Fmt
  alias Barkpark.Plugins.Sheets.Core, as: Core
  alias Elixlsx.{Sheet, Workbook}

  @px_per_width_unit 7
  # Row heights: the model is px, xlsx wants POINTS (1px = 0.75pt at 96dpi).
  # The import half divides by the same factor, so heights round-trip.
  @pt_per_px 0.75
  @hex_color ~r/^#[0-9a-fA-F]{6}$/

  # Barkpark-engine function spellings that Excel does not recognize → the
  # Excel name. `AVG` is a Barkpark alias for `AVERAGE`; exported verbatim it
  # becomes `#NAME?` the moment Excel recalculates. `AVERAGE` is also in the
  # engine's function set, so a re-import recomputes identically.
  @dialect %{"AVG" => "AVERAGE"}

  # Barkpark-engine-only functions with NO Excel spelling: exported as a formula
  # they open as `#NAME?` and the engine's computed value (a bar string / a
  # count) is lost. Mirror the CSV posture instead — write the cached literal
  # value, dropping the `<f>`. A re-import reads a plain value cell (the formula
  # is not reconstructed), which is the documented lossy edge for these.
  @engine_only ~w(SPARKLINE COUNTUNIQUE)

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
        tabs -> tabs |> Enum.zip(export_names(tabs)) |> Enum.map(&build_sheet/1)
      end

    case Elixlsx.write_to_memory(%Workbook{sheets: sheets}, filename) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, "xlsx encode failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "xlsx encode failed: #{Exception.message(e)}"}
  end

  defp build_sheet({tab, name}) when is_map(tab) do
    cells =
      for {addr, cell} <- Map.get(tab, "cells") || %{},
          is_map(cell),
          {:ok, pos} <- [Core.parse_ref(addr)],
          do: {pos, cell}

    row_heights = encode_row_heights(Map.get(tab, "row_heights"))

    {max_col, max_row} =
      Enum.reduce(cells, {0, 0}, fn {{c, r}, _cell}, {mc, mr} -> {max(mc, c), max(mr, r)} end)

    # elixlsx only emits `<row>` up to length(rows), so a height set past the
    # last occupied cell would silently drop. Extend the row extent to the
    # highest height key BEFORE the cap so trailing-row heights survive.
    max_row = max(max_row, row_heights |> Map.keys() |> Enum.max(fn -> 0 end))

    # Hard-cap the dense grid the same way Core.snapshot_for does (two-axis:
    # columns clamp against the cap first, then rows fit under it) — a single
    # far cell like XFD1048576 would otherwise densify to ~17.2B positions and
    # OOM the node. Cells beyond the clamp fall away as nil→blank in build.
    cap = Core.position_cap()
    max_col = min(max_col, cap)
    max_row = min(max_row, max(div(cap, max(max_col, 1)), 1))

    by_pos = Map.new(cells)

    rows =
      case max_row do
        0 ->
          [[]]

        max_row ->
          # A height-only sheet (heights but no cells) has max_col 0 — emit
          # empty rows so the height attr still rides along.
          col_range = if max_col >= 1, do: 1..max_col, else: []

          for r <- 1..max_row do
            for c <- col_range, do: encode_cell(Map.get(by_pos, {c, r}))
          end
      end

    %Sheet{
      name: name,
      rows: rows,
      col_widths: encode_col_widths(Map.get(tab, "col_widths")),
      row_heights: row_heights,
      merge_cells: encode_merges(Map.get(tab, "merges")),
      pane_freeze: encode_pane(tab)
    }
  end

  defp build_sheet({_tab, name}), do: %Sheet{name: name, rows: []}

  # Worksheet names, computed up front over ALL tabs: each raw name is
  # sanitized (illegal `[]:*?/\` chars → space — Excel flags the file corrupt
  # otherwise — trimmed, de-quoted, 31-char capped; empty → `Sheet<n>`), then
  # deduped case-insensitively (Excel treats "Data"/"data" as a collision). On
  # a clash the base is re-sliced to leave room for a ` 2`/` 3`… suffix so the
  # result still fits 31 chars — without which two "Data" tabs reimport as two
  # copies of the FIRST tab (the second tab's data is lost).
  defp export_names(tabs) do
    tabs
    |> Enum.with_index(1)
    |> Enum.reduce({[], MapSet.new()}, fn {tab, i}, {acc, seen} ->
      {name, seen} = dedupe(sanitize_name(raw_name(tab), i), seen)
      {[name | acc], seen}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp raw_name(tab) when is_map(tab) do
    case Map.get(tab, "name") do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  defp raw_name(_), do: ""

  defp sanitize_name(name, index) do
    cleaned =
      name
      |> String.replace(~r/[\[\]:*?\/\\]/, " ")
      |> String.trim()
      |> String.trim("'")
      |> String.slice(0, 31)

    if cleaned == "", do: "Sheet#{index}", else: cleaned
  end

  defp dedupe(base, seen) do
    if MapSet.member?(seen, String.downcase(base)) do
      dedupe_suffix(base, seen, 2)
    else
      {base, MapSet.put(seen, String.downcase(base))}
    end
  end

  defp dedupe_suffix(base, seen, n) do
    suffix = " #{n}"
    candidate = String.slice(base, 0, 31 - String.length(suffix)) <> suffix

    if MapSet.member?(seen, String.downcase(candidate)) do
      dedupe_suffix(base, seen, n + 1)
    else
      {candidate, MapSet.put(seen, String.downcase(candidate))}
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
    if engine_only?(f) do
      cached_literal(cell)
    else
      formula = f |> strip_eq() |> translate_dialect() |> escape_xml()

      # Only a NUMERIC cached value rides alongside `<f>` — a string cached value
      # is a documented drop (an xlsx formula cell carries a numeric <v> only;
      # Excel recomputes string results on open). Engine-only functions, which
      # have no Excel spelling to recompute, are handled above as literals.
      case Map.get(cell, "v") do
        v when is_number(v) -> {:formula, formula, value: v}
        _ -> {:formula, formula}
      end
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

  # True when an engine-only function (no Excel twin) is CALLED anywhere in
  # the formula's code — not just as the leading name. Nested/compound uses
  # (`IF(A1>0,COUNTUNIQUE(…),0)`, `2*COUNTUNIQUE(…)`) exported verbatim open
  # as `#NAME?` and Excel discards the cached value. String literals are
  # excluded (the same quote split `translate_dialect/1` uses), so a quoted
  # `"COUNTUNIQUE("` does not trip it.
  @engine_only_call ~r/\b(#{Enum.join(@engine_only, "|")})\s*\(/i
  defp engine_only?(f) do
    ~r/"(?:[^"]|"")*"/
    |> Regex.split(f, include_captures: true)
    |> Enum.any?(fn
      <<?"::utf8, _rest::binary>> -> false
      segment -> Regex.match?(@engine_only_call, segment)
    end)
  end

  # The cached value of a formula cell rendered as a plain literal (numbers,
  # booleans, non-empty strings; anything else has nothing to export).
  defp cached_literal(%{"v" => v}) when is_number(v) or is_boolean(v), do: v
  defp cached_literal(%{"v" => v}) when is_binary(v) and v != "", do: v
  defp cached_literal(_cell), do: nil

  defp strip_eq(f) do
    case String.trim(f) do
      "=" <> rest -> rest
      other -> other
    end
  end

  # Translate Barkpark-engine function names to their Excel spellings, leaving
  # string literals untouched: split on quoted spans (`"…"`, with `""` escapes)
  # keeping the captures, rewrite only the code segments, rejoin.
  defp translate_dialect(f) do
    ~r/"(?:[^"]|"")*"/
    |> Regex.split(f, include_captures: true)
    |> Enum.map(&translate_segment/1)
    |> Enum.join()
  end

  defp translate_segment(<<?"::utf8, _rest::binary>> = literal), do: literal

  defp translate_segment(segment) do
    Enum.reduce(@dialect, segment, fn {from, to}, acc ->
      Regex.replace(~r/\b#{from}\s*\(/i, acc, "#{to}(")
    end)
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

  # Mirror of encode_col_widths for rows: px → points, integer keys ≥ 1.
  defp encode_row_heights(heights) when is_map(heights) do
    for {key, px} <- heights,
        row = parse_col(key),
        row != nil,
        is_number(px) and px > 0,
        into: %{},
        do: {row, Float.round(px * @pt_per_px, 2)}
  end

  defp encode_row_heights(_), do: %{}

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
