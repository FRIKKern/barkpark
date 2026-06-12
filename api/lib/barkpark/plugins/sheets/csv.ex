defmodule Barkpark.Plugins.Sheets.Csv do
  @moduledoc """
  RFC-4180 CSV / TSV conversion for the Sheets plugin (M5) — VALUES ONLY by
  design: formulas export their cached value, formats / merges / styles do
  not travel (documented lossy).

  * `parse/2` — strict-enough RFC-4180: quoted fields with `""` escaping,
    `CRLF` and bare `LF`/`CR` row breaks, an unterminated quote is an
    error. The separator is `","` or `"\\t"` (TSV is the same grammar with
    a tab separator). A single leading UTF-8 BOM (`\\uFEFF`) strips —
    Excel's "CSV UTF-8" always writes one; it is encoding metadata, not
    content.
  * `import_content/2` — one tab (`"Sheet1"`). Empty fields skip; other
    fields type-infer integer → float → string. Content beyond the Excel
    grid bounds clips first — fields past column XFD/16,384 and lines past
    row 1,048,576 drop (documented lossy) — so an import is always legal
    for the `before_save` gate. The non-empty-cell cap
    (`Barkpark.Plugins.Sheets.cell_cap/0`) enforces incrementally — the
    fold halts with `{:error, {:cell_cap_exceeded, count}}` (the true
    running count at the halt) the moment the running count exceeds the
    cap, never building the rest.
  * `export/3` — one tab per call (the route's `?tab=` selector). The grid
    comes from `Barkpark.Sheets.snapshot_for/2` — the same dense values
    projection every other read surface uses — with a frozen head row
    re-attached as the first data row. Rows join with `CRLF`; fields quote
    only when they carry the separator, a quote, or a line break.
  """

  alias Barkpark.Sheets, as: Core

  @seps [",", "\t"]

  @doc "Parse delimited text into a list of string rows."
  @spec parse(String.t(), String.t()) :: {:ok, [[String.t()]]} | {:error, String.t()}
  def parse(text, sep \\ ",") when is_binary(text) and sep in @seps do
    <<sep_byte>> = sep
    parse_rows(strip_bom(text), sep_byte, "", [], [])
  end

  @doc "Parse delimited text into single-tab sheet content."
  @spec import_content(String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t() | {:cell_cap_exceeded, pos_integer()}}
  def import_content(text, sep \\ ",") do
    with {:ok, rows} <- parse(text, sep),
         {:ok, cells} <- build_cells(rows) do
      tab =
        if cells == %{},
          do: %{"name" => "Sheet1"},
          else: %{"name" => "Sheet1", "cells" => cells}

      {:ok, %{"tabs" => [tab]}}
    end
  end

  # Every entry in the cells map is non-empty by construction, so map_size
  # IS the running non-empty-cell count — the fold halts the moment one
  # more cell would exceed the cap, reporting the true running count at
  # the halt (the same shape XlsxImport reports). Lines and fields beyond
  # the Excel grid bounds clip first, keeping the import gate-legal.
  defp build_cells(rows) do
    cap = Barkpark.Plugins.Sheets.cell_cap()
    max_col = Barkpark.Plugins.Sheets.grid_max_col()

    rows
    |> Enum.take(Barkpark.Plugins.Sheets.grid_max_row())
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {row, r}, {:ok, acc} ->
      row
      |> Enum.take(max_col)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, acc}, fn
        {"", _c}, inner ->
          {:cont, inner}

        {field, c}, {:ok, inner} ->
          if map_size(inner) >= cap do
            {:halt, {:error, {:cell_cap_exceeded, map_size(inner) + 1}}}
          else
            {:cont, {:ok, Map.put(inner, Core.format_ref({c, r}), %{"v" => infer(field)})}}
          end
      end)
      |> case do
        {:ok, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Export one tab of sheet content as delimited text."
  @spec export(map(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, :tab_not_found}
  def export(content, tab_index \\ 0, sep \\ ",") when sep in @seps do
    case Core.get_tab(content, tab_index) do
      nil ->
        {:error, :tab_not_found}

      _tab ->
        snapshot = Core.snapshot_for(content, tab_index)

        grid =
          case Map.get(snapshot, "head") do
            head when is_list(head) -> [head | Map.get(snapshot, "rows", [])]
            _ -> Map.get(snapshot, "rows", [])
          end

        lines = Enum.map(grid, fn row -> Enum.map_join(row, sep, &quote_field(&1, sep)) end)

        case lines do
          [] -> {:ok, ""}
          lines -> {:ok, Enum.join(lines, "\r\n") <> "\r\n"}
        end
    end
  end

  # ── parser ─────────────────────────────────────────────────────────────────

  # A single leading UTF-8 BOM (0xEF 0xBB 0xBF — Excel "CSV UTF-8" always
  # writes one) is encoding metadata, not content: strip it so A1 stays
  # clean and a quoted first field still opens.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  defp parse_rows(<<>>, _sep, field, row, rows) do
    rows =
      if field == "" and row == [] do
        rows
      else
        [Enum.reverse([field | row]) | rows]
      end

    {:ok, Enum.reverse(rows)}
  end

  # A quote OPENS a quoted field only at field start; mid-field quotes are
  # taken literally (lenient, like most real-world readers).
  defp parse_rows(<<?", rest::binary>>, sep, "", row, rows) do
    case parse_quoted(rest, "") do
      {:ok, field, rest2} -> parse_rows_after_quoted(rest2, sep, field, row, rows)
      :error -> {:error, "unterminated quoted field"}
    end
  end

  defp parse_rows(<<byte, rest::binary>>, sep, field, row, rows) when byte == sep,
    do: parse_rows(rest, sep, "", [field | row], rows)

  defp parse_rows(<<"\r\n", rest::binary>>, sep, field, row, rows),
    do: parse_rows(rest, sep, "", [], [Enum.reverse([field | row]) | rows])

  defp parse_rows(<<"\n", rest::binary>>, sep, field, row, rows),
    do: parse_rows(rest, sep, "", [], [Enum.reverse([field | row]) | rows])

  defp parse_rows(<<"\r", rest::binary>>, sep, field, row, rows),
    do: parse_rows(rest, sep, "", [], [Enum.reverse([field | row]) | rows])

  defp parse_rows(<<char::utf8, rest::binary>>, sep, field, row, rows),
    do: parse_rows(rest, sep, field <> <<char::utf8>>, row, rows)

  # After a closing quote the next byte should be a separator, a row break
  # or EOF; stray trailing characters append to the field (lenient).
  defp parse_rows_after_quoted(rest, sep, field, row, rows) do
    case rest do
      <<>> -> {:ok, Enum.reverse([Enum.reverse([field | row]) | rows])}
      <<byte, rest2::binary>> when byte == sep -> parse_rows(rest2, sep, "", [field | row], rows)
      <<"\r\n", rest2::binary>> -> end_row(rest2, sep, field, row, rows)
      <<"\n", rest2::binary>> -> end_row(rest2, sep, field, row, rows)
      <<"\r", rest2::binary>> -> end_row(rest2, sep, field, row, rows)
      <<char::utf8, rest2::binary>> -> parse_rows(rest2, sep, field <> <<char::utf8>>, row, rows)
    end
  end

  defp end_row(rest, sep, field, row, rows),
    do: parse_rows(rest, sep, "", [], [Enum.reverse([field | row]) | rows])

  defp parse_quoted(<<?", ?", rest::binary>>, acc), do: parse_quoted(rest, acc <> "\"")
  defp parse_quoted(<<?", rest::binary>>, acc), do: {:ok, acc, rest}
  defp parse_quoted(<<char::utf8, rest::binary>>, acc), do: parse_quoted(rest, acc <> <<char::utf8>>)
  defp parse_quoted(<<>>, _acc), do: :error

  # ── value inference + quoting ──────────────────────────────────────────────

  defp infer(field) do
    case Integer.parse(field) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(field) do
          {f, ""} -> f
          _ -> field
        end
    end
  end

  defp quote_field(field, sep) do
    if String.contains?(field, [sep, "\"", "\n", "\r"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end
end
