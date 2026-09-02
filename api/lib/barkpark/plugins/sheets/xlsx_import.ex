defmodule Barkpark.Plugins.Sheets.XlsxImport do
  @moduledoc """
  xlsx binary → sheet-document content (`%{"tabs" => […]}`) — the import
  half of the Sheets plugin's conversion layer (M5).

  Two readers over the same bytes:

    * `XlsxReader` (cell mode) supplies VALUES + FORMULAS per A1 ref —
      shared strings resolved, recognized date formats already converted
      to `Date`/`NaiveDateTime`.
    * a thin Saxy pass over the package XML supplies what the library does
      not expose: per-cell style indexes (→ `fmt` class + `s` basic style),
      column widths, merged ranges, and frozen panes.

  ## Mapping

    * every worksheet → one tab, in workbook order, name preserved
    * values: numbers (floats normalized to ints when exact), strings,
      booleans; date/datetime cells → ISO-8601 strings with `"t"`
      `"date"`/`"datetime"` (serials converted against the workbook's
      epoch — 1900 or 1904 system). Datetimes are NAIVE — xlsx has no
      timezone, so a trailing offset never appears.
    * formulas → `"f"` (any leading `"="` stripped — the canonical stored
      form); a numeric cached value rides along as `"v"`. The save path
      runs `Barkpark.Plugins.Sheets.Engine.recompute/1`, which keeps the file's
      cached value and flags `"stale" => true` for functions the engine
      does not know (bound grill decision). Excel SHARED formulas (a filled
      column) are rebased per follower against the master's offset so each
      follower carries its OWN formula, not the master's verbatim text —
      otherwise recompute would overwrite every follower's correct value.
    * number formats → `"fmt"` hints via `Barkpark.Plugins.Sheets.Fmt`
    * column widths → `"col_widths"` (px ≈ width-units × 7, the xlsx
      character-width convention; the export half divides by the same
      factor, so widths round-trip exactly)
    * row heights → `"row_heights"` (px = round(pt ÷ 0.75), the point↔px
      convention at 96dpi; ONLY `<row>`s carrying `customHeight="1"` are
      read — an auto-fit row without it keeps our default, a documented
      drop; the export half multiplies by 0.75, so heights round-trip)
    * merged ranges → tab `"merges"` (`["A1:B2", …]`), sanitized: each
      range clips to the tab's occupied bounds, then drops when its
      clipped area exceeds `Barkpark.Plugins.Sheets.merge_area_cap/0`
      cells or collapses to a single cell — a hostile `mergeCell` can
      never widen the dense snapshot grid
    * basic styles → cell `"s"`: bold / italic / solid-fill bg
      (normalized to lowercase `#rrggbb`) / horizontal alignment
      (left|center|right)
    * frozen panes → `"frozen_rows"` / `"frozen_cols"`
    * tab color → tab `"color"`: a `<sheetPr><tabColor rgb="AARRGGBB"/>` maps to
      lowercase `#rrggbb` (the `FF` alpha dropped); only an explicit `rgb=`
      round-trips — a theme/indexed tabColor is ignored (the v1 cap)
    * `<conditionalFormatting>`/`<cfRule>` → tab `"cond_formats"` (CF-X), in
      `<cfRule priority>` order, each in `CondFormat`'s canonical stored shape
      (`id`/`range`/`when`/`style`). `cellIs` with `greaterThan`/`lessThan`/
      `equal`/`between` maps to `gt`/`lt`/`eq`/`between`, `containsText` to
      `contains`; the `when` value(s) are decoded from the `<formula>` children
      as TYPED xlsx literals (a bare number → a number, `"…"` → a string,
      `TRUE`/`FALSE` → a boolean), so `XlsxExport`'s rules come back
      byte-identical. The rule's `style` comes from the `<dxf>` its `dxfId`
      points at (bold / italic / a solid `bgColor` or `fgColor` → `#rrggbb`).
      The stored `"id"` rides in `<cfRule><extLst>` on a Barkpark-written file;
      a FOREIGN file has none, so the import synthesizes a per-tab-unique
      `cf<N>` (the storage gate requires an id — a rule it would reject is
      worse than a synthesized name). Every candidate rule is then run past
      that gate (`Barkpark.Plugins.Sheets.cond_format_list_errors/2`) and the
      list deduped by range/id and cut to `cond_format_cap/0`, so an import can
      never produce cond_formats the save path would 409 on.

  ## Dropped on import (documented, never an error)

  Charts, pivot tables, images, data validation — plus the conditional-format
  rule KINDS Barkpark has no model for (`colorScale`, `dataBar`, `iconSet`,
  `expression`, `top10`, …, and any `cellIs`/`containsText` rule whose formula
  is not a plain literal — a cell reference, an expression): an unknown
  `cfRule` is skipped, never an import error. Also dropped:
  auto-fit row heights (a `<row>` without `customHeight="1"`),
  fonts beyond bold/italic, borders, theme/indexed fill
  colors, number formats outside the `Fmt` vocabulary, merged ranges
  that exceed the area cap after clipping (dropped deterministically),
  and cells addressed beyond the Excel grid bounds (column XFD/16,384,
  row 1,048,576 — Excel itself cannot write one, only a hand-crafted
  package can; dropping them keeps the import legal for the
  `before_save` gate).
  `"t"` on plain literals is normalized away (the JSON value type carries
  it); only `"date"`/`"datetime"` literals keep a `"t"`.

  The non-empty-cell cap (`Barkpark.Plugins.Sheets.cell_cap/0`) enforces
  incrementally across all tabs — the fold halts with
  `{:error, {:cell_cap_exceeded, count}}` the moment the running count
  exceeds the cap, never building the rest.

  ## Resource-exhaustion posture (xlsx decompression bombs)

  An xlsx IS a zip archive, and both readers over the bytes — `XlsxReader.open`
  (`open_package/1`) and the raw `:zip.extract(binary, [:memory])` in
  `parse_layout/1` — FULLY inflate the members they touch into RAM. That inflate
  runs UPSTREAM of every cell/merge/grid cap: a 1.45 MiB archive can materialise
  ~400 MiB before `cell_cap/0` is ever consulted, and the import controller's
  15 MB byte cap bounds only the COMPRESSED on-disk size. So `to_content/1`
  carries an explicit **pre-extract decompressed-size ceiling** — the twin of
  `Barkpark.Media.ImageBackend.Vix`'s `guard_dimensions/1` for images. The
  MECHANISM: `:zip.list_dir/1` reports each member's declared UNCOMPRESSED size
  straight from the central directory WITHOUT inflating anything, so the guard
  sums those declared sizes and rejects up front with
  `{:error, :xlsx_decompressed_size_exceeded}` when the total exceeds the
  ceiling — BEFORE `open_package/1` (covering a bomb hidden in a member
  `XlsxReader` itself reads, e.g. a huge `xl/sharedStrings.xml`) and before the
  raw extract in `parse_layout/1`. The ceiling defaults to 256 MiB and is
  overridable per-env via
  `config :barkpark, Barkpark.Plugins.Sheets.XlsxImport, max_decompressed_bytes: N`.
  """

  alias Barkpark.Plugins.Sheets.Fmt
  alias Barkpark.Plugins.Sheets.Core, as: SheetCore
  alias XlsxReader.Cell

  # Pre-extract ceiling on the SUM of every member's declared uncompressed size,
  # read from the zip central directory (no inflate). Both inflate vectors
  # (`open_package/1` and `parse_layout/1`'s `:zip.extract`) run past every
  # cell/merge/grid cap, so this fails closed on a decompression bomb before any
  # member is materialised. Mirrors Magick's `-limit memory 256MiB` and the Vix
  # backend's `@default_max_decode_bytes`. Overridable per-env for tests via
  # `config :barkpark, __MODULE__, max_decompressed_bytes: N`.
  @default_max_decompressed_bytes 256 * 1024 * 1024

  # xlsx column widths are in "character" units; Excel's default char is
  # ~7px. round(px / 7 * 7) is exact for integers, so widths round-trip.
  @px_per_width_unit 7

  # xlsx row heights are in POINTS, the model is px: 1px = 0.75pt (96dpi
  # over 72pt/in). px = round(ht / 0.75) is exact for the integer px the
  # export half emits, so heights round-trip.
  @pt_per_px 0.75

  @epoch_1900 ~D[1899-12-30]
  @epoch_1904 ~D[1904-01-01]

  @doc """
  Convert an xlsx binary to sheet-document content.

  Returns `{:ok, %{"tabs" => […]}}` or `{:error, message}`.
  """
  @spec to_content(binary()) ::
          {:ok, map()}
          | {:error,
             String.t()
             | {:cell_cap_exceeded, pos_integer()}
             | :xlsx_decompressed_size_exceeded}
  def to_content(binary) when is_binary(binary) do
    with :ok <- guard_decompressed_size(binary),
         {:ok, package} <- open_package(binary),
         {:ok, layout} <- parse_layout(binary) do
      package
      |> XlsxReader.sheet_names()
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], 0}, fn {name, index}, {:ok, acc, count} ->
        case XlsxReader.sheet(package, name, cell_data_format: :cell) do
          {:ok, rows} ->
            # Attach layout by workbook POSITION, not by name: two tabs that
            # share a name (or collide after the 31-char slice) must not both
            # fold onto the FIRST tab's styles/merges/widths. XlsxReader.sheet/3
            # is still name-addressed, so a FOREIGN duplicate-name package stays
            # ambiguous THERE (the first match's cells win) — acceptable, since
            # Excel/LibreOffice cannot author one and the export side now
            # sanitizes + dedupes names so neither can we.
            sheet_layout = Enum.at(layout.sheets, index)

            case build_tab(name, rows, sheet_layout, layout, count) do
              {:ok, tab, count} -> {:cont, {:ok, [tab | acc], count}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, reason} ->
            {:halt, {:error, "could not read sheet #{inspect(name)}: #{inspect(reason)}"}}
        end
      end)
      |> case do
        {:ok, tabs, _count} -> {:ok, %{"tabs" => Enum.reverse(tabs)}}
        {:error, _} = error -> error
      end
    end
  end

  # xlsx_reader's zip-error translation is not total — hand-crafted garbage
  # bytes can raise out of :zip instead of returning {:error, _}. Rescue to
  # the same clean error either way.
  defp open_package(binary) do
    case XlsxReader.open(binary, source: :binary) do
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, "invalid xlsx: #{inspect(reason)}"}
    end
  rescue
    _ -> {:error, "invalid xlsx: not an xlsx package"}
  end

  # Pre-extract decompression-bomb guard: sum every member's DECLARED
  # uncompressed size from the zip central directory — `:zip.list_dir/1` reads
  # only the directory, it does NOT inflate — and reject before any member is
  # materialised when the total exceeds the ceiling. Sits ahead of BOTH inflate
  # vectors (`open_package/1` and `parse_layout/1`). A binary whose central
  # directory does not read as a zip is NOT rejected here — `:ok` lets
  # `open_package/1` produce the canonical `"invalid xlsx"` error instead of
  # masking a plain not-a-zip as a size violation.
  defp guard_decompressed_size(binary) do
    case :zip.list_dir(binary) do
      {:ok, entries} ->
        if declared_uncompressed_bytes(entries) > max_decompressed_bytes() do
          {:error, :xlsx_decompressed_size_exceeded}
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # `:zip.list_dir/1` yields `{:zip_comment, _}` plus one
  # `{:zip_file, name, file_info, comment, offset, comp_size}` per member;
  # `elem(file_info, 1)` is the uncompressed size record field.
  defp declared_uncompressed_bytes(entries) do
    Enum.reduce(entries, 0, fn
      {:zip_file, _name, file_info, _comment, _offset, _comp}, acc ->
        acc + uncompressed_size(file_info)

      _entry, acc ->
        acc
    end)
  end

  defp uncompressed_size(file_info) do
    case elem(file_info, 1) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  defp max_decompressed_bytes do
    :barkpark
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_decompressed_bytes, @default_max_decompressed_bytes)
  end

  # ── tab assembly ───────────────────────────────────────────────────────────

  defp build_tab(name, rows, sheet_layout, layout, count) do
    sheet_layout = sheet_layout || %{}
    cell_xfs = Map.get(sheet_layout, :cell_styles, %{})
    masters = Map.get(sheet_layout, :shared_masters, %{})
    followers = Map.get(sheet_layout, :shared_followers, %{})
    cap = Barkpark.Plugins.Sheets.cell_cap()

    rows
    |> List.flatten()
    |> Enum.reduce_while({%{}, count}, fn
      # Padding for omitted cells/rows is the raw blank_value (""), only
      # real cells arrive as Cell structs with a ref.
      %Cell{ref: ref} = cell, {acc, count} when is_binary(ref) ->
        override = shared_formula(ref, followers, masters)

        case build_cell(cell, Map.get(cell_xfs, ref), layout.date_base, override) do
          nil ->
            {:cont, {acc, count}}

          built ->
            count = count + non_empty(built)

            if count > cap do
              {:halt, {:error, {:cell_cap_exceeded, count}}}
            else
              {:cont, {Map.put(acc, ref, built), count}}
            end
        end

      _blank, acc_count ->
        {:cont, acc_count}
    end)
    |> case do
      {:error, _} = error ->
        error

      {cells, count} ->
        tab =
          %{"name" => name}
          |> put_unless_empty("cells", cells)
          |> put_unless_empty("col_widths", Map.get(sheet_layout, :col_widths, %{}))
          |> put_unless_empty("row_heights", Map.get(sheet_layout, :row_heights, %{}))
          |> put_unless_empty(
            "merges",
            sanitize_merges(Map.get(sheet_layout, :merges, []), cells)
          )
          |> put_unless_empty("cond_formats", Map.get(sheet_layout, :cond_formats, []))
          |> put_frozen("frozen_rows", Map.get(sheet_layout, :frozen_rows, 0))
          |> put_frozen("frozen_cols", Map.get(sheet_layout, :frozen_cols, 0))
          |> put_color(Map.get(sheet_layout, :tab_color))

        {:ok, tab, count}
    end
  end

  # Mirrors the import controller's non-empty predicate: a counted cell
  # carries a non-empty value or a formula (style-only cells are free).
  defp non_empty(built) do
    if Map.get(built, "v") not in [nil, ""] or is_binary(Map.get(built, "f")), do: 1, else: 0
  end

  # Hostile or sloppy mergeCell ranges must never leave the import wider
  # than the data: clip each range to the tab's occupied bounds, then drop
  # any range whose clipped area still exceeds the merge-area cap — and any
  # range that clips down to a single cell (it carries no information).
  defp sanitize_merges([], _cells), do: []

  defp sanitize_merges(merges, cells) do
    area_cap = Barkpark.Plugins.Sheets.merge_area_cap()

    {max_col, max_row} =
      Enum.reduce(cells, {0, 0}, fn {ref, _cell}, {mc, mr} ->
        case SheetCore.parse_ref(ref) do
          {:ok, {c, r}} -> {max(mc, c), max(mr, r)}
          :error -> {mc, mr}
        end
      end)

    Enum.flat_map(merges, fn merge ->
      with [a, b] <- String.split(merge, ":"),
           {:ok, {c1, r1}} <- SheetCore.parse_ref(a),
           {:ok, {c2, r2}} <- SheetCore.parse_ref(b) do
        {c1, c2} = {min(c1, c2), min(max(c1, c2), max_col)}
        {r1, r2} = {min(r1, r2), min(max(r1, r2), max_row)}
        area = (c2 - c1 + 1) * (r2 - r1 + 1)

        if c1 > c2 or r1 > r2 or area <= 1 or area > area_cap do
          []
        else
          [SheetCore.format_ref({c1, r1}) <> ":" <> SheetCore.format_ref({c2, r2})]
        end
      else
        _ -> []
      end
    end)
  end

  defp put_unless_empty(map, _key, empty) when empty == %{} or empty == [], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_frozen(map, key, n) when is_integer(n) and n > 0, do: Map.put(map, key, n)
  defp put_frozen(map, _key, _n), do: map

  # The tab's `<sheetPr><tabColor>` color, already normalized to `#rrggbb` by
  # `parse_tab_color/1` (or nil when absent / theme-indexed).
  defp put_color(map, color) when is_binary(color), do: Map.put(map, "color", color)
  defp put_color(map, _color), do: map

  # A ref beyond the Excel grid bounds drops like any other unrepresentable
  # feature (see the moduledoc) — `if` without `else` yields nil, the same
  # "no cell" the callers already handle.
  defp build_cell(%Cell{} = cell, xf, date_base, formula_override) do
    if in_grid?(cell.ref), do: do_build_cell(cell, xf, date_base, formula_override)
  end

  # Excel fills a column down as a SHARED formula: the master cell carries the
  # `<f t="shared" si="N" ref=…>` text, every follower an empty `<f t="shared"
  # si="N"/>`. XlsxReader hands each follower the master's VERBATIM (unshifted)
  # text — so C2 imports as `SUM(A1:B1)` instead of `SUM(A2:B2)`, and the
  # always-run recompute then overwrites the follower's correct cached value.
  # Rebase the master's text by the follower's offset (`$`-anchor aware) so the
  # follower carries its OWN formula and recompute reproduces its cached value.
  defp shared_formula(ref, followers, masters) do
    with si when is_binary(si) <- Map.get(followers, ref),
         {master_ref, master_text} <- Map.get(masters, si),
         {:ok, {mc, mr}} <- SheetCore.parse_ref(master_ref),
         {:ok, {c, r}} <- SheetCore.parse_ref(ref) do
      Barkpark.Plugins.Sheets.Structure.rebase_formula(master_text, c - mc, r - mr)
    else
      _ -> nil
    end
  end

  defp in_grid?(ref) do
    case SheetCore.parse_ref(ref) do
      {:ok, {col, row}} ->
        col <= Barkpark.Plugins.Sheets.grid_max_col() and
          row <= Barkpark.Plugins.Sheets.grid_max_row()

      :error ->
        false
    end
  end

  defp do_build_cell(%Cell{} = cell, xf, date_base, formula_override) do
    fmt = xf && xf.fmt
    style = (xf && xf.style) || %{}

    {v, t, fmt} = convert_value(cell.value, fmt, date_base)

    built =
      %{}
      |> maybe_put("v", v)
      |> maybe_put("t", t)
      |> maybe_put("f", formula_override || normalize_formula(cell.formula))
      |> maybe_put("fmt", fmt)
      |> put_unless_empty("s", style)

    if built == %{}, do: nil, else: built
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_formula(f) when is_binary(f) and f != "" do
    case String.trim(f) do
      "=" <> rest -> rest
      other -> other
    end
  end

  defp normalize_formula(_), do: nil

  # value (+ fmt class) → {v, t, fmt}. xlsx_reader converts serials it
  # recognizes itself; serials under formats it does not recognize arrive
  # as numbers and convert here against the fmt class.
  defp convert_value(%Date{} = d, fmt, _base),
    do: {Date.to_iso8601(d), "date", fmt || "date"}

  defp convert_value(%NaiveDateTime{} = ndt, fmt, _base),
    do: {NaiveDateTime.to_iso8601(ndt), "datetime", fmt || "datetime"}

  defp convert_value(%DateTime{} = dt, fmt, _base),
    do: {dt |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(), "datetime", fmt || "datetime"}

  defp convert_value(n, "date", base) when is_number(n) and n >= 0,
    do: {base |> Date.add(trunc(n)) |> Date.to_iso8601(), "date", "date"}

  defp convert_value(n, "datetime", base) when is_number(n) and n >= 0 do
    days = trunc(n)
    seconds = round((n - days) * 86_400)

    iso =
      base
      |> Date.add(days)
      |> NaiveDateTime.new!(~T[00:00:00])
      |> NaiveDateTime.add(seconds, :second)
      |> NaiveDateTime.to_iso8601()

    {iso, "datetime", "datetime"}
  end

  defp convert_value(n, fmt, _base) when is_number(n), do: {normalize_number(n), nil, fmt}
  defp convert_value(b, fmt, _base) when is_boolean(b), do: {b, nil, fmt}
  defp convert_value("", fmt, _base), do: {nil, nil, fmt}
  defp convert_value(s, fmt, _base) when is_binary(s), do: {s, nil, fmt}
  defp convert_value(other, fmt, _base), do: {to_string(other), nil, fmt}

  # Floats that are exactly integral normalize to ints (xlsx stores every
  # number as a double; "2" must come back as 2, not 2.0).
  defp normalize_number(n) when is_float(n) do
    if n == trunc(n) and abs(n) < 1.0e15, do: trunc(n), else: n
  end

  defp normalize_number(n), do: n

  # ── package-XML layout parse (Saxy over the raw zip) ───────────────────────
  #
  # Everything XlsxReader does not expose: workbook sheet order + rels,
  # styles.xml (numFmts / fonts / fills / cellXfs), and per-worksheet cols,
  # mergeCells, frozen panes, and per-cell style indexes.

  defp parse_layout(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, entries} ->
        files = Map.new(entries, fn {name, content} -> {to_string(name), content} end)
        workbook = simple_form(files["xl/workbook.xml"])
        rels = parse_rels(simple_form(files["xl/_rels/workbook.xml.rels"]))
        styles = simple_form(files["xl/styles.xml"])
        xfs = parse_styles(styles)
        dxfs = parse_dxfs(styles)
        date_base = if date_1904?(workbook), do: @epoch_1904, else: @epoch_1900

        # An ORDERED list in workbook order — `to_content` attaches it to the
        # matching XlsxReader.sheet_names/1 entry by position, so duplicate tab
        # names never collapse two tabs' layouts onto one.
        sheets =
          workbook
          |> workbook_sheets()
          |> Enum.map(fn {_name, rid} ->
            xml = files[resolve_target(Map.get(rels, rid))]
            parse_worksheet(simple_form(xml), xfs, dxfs)
          end)

        {:ok, %{sheets: sheets, date_base: date_base}}

      {:error, reason} ->
        {:error, "invalid xlsx: #{inspect(reason)}"}
    end
  rescue
    # :zip.extract eagerly full-inflates each member, so a package that opens
    # under XlsxReader but carries a corrupt deflate stream (or garbage the
    # zip-error translation misses) raises out of :zip instead of returning
    # {:error, _}. Rescue to the same clean error either way — mirrors
    # open_package/1.
    _ -> {:error, "invalid xlsx: not an xlsx package"}
  end

  defp simple_form(nil), do: nil

  defp simple_form(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, element} -> element
      _ -> nil
    end
  end

  # Local (prefix-stripped) element/attribute name matching — real-world
  # producers vary the namespace prefixes.
  defp local(name), do: name |> String.split(":") |> List.last()

  defp children_named(nil, _name), do: []

  defp children_named({_n, _attrs, children}, name) do
    Enum.filter(children, fn
      {n, _, _} -> local(n) == name
      _ -> false
    end)
  end

  defp child_named(element, name), do: element |> children_named(name) |> List.first()

  defp attr(nil, _name), do: nil

  defp attr({_n, attrs, _c}, name) do
    Enum.find_value(attrs, fn {k, v} -> if local(k) == name, do: v end)
  end

  defp to_int(nil), do: nil

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_num(nil), do: nil

  defp to_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp date_1904?(workbook) do
    (workbook |> child_named("workbookPr") |> attr("date1904")) in ["1", "true"]
  end

  defp workbook_sheets(workbook) do
    for sheet <- workbook |> child_named("sheets") |> children_named("sheet"),
        name = attr(sheet, "name"),
        rid = attr(sheet, "id"),
        is_binary(name) and is_binary(rid),
        do: {name, rid}
  end

  defp parse_rels(rels_root) do
    for rel <- children_named(rels_root, "Relationship"),
        id = attr(rel, "Id"),
        target = attr(rel, "Target"),
        is_binary(id) and is_binary(target),
        into: %{},
        do: {id, target}
  end

  defp resolve_target(nil), do: nil

  defp resolve_target(target) do
    t = String.trim_leading(target, "/")
    if String.starts_with?(t, "xl/"), do: t, else: "xl/" <> t
  end

  # styles.xml → cellXfs as a list of %{fmt:, style:} (indexed by the
  # worksheet cells' `s` attribute).
  defp parse_styles(nil), do: []

  defp parse_styles(root) do
    custom_formats =
      for nf <- root |> child_named("numFmts") |> children_named("numFmt"),
          id = attr(nf, "numFmtId"),
          code = attr(nf, "formatCode"),
          is_binary(id) and is_binary(code),
          into: %{},
          do: {id, code}

    fonts =
      for font <- root |> child_named("fonts") |> children_named("font") do
        %{b: font_flag?(font, "b"), i: font_flag?(font, "i")}
      end

    fills =
      for fill <- root |> child_named("fills") |> children_named("fill"), do: fill_bg(fill)

    for xf <- root |> child_named("cellXfs") |> children_named("xf") do
      %{
        fmt: Fmt.classify(attr(xf, "numFmtId"), custom_formats),
        style: xf_style(xf, fonts, fills)
      }
    end
  end

  defp font_flag?(font, name) do
    case child_named(font, name) do
      nil -> false
      flag -> attr(flag, "val") not in ["0", "false"]
    end
  end

  # Only an explicit solid patternFill with an rgb fgColor maps to "bg" —
  # theme/indexed colors are dropped (documented). ARGB → lowercase #rrggbb.
  defp fill_bg(fill) do
    with pattern_fill when pattern_fill != nil <- child_named(fill, "patternFill"),
         "solid" <- attr(pattern_fill, "patternType"),
         fg_color when fg_color != nil <- child_named(pattern_fill, "fgColor"),
         rgb when is_binary(rgb) and byte_size(rgb) >= 6 <- attr(fg_color, "rgb") do
      "#" <> (rgb |> String.slice(-6, 6) |> String.downcase())
    else
      _ -> nil
    end
  end

  defp xf_style(xf, fonts, fills) do
    font = Enum.at(fonts, to_int(attr(xf, "fontId")) || 0) || %{b: false, i: false}
    bg = Enum.at(fills, to_int(attr(xf, "fillId")) || 0)

    al =
      case xf |> child_named("alignment") |> attr("horizontal") do
        h when h in ["left", "center", "right"] -> h
        _ -> nil
      end

    %{}
    |> put_if(font.b, "b", true)
    |> put_if(font.i, "i", true)
    |> put_if(is_binary(bg), "bg", bg)
    |> put_if(is_binary(al), "al", al)
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _cond, _key, _value), do: map

  # One worksheet's layout: per-cell xf lookup, col widths, merges, panes.
  defp parse_worksheet(nil, _xfs, _dxfs), do: %{}

  defp parse_worksheet(root, xfs, dxfs) do
    rows = root |> child_named("sheetData") |> children_named("row")

    cell_styles =
      for row <- rows,
          c <- children_named(row, "c"),
          ref = attr(c, "r"),
          is_binary(ref),
          xf = Enum.at(xfs, to_int(attr(c, "s")) || 0),
          xf != nil,
          xf.fmt != nil or xf.style != %{},
          into: %{},
          do: {ref, xf}

    # Shared formulas: the master `<f t="shared" si=N ref=…>TEXT</f>` seeds
    # `si → {master_ref, text}`; each empty follower `<f t="shared" si=N/>`
    # seeds `follower_ref → si`. `build_tab` rebases the master text by the
    # follower's offset (see `shared_formula/3`).
    shared_masters =
      for row <- rows,
          c <- children_named(row, "c"),
          ref = attr(c, "r"),
          is_binary(ref),
          f = child_named(c, "f"),
          f != nil,
          attr(f, "t") == "shared",
          si = attr(f, "si"),
          is_binary(si),
          text = element_text(f),
          text != "",
          into: %{},
          do: {si, {ref, text}}

    shared_followers =
      for row <- rows,
          c <- children_named(row, "c"),
          ref = attr(c, "r"),
          is_binary(ref),
          f = child_named(c, "f"),
          f != nil,
          attr(f, "t") == "shared",
          si = attr(f, "si"),
          is_binary(si),
          element_text(f) == "",
          into: %{},
          do: {ref, si}

    # `<col min max>` is attacker-controlled: an unbounded `max` (e.g.
    # 2_000_000_000) would build a ~2-billion-entry map here — a whole-BEAM
    # OOM bomb that runs before the cell_cap. Clamp both ends to the Excel
    # grid; `Kernel.max(min)` keeps a hostile `max < min` from producing a
    # descending range.
    col_widths =
      for col <- root |> child_named("cols") |> children_named("col"),
          w = to_num(attr(col, "width")),
          w != nil and w > 0,
          min = to_int(attr(col, "min")),
          min != nil,
          min >= 1 and min <= Barkpark.Plugins.Sheets.grid_max_col(),
          hi =
            (case to_int(attr(col, "max")) do
               nil -> min
               m -> m |> Kernel.min(Barkpark.Plugins.Sheets.grid_max_col()) |> Kernel.max(min)
             end),
          i <- min..hi,
          into: %{},
          do: {Integer.to_string(i), round(w * @px_per_width_unit)}

    # One `<row>` per element (no min/max span), so no OOM bomb like `<col>`:
    # only rows carrying an explicit `customHeight="1"` are read (an auto-fit
    # height is a documented drop); the key clamps to the grid, points → px.
    row_heights =
      for row <- rows,
          attr(row, "customHeight") == "1",
          ht = to_num(attr(row, "ht")),
          ht != nil and ht > 0,
          r = to_int(attr(row, "r")),
          r != nil,
          r >= 1 and r <= Barkpark.Plugins.Sheets.grid_max_row(),
          into: %{},
          do: {Integer.to_string(r), round(ht / @pt_per_px)}

    merges =
      for mc <- root |> child_named("mergeCells") |> children_named("mergeCell"),
          ref = attr(mc, "ref"),
          is_binary(ref) and String.contains?(ref, ":"),
          do: ref

    {frozen_rows, frozen_cols} = frozen_panes(root)

    %{
      cell_styles: cell_styles,
      shared_masters: shared_masters,
      shared_followers: shared_followers,
      col_widths: col_widths,
      row_heights: row_heights,
      merges: merges,
      frozen_rows: frozen_rows,
      frozen_cols: frozen_cols,
      tab_color: parse_tab_color(root),
      cond_formats: parse_cond_formats(root, dxfs)
    }
  end

  # `<sheetPr><tabColor rgb="AARRGGBB"/>` → `#rrggbb` (drop the alpha, lowercase),
  # mirroring `fill_bg/1`. Only an explicit `rgb=` round-trips — a theme/indexed
  # tabColor (no `rgb=`) yields nil and is dropped (the v1 cap, documented). A
  # non-hex last-6 is rejected so import never emits a color the gate would fail.
  defp parse_tab_color(root) do
    with sheet_pr when sheet_pr != nil <- child_named(root, "sheetPr"),
         tab_color when tab_color != nil <- child_named(sheet_pr, "tabColor"),
         rgb when is_binary(rgb) and byte_size(rgb) >= 6 <- attr(tab_color, "rgb"),
         hex = rgb |> String.slice(-6, 6) |> String.downcase(),
         true <- hex =~ ~r/^[0-9a-f]{6}$/ do
      "#" <> hex
    else
      _ -> nil
    end
  end

  # ── conditional formatting (CF-X) ──────────────────────────────────────────
  #
  # `<conditionalFormatting sqref><cfRule …>` → the tab's `"cond_formats"`, the
  # mirror of `XlsxExport`'s emitter. Three lookups feed one rule: the `sqref`
  # (the range), the `cfRule`'s type/operator/`<formula>` (the `when`), and the
  # `<dxf>` its `dxfId` points at (the `style`). A rule kind Barkpark has no
  # model for — `colorScale`, `dataBar`, `iconSet`, an `expression`, or a
  # `cellIs` whose formula is not a plain literal — is SKIPPED, never an error:
  # the drop posture the moduledoc documents for every other unrepresentable
  # feature.

  # xlsx `cellIs` operator → the Barkpark op. `containsText` is handled apart
  # (its needle rides in a SEARCH formula, not as a bare literal).
  @cf_cell_is %{
    "greaterThan" => "gt",
    "lessThan" => "lt",
    "equal" => "eq",
    "between" => "between"
  }

  # The needle of the canonical `containsText` formula
  # `NOT(ISERROR(SEARCH(<literal>,<ref>)))`. Greedy on the literal so a needle
  # containing a comma still binds to the LAST `,<ref>)` — a foreign formula
  # whose needle is a cell reference simply fails to decode and falls back to
  # the `text` attribute.
  @cf_search_re ~r/SEARCH\((.*),[^,()]*\)/s

  defp parse_cond_formats(root, dxfs) do
    for cf <- children_named(root, "conditionalFormatting"),
        sqref = attr(cf, "sqref"),
        is_binary(sqref),
        rule <- children_named(cf, "cfRule"),
        built = build_cond_format(sqref, rule, dxfs),
        built != nil do
      built
    end
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> gate_legal_cond_formats()
  end

  # The import must never hand the save path content `before_save` would then
  # reject — a 409 on the whole upload, over a rule nobody asked for. So each
  # candidate is run past the ONE shared storage validator
  # (`Barkpark.Plugins.Sheets.cond_format_list_errors/2` — no fourth copy of
  # the rules here), then the list is deduped by range and by id and cut to
  # `cond_format_cap/0`, the three list-level constraints the same gate makes.
  # Real-world drops this catches: Excel's "Bold red text" preset (a dxf with a
  # FONT color and no fill — the gate requires `style.bg`), a sheet with more
  # than the cap's worth of rules, and two rules over one range.
  defp gate_legal_cond_formats(rules) do
    rules
    # A foreign rule has no `"id"` yet and the gate requires the key, so the
    # per-rule check runs against a placeholder; the survivors are named after
    # the drops, so the ids the tab ends up with are tight (`cf1`, `cf2`, …).
    |> Enum.filter(&(Barkpark.Plugins.Sheets.cond_format_list_errors([id_stub(&1)], 0) == []))
    |> Enum.uniq_by(&Map.get(&1, "range"))
    |> Enum.take(Barkpark.Plugins.Sheets.cond_format_cap())
    |> fill_cond_format_ids()
    |> Enum.uniq_by(&Map.get(&1, "id"))
  end

  defp id_stub(rule), do: Map.put_new(rule, "id", "cf")

  # `{priority, rule}` — the priority orders the tab's list, which IS the
  # CF-D4 first-match precedence on the Barkpark side.
  defp build_cond_format(sqref, rule, dxfs) do
    with {:ok, range} <- cond_format_range(sqref),
         {:ok, when_map} <- cond_format_when(rule),
         style when style != %{} <- cond_format_style(rule, dxfs) do
      built =
        %{"range" => range, "when" => when_map, "style" => style}
        |> maybe_put("id", cond_format_ext_id(rule))

      {to_int(attr(rule, "priority")) || 0, built}
    else
      _ -> nil
    end
  end

  # An `sqref` may list several ranges ("A1:B2 D5"); a Barkpark rule holds ONE,
  # so the first is taken and the rest dropped (documented with the other
  # unrepresentable features). Normalized to canonical A1 form via `parse_ref`,
  # exactly as the storage gate normalizes for its duplicate-range check.
  defp cond_format_range(sqref) do
    with [first | _] <- String.split(sqref, ~r/\s+/, trim: true),
         [a, b] <- cond_format_corners(first),
         {:ok, {c1, r1}} <- SheetCore.parse_ref(a),
         {:ok, {c2, r2}} <- SheetCore.parse_ref(b) do
      lo = SheetCore.format_ref({min(c1, c2), min(r1, r2)})
      hi = SheetCore.format_ref({max(c1, c2), max(r1, r2)})
      {:ok, if(lo == hi, do: lo, else: lo <> ":" <> hi)}
    else
      _ -> :error
    end
  end

  defp cond_format_corners(ref) do
    case String.split(ref, ":") do
      [a] -> [a, a]
      [a, b] -> [a, b]
      _ -> :error
    end
  end

  defp cond_format_when(rule) do
    formulas = for f <- children_named(rule, "formula"), do: element_text(f)

    case {attr(rule, "type"), attr(rule, "operator")} do
      {"cellIs", "between"} -> cond_format_between(formulas)
      {"cellIs", operator} -> cond_format_cell_is(Map.get(@cf_cell_is, operator), formulas)
      {"containsText", _} -> cond_format_contains(rule, formulas)
      _ -> :error
    end
  end

  defp cond_format_cell_is(nil, _formulas), do: :error

  defp cond_format_cell_is(op, [formula | _]) do
    case decode_cf_literal(formula) do
      :error -> :error
      value -> {:ok, %{"op" => op, "value" => value}}
    end
  end

  defp cond_format_cell_is(_op, _formulas), do: :error

  defp cond_format_between([lo, hi | _]) do
    with value when value != :error <- decode_cf_literal(lo),
         value2 when value2 != :error <- decode_cf_literal(hi) do
      {:ok, %{"op" => "between", "value" => value, "value2" => value2}}
    else
      _ -> :error
    end
  end

  defp cond_format_between(_formulas), do: :error

  # The needle: from the SEARCH formula when it decodes (that carries the
  # TYPE, which the string-only `text` attribute cannot), else the `text`
  # attribute — the shape an Excel-authored rule takes.
  defp cond_format_contains(rule, formulas) do
    needle =
      case cf_search_needle(formulas) do
        :error -> attr(rule, "text")
        value -> value
      end

    if is_nil(needle), do: :error, else: {:ok, %{"op" => "contains", "value" => needle}}
  end

  defp cf_search_needle([formula | _]) do
    case Regex.run(@cf_search_re, formula) do
      [_, literal] -> decode_cf_literal(String.trim(literal))
      _ -> :error
    end
  end

  defp cf_search_needle(_formulas), do: :error

  # An xlsx formula literal → the Elixir term `XlsxExport` encoded: `"…"` (with
  # `""` escaping) → a string, `TRUE`/`FALSE` → a boolean, a bare numeral → an
  # integer or float. Anything else (a cell ref, an expression) → `:error`, and
  # the rule is skipped rather than imported with a guessed threshold. `:error`
  # is the miss marker because `nil` is not a value any literal decodes to.
  defp decode_cf_literal("\"" <> _ = literal) do
    if String.ends_with?(literal, "\"") and byte_size(literal) >= 2 do
      literal |> binary_part(1, byte_size(literal) - 2) |> String.replace(~s(""), ~s("))
    else
      :error
    end
  end

  defp decode_cf_literal("TRUE"), do: true
  defp decode_cf_literal("FALSE"), do: false

  defp decode_cf_literal(literal) when is_binary(literal) do
    case Integer.parse(literal) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(literal) do
          {f, ""} -> f
          _ -> :error
        end
    end
  end

  defp decode_cf_literal(_literal), do: :error

  # The rule's style is the `<dxf>` its `dxfId` indexes; a rule with no dxfId,
  # or one pointing past the table, carries no style and is skipped by
  # `build_cond_format/3` (`CondFormat` drops a styleless rule too).
  defp cond_format_style(rule, dxfs) do
    case to_int(attr(rule, "dxfId")) do
      nil -> %{}
      index when index >= 0 -> Enum.at(dxfs, index) || %{}
      _ -> %{}
    end
  end

  # The stored `"id"`, from the Barkpark `<extLst><ext><bp:id>` the export half
  # writes (`local/1` strips the `bp:` prefix). Absent on a foreign file.
  defp cond_format_ext_id(rule) do
    Enum.find_value(children_named(rule, "extLst"), fn ext_lst ->
      Enum.find_value(children_named(ext_lst, "ext"), fn ext ->
        case ext |> children_named("id") |> List.first() |> element_text() do
          "" -> nil
          id -> id
        end
      end)
    end)
  end

  # Every stored rule needs an `"id"` (the storage gate requires the key), and
  # a foreign file has none. Fill the gaps with the first free `cf<N>` so a
  # re-save is legal, without ever colliding with an id the file DID carry.
  defp fill_cond_format_ids(rules) do
    taken = MapSet.new(for r <- rules, is_binary(Map.get(r, "id")), do: Map.get(r, "id"))

    rules
    |> Enum.map_reduce(taken, fn rule, taken ->
      if is_binary(Map.get(rule, "id")) do
        {rule, taken}
      else
        id = next_cond_format_id(taken, 1)
        {Map.put(rule, "id", id), MapSet.put(taken, id)}
      end
    end)
    |> elem(0)
  end

  defp next_cond_format_id(taken, n) do
    id = "cf#{n}"
    if MapSet.member?(taken, id), do: next_cond_format_id(taken, n + 1), else: id
  end

  # styles.xml `<dxfs>` → one sanitized style map per `<dxf>`, positionally
  # indexed by `cfRule`'s `dxfId`. DIFFERENTIAL formatting normally carries its
  # fill color in `bgColor`; some producers write `fgColor`, so both are read.
  defp parse_dxfs(nil), do: []

  defp parse_dxfs(root) do
    for dxf <- root |> child_named("dxfs") |> children_named("dxf"), do: dxf_style(dxf)
  end

  defp dxf_style(dxf) do
    font = child_named(dxf, "font")
    bg = dxf |> child_named("fill") |> dxf_fill_bg()

    %{}
    |> put_if(font_flag?(font, "b"), "b", true)
    |> put_if(font_flag?(font, "i"), "i", true)
    |> put_if(is_binary(bg), "bg", bg)
  end

  defp dxf_fill_bg(nil), do: nil

  defp dxf_fill_bg(fill) do
    pattern = child_named(fill, "patternFill")
    color = child_named(pattern, "bgColor") || child_named(pattern, "fgColor")

    with rgb when is_binary(rgb) and byte_size(rgb) >= 6 <- attr(color, "rgb"),
         hex = rgb |> String.slice(-6, 6) |> String.downcase(),
         true <- hex =~ ~r/^[0-9a-f]{6}$/ do
      "#" <> hex
    else
      _ -> nil
    end
  end

  # Joined text of an element's character children — an `<f>` (a shared master
  # carries its formula there; a follower is empty), a `<formula>`, a
  # `<bp:id>`.
  defp element_text({_n, _attrs, children}) do
    children
    |> Enum.map(fn
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp element_text(_), do: ""

  defp frozen_panes(root) do
    pane =
      root
      |> child_named("sheetViews")
      |> child_named("sheetView")
      |> child_named("pane")

    if pane != nil and attr(pane, "state") == "frozen" do
      {to_int(attr(pane, "ySplit")) || 0, to_int(attr(pane, "xSplit")) || 0}
    else
      {0, 0}
    end
  end
end
