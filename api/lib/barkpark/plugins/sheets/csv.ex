defmodule Barkpark.Plugins.Sheets.Csv do
  @moduledoc """
  RFC-4180 CSV / TSV conversion for the Sheets plugin (M5) — VALUES ONLY by
  design: formulas export their cached value, formats / merges / styles do
  not travel (documented lossy).

  * `parse/2` — strict-enough RFC-4180: quoted fields with `""` escaping,
    `CRLF` and bare `LF`/`CR` row breaks, an unterminated quote is an
    error. The separator is `","`, `";"` or `"\\t"` (TSV is the same grammar
    with a tab separator; `";"` is the European decimal-comma dialect). A
    single leading UTF-8 BOM (`\\uFEFF`) strips — Excel's "CSV UTF-8" always
    writes one; it is encoding metadata, not content.
  * `normalize_encoding/1` — the import hygiene front door: UTF-16 (BOM-led,
    both endiannesses) transcodes to UTF-8, valid UTF-8 passes through, and
    everything else falls back to Windows-1252 → UTF-8 (Excel's "ANSI CSV").
    Only a malformed UTF-16 stream errors. Runs ONCE before any sniff/parse.
  * `sniff_separator/2` — quote-aware delimiter detection over the leading
    logical rows; picks the candidate whose per-row field count is most
    consistent, falling back to the extension default on a tie or a
    no-signal (single-column) file.
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
    comes from `Barkpark.Plugins.Sheets.Core.snapshot_for/2` — the same dense values
    projection every other read surface uses — with a frozen head row
    re-attached as the first data row. Rows join with `CRLF`; fields quote
    only when they carry the separator, a quote, or a line break.
  """

  alias Barkpark.Plugins.Sheets.Core, as: Core

  @seps [",", ";", "\t"]

  # Delimiter-sniff bounds: probe at most the first N logical rows and cap the
  # scanned prefix in bytes so a pathological single-line file can't turn the
  # sniff into unbounded parse work.
  @sniff_max_rows 20
  @sniff_byte_budget 100_000

  # Windows-1252 (Excel "ANSI CSV") 0x80–0x9F → Unicode. The 27 printable
  # positions; the 5 unassigned bytes (0x81 0x8D 0x8F 0x90 0x9D) fall through
  # to the latin1 identity below (their own C1 control codepoint).
  @cp1252_high %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  @doc "Parse delimited text into a list of string rows."
  @spec parse(String.t(), String.t()) :: {:ok, [[String.t()]]} | {:error, String.t()}
  def parse(text, sep \\ ",") when is_binary(text) and sep in @seps do
    # parse_rows/parse_quoted match on `<<char::utf8, …>>`, so a byte that is
    # not a valid UTF-8 start (e.g. 0xE9 = 'é' in Windows-1252, what Excel
    # writes on Western-European Windows) matches no clause and would raise
    # FunctionClauseError → HTTP 500. Reject invalid text up front as a clean
    # {:error, _} (the controller's wrap_convert maps it to 422 invalid_csv).
    if String.valid?(text) do
      <<sep_byte>> = sep
      parse_rows(strip_bom(text), sep_byte, "", [], [])
    else
      {:error, "input is not valid UTF-8 text"}
    end
  end

  @doc "Parse delimited text into single-tab sheet content."
  @spec import_content(String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t() | {:cell_cap_exceeded, pos_integer()}}
  def import_content(text, sep \\ ",") do
    with {:ok, rows} <- parse(text, sep),
         {:ok, cells} <- build_cells(rows, sep) do
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
  defp build_cells(rows, sep) do
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
            {:cont, {:ok, Map.put(inner, Core.format_ref({c, r}), %{"v" => infer(field, sep)})}}
          end
      end)
      |> case do
        {:ok, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Normalize an uploaded byte stream to a UTF-8 binary before any sniff/parse.

  A BOM-led UTF-16 stream (Excel's "Unicode Text (*.txt)") transcodes from the
  declared endianness; valid UTF-8 (BOM stripping stays in `parse/2`) passes
  through untouched; anything else is treated as Windows-1252 ("ANSI CSV" /
  legacy latin1) and cannot fail. Only a truncated/malformed UTF-16 stream is
  an error — the parser can then surface the clean 422 the controller maps.
  """
  @spec normalize_encoding(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_encoding(<<0xFF, 0xFE, rest::binary>>), do: from_utf16(rest, :little)
  def normalize_encoding(<<0xFE, 0xFF, rest::binary>>), do: from_utf16(rest, :big)

  def normalize_encoding(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, text}, else: {:ok, from_cp1252(text)}
  end

  defp from_utf16(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}) do
      utf8 when is_binary(utf8) -> {:ok, utf8}
      # {:error, _, _} (invalid unit) or {:incomplete, _, _} (odd byte length)
      _ -> {:error, "input is not valid UTF-8 text"}
    end
  end

  # 0x80–0x9F remap via the Windows-1252 table; every other byte (incl. the 5
  # unassigned high bytes) is its own latin1 codepoint. A codepoint list →
  # UTF-8 is total, so this branch never fails.
  defp from_cp1252(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.map(&Map.get(@cp1252_high, &1, &1))
    |> :unicode.characters_to_binary()
  end

  @doc """
  Sniff the field separator over the leading rows of `text`, returning `default`
  when no candidate carries a signal (a single-column file) or on a tie.

  For each of `","`, `";"`, `"\\t"` the quote-aware `parse/2` runs on a bounded
  prefix; the candidate is scored by `{consistency, modal_field_count}` where
  consistency is the fraction of probed rows whose field count equals the modal
  count. A candidate whose modal count is `< 2` (no split happened) scores zero.
  Ties resolve to `default` first, then the fixed order `";"` > `","` > `"\\t"`.
  """
  @spec sniff_separator(String.t(), String.t()) :: String.t()
  def sniff_separator(text, default) when is_binary(text) and default in @seps do
    prefix = text |> strip_bom() |> byte_prefix(@sniff_byte_budget)
    scores = Enum.map(@seps, fn sep -> {sep, sniff_score(prefix, sep)} end)
    best = scores |> Enum.map(&elem(&1, 1)) |> Enum.max()

    if best == {0.0, 0} do
      default
    else
      tied = for {sep, score} <- scores, score == best, do: sep
      if default in tied, do: default, else: Enum.find([";", ",", "\t"], &(&1 in tied))
    end
  end

  # {consistency, modal_field_count}; {0.0, 0} means "no usable split".
  defp sniff_score(prefix, sep) do
    case parse(prefix, sep) do
      {:ok, rows} ->
        counts = rows |> Enum.take(@sniff_max_rows) |> Enum.map(&length/1)
        modal = modal_count(counts)

        if modal < 2 do
          {0.0, 0}
        else
          {Enum.count(counts, &(&1 == modal)) / length(counts), modal}
        end

      {:error, _} ->
        {0.0, 0}
    end
  end

  defp modal_count([]), do: 0

  defp modal_count(counts) do
    counts
    |> Enum.frequencies()
    |> Enum.max_by(fn {count, freq} -> {freq, count} end)
    |> elem(0)
  end

  # A byte-bounded prefix that never ends mid-UTF-8-char (parse/2 rejects
  # invalid text, which would wrongly zero every candidate).
  defp byte_prefix(text, limit) when byte_size(text) <= limit, do: text
  defp byte_prefix(text, limit), do: trim_to_valid(binary_part(text, 0, limit))

  defp trim_to_valid(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_to_valid(binary_part(bin, 0, byte_size(bin) - 1))
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

  defp parse_quoted(<<char::utf8, rest::binary>>, acc),
    do: parse_quoted(rest, acc <> <<char::utf8>>)

  defp parse_quoted(<<>>, _acc), do: :error

  # ── value inference + quoting ──────────────────────────────────────────────

  # Type inference, in strict order:
  #   1. case-insensitive TRUE/FALSE → boolean (Excel parity; export round-trips
  #      via Core.cell_value which renders "TRUE"/"FALSE").
  #   2. a leading zero on a multi-digit run ("007", "00501", "-08") is an
  #      identifier (zip/phone/SKU), NOT a number — keep it verbatim. Real
  #      numbers "0", "0.5", "-0.7" have a non-digit right after the 0, so the
  #      guard does not match them.
  #   3. decimal-comma dialect ("1,5" → 1.5) ONLY when the file's separator is
  #      ";" — otherwise a comma is a field break and never reaches infer.
  #   4. plain integer → float → string.
  defp infer(field, sep) do
    field = strip_formula_guard(field)

    cond do
      String.upcase(field) == "TRUE" -> true
      String.upcase(field) == "FALSE" -> false
      Regex.match?(~r/^[+-]?0\d/, field) -> field
      sep == ";" and Regex.match?(~r/^-?\d+,\d+$/, field) -> decimal_comma(field)
      true -> infer_number(field)
    end
  end

  defp decimal_comma(field) do
    case field |> String.replace(",", ".") |> Float.parse() do
      {f, ""} -> f
      _ -> field
    end
  end

  defp infer_number(field) do
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
    # CSV formula-injection guard (CWE-1236): a TEXT cell whose value merely
    # LOOKS like a formula (leading `=`, `@`, or `+`) executes when the download
    # is opened in Excel/Sheets. Neutralize it with a leading apostrophe (the
    # OWASP mitigation) BEFORE the separator/quote/newline quoting runs. A
    # leading `+` also evaluates as a formula / DDE vector, and a positive
    # number never serializes with a leading `+` (`to_string(123)` = "123"), so
    # numeric cells are unaffected. `-` is deliberately NOT a trigger — it would
    # mangle legitimate negative-looking text, and negative numbers are already
    # covered by type inference; no real number ever starts with `=`/`@`/`+`.
    #
    # The guard ALSO fires when apostrophes already precede the trigger
    # (`'=x` → `''=x`): the extra marker keeps Excel's text semantics AND
    # makes `strip_formula_guard/1` (the import inverse) a true bijection —
    # without it, a stored `'=x` would export as-is and re-import as `=x`.
    field = if formula_like?(field), do: "'" <> field, else: field

    if String.contains?(field, [sep, "\"", "\n", "\r"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end

  # True when a leading run of text-marker apostrophes (possibly empty) is
  # followed by a formula trigger (`=`, `@`, `+`) — the export guard's fire
  # condition and the import strip's precondition, so the two stay inverses.
  defp formula_like?(<<trigger, _::binary>>) when trigger in [?=, ?@, ?+], do: true
  defp formula_like?(<<?', rest::binary>>), do: formula_like?(rest)
  defp formula_like?(_), do: false

  # Import-side inverse of the CSV injection guard (Excel text-marker
  # semantics: Excel strips the apostrophe on open, we must too or one
  # Barkpark→Barkpark export+import cycle permanently prepends `'` to
  # `+47 …` phone numbers and `=`-leading text). Strips exactly ONE leading
  # apostrophe when what remains is formula-like; text legitimately starting
  # with `'` followed by anything else (`'hello`) is untouched.
  defp strip_formula_guard(<<?', rest::binary>> = field) do
    if formula_like?(rest), do: rest, else: field
  end

  defp strip_formula_guard(field), do: field
end
