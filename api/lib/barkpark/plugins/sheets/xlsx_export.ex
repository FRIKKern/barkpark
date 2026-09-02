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
    * tab `"color"` (`#rrggbb`) → `<sheetPr><tabColor rgb="FFRRGGBB"/>` via a
      zip post-process (elixlsx has no tab-color knob — see `apply_xml_patches/2`)
    * cell `"s"` → bold / italic / solid bg fill / horizontal alignment,
      composed with the tab's `"cond_formats"` (CF-D) — a conditional-format
      rule matching a cell has its computed style BAKED into the exported cell
      (CF wins `bg`/`b`/`i`, manual `al` and any keys the rule doesn't set
      survive; `CondFormat.compose/2`), on ALL rows incl. a frozen head row
      (CF-AM2 — CF follows manual styling, which xlsx already emits on every
      row)
    * tab `"cond_formats"` → real `<conditionalFormatting sqref>/<cfRule>` XML
      plus a matching `<dxf>` per distinct rule style in `xl/styles.xml`
      (CF-X — see `cond_format_plan/1`). The baked cell styles above are KEPT
      as well, so a viewer that ignores rules still shows the colour, and
      `XlsxImport` reads the rules back into `"cond_formats"`: a
      Sheets → xlsx → Sheets round trip no longer freezes live rules into
      static fills. A tab with no exportable rule exports byte-identically to
      before (no `conditionalFormatting`, no `dxfs`)
    * `"frozen_rows"`/`"frozen_cols"` → a frozen pane

  Error cells (`"t" => "e"`) export their error string as text. `"locale"`
  is not represented in the export (documented; locale is a document-level
  setting with no xlsx twin).

  ## Conditional formatting: what is exported, and what stays baked-only

  Every op `Barkpark.Plugins.Sheets.CondFormat` supports is exported:
  `gt`/`lt`/`eq`/`between` as `<cfRule type="cellIs">` (operators
  `greaterThan`/`lessThan`/`equal`/`between`) and `contains` as
  `<cfRule type="containsText">`. The rule's `when` value(s) ride in
  `<formula>` as TYPED xlsx literals (a number bare, a string quoted, a
  boolean `TRUE`/`FALSE`), which is what makes the import side's decode exact
  rather than a guess; the stored `"id"`, for which xlsx has no attribute,
  rides in the spec's own producer-private escape hatch, `<cfRule><extLst>`.

  BAKED-ONLY (the style still bakes into the cell, but no `cfRule` is written,
  because there is nothing faithful to write):

    * a rule the kernel drops outright — unknown `"op"`, an unparseable
      `"range"`, or a `"style"` that sanitizes to empty. `CondFormat` never
      admits it as a rule, so it never colours a cell either.
    * a rule the STORAGE GATE
      (`Barkpark.Plugins.Sheets.cond_format_list_errors/2`, the one shared
      validator) would refuse. Only a hand-written document can hold one, and
      it is dead here — a string threshold on `gt`, a numeric or empty
      `contains` needle, a `between` with no `"value2"`, a `"style"` with no
      `"bg"`, a missing `"id"` — but it would be LIVE in Excel, which coerces.
      Writing it would put a rule in the file that this codebase can neither
      evaluate nor read back into storage.
    * a `when` whose value is neither a number, a string, nor a boolean (a
      list, a map, `nil`) — there is no xlsx literal for it. The gate refuses
      those too; the encoder simply never guesses.
    * a second rule over a range an earlier rule already claimed (CF-D4 is
      one rule per range) — the first wins, exactly as evaluation does.

  Excel EVALUATES some exported rules a little differently than Barkpark does,
  which is a fidelity note, not a drop: Excel coerces blank cells to 0 (so a
  `lt`/`gt` rule can fire on a blank there and never here), `contains` matches
  Barkpark's snapshot DISPLAY string but Excel's SEARCH matches the raw
  value (a `"25.00%"` needle on a percent cell), and a type-mismatched rule
  value (a string threshold on `gt`, a numeric `contains` needle) never
  matches in Barkpark while Excel may coerce it. The rule round-trips through
  Barkpark byte-identically in every one of those cases.
  """

  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Fmt
  alias Barkpark.Plugins.Sheets.Core, as: Core
  alias Elixlsx.{Sheet, Workbook}

  @px_per_width_unit 7
  # Row heights: the model is px, xlsx wants POINTS (1px = 0.75pt at 96dpi).
  # The import half divides by the same factor, so heights round-trip.
  @pt_per_px 0.75

  # Determinism (QR-C). An xlsx binary has TWO wall-clock stamps that make two
  # exports of identical content differ byte-for-byte across a clock tick:
  #   1. docProps/core.xml `dcterms:created`/`modified` — elixlsx stamps these
  #      from `workbook.datetime` (Writer.get_docProps_core_xml), which defaults
  #      to `now`. `%Workbook{datetime:}` is the SUPPORTED override, so we pin it.
  #   2. the ZIP DOS mod time/date in every local + central directory header —
  #      stamped by `:zip.create` from the wall clock at 2s resolution, with no
  #      elixlsx knob. We patch it out of the finished binary (see below).
  # Both fixed → identical content exports to identical bytes, by construction.
  @export_timestamp "2020-01-01T00:00:00Z"

  # The 4 bytes a DOS-time + DOS-date field carries, little-endian, time then
  # date: time 0x0000 = 00:00:00; date 0x0021 = 1980-01-01 (year 0 since 1980,
  # month 1, day 1) — the minimum legal DOS date, so every unzip accepts it.
  @dos_datetime <<0x00, 0x00, 0x21, 0x00>>

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

    case Elixlsx.write_to_memory(%Workbook{sheets: sheets, datetime: @export_timestamp}, filename) do
      {:ok, {_name, binary}} -> {:ok, binary |> apply_xml_patches(tabs) |> patch_zip_mtimes()}
      {:error, reason} -> {:error, "xlsx encode failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "xlsx encode failed: #{Exception.message(e)}"}
  end

  # ── zip post-process: tab colors (QL-D7) + conditionalFormatting (CF-X) ─────
  #
  # elixlsx emits neither a tab color nor conditional-formatting XML, so both
  # are stamped by post-processing the finished zip. One unzip/patch/rezip
  # covers both: for each colored tab, `xl/worksheets/sheet<N>.xml` (N = 1-based
  # tab position, elixlsx names sheets in tab order) gains a
  # `<tabColor rgb="FFRRGGBB"/>` as the first child of `<sheetPr>`; for each tab
  # with exportable rules the same worksheet gains its `<conditionalFormatting>`
  # blocks, and `xl/styles.xml` gains the workbook-wide `<dxfs>` table they
  # index into.
  #
  # A document with neither takes the current path BYTE-IDENTICALLY — the whole
  # unzip/patch/rezip is skipped, and `patch_zip_mtimes` (which runs after) sees
  # exactly the bytes it did before. The rezip is a pure function of content
  # (no wall-clock), so `patch_zip_mtimes` still normalizes the fresh DOS times
  # and patched exports stay deterministic too. Fail-open on any structural
  # surprise: the unpatched binary is returned rather than break an export.
  defp apply_xml_patches(binary, tabs) do
    colored = tab_colors(tabs)
    {cond_formats, dxfs} = cond_format_plan(tabs)

    if colored == %{} and cond_formats == %{} do
      binary
    else
      rezip_patched(binary, colored, cond_formats, dxfs)
    end
  end

  defp tab_colors(tabs) do
    tabs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {tab, n} ->
      case tab_color(tab) do
        nil -> []
        color -> [{n, to_argb(color)}]
      end
    end)
    |> Map.new()
  end

  defp tab_color(tab) when is_map(tab) do
    case Map.get(tab, "color") do
      c when is_binary(c) -> if CondFormat.valid_bg?(c), do: c, else: nil
      _ -> nil
    end
  end

  defp tab_color(_), do: nil

  # `#rrggbb` (lowercase in storage) → ARGB `FFRRGGBB` (uppercase) — the xlsx
  # tabColor wants a fully-opaque ARGB. Validated by `tab_color/1` upstream.
  defp to_argb("#" <> hex), do: "FF" <> String.upcase(hex)

  defp rezip_patched(binary, colored, cond_formats, dxfs) do
    with {:ok, entries} <- :zip.extract(binary, [:memory]) do
      patched = Enum.map(entries, &patch_member(&1, colored, cond_formats, dxfs))

      case :zip.create(~c"sheet.xlsx", patched, [:memory]) do
        {:ok, {_name, out}} -> out
        _ -> binary
      end
    else
      _ -> binary
    end
  rescue
    _ -> binary
  end

  defp patch_member({name, content}, colored, cond_formats, dxfs) do
    cond do
      to_string(name) == "xl/styles.xml" and dxfs != [] ->
        {name, content |> to_string() |> insert_dxfs(dxfs)}

      worksheet_index(name) != nil ->
        n = worksheet_index(name)

        xml =
          content
          |> to_string()
          |> maybe_insert_tab_color(Map.get(colored, n))
          |> maybe_insert_cond_formats(Map.get(cond_formats, n))

        {name, xml}

      true ->
        {name, content}
    end
  end

  # `xl/worksheets/sheet<N>.xml` → N (1-based); any other member → nil.
  defp worksheet_index(name) do
    case Regex.run(~r{^xl/worksheets/sheet(\d+)\.xml$}, to_string(name)) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp maybe_insert_tab_color(xml, nil), do: xml

  # Insert `<tabColor rgb="…"/>` as the FIRST child of the worksheet's existing
  # `<sheetPr …>` (schema order: tabColor precedes pageSetUpPr). elixlsx always
  # emits the open-tag form, so a self-closing `<sheetPr/>` never occurs here;
  # if the tag is somehow absent the xml is returned unchanged (fail-open).
  defp maybe_insert_tab_color(xml, argb) do
    String.replace(xml, ~r/(<sheetPr\b[^>]*>)/, "\\1<tabColor rgb=\"#{argb}\"/>", global: false)
  end

  defp maybe_insert_cond_formats(xml, nil), do: xml

  # CT_Worksheet's sequence puts `conditionalFormatting` after `mergeCells` and
  # BEFORE `dataValidations`/`pageMargins`, so anchor on whichever of those
  # elixlsx emitted first. Fail-open: an anchor-less worksheet keeps its XML.
  defp maybe_insert_cond_formats(xml, cf_xml) do
    case Enum.find(["<dataValidations", "<pageMargins"], &String.contains?(xml, &1)) do
      nil -> xml
      anchor -> String.replace(xml, anchor, cf_xml <> anchor, global: false)
    end
  end

  # CT_Stylesheet's sequence is numFmts, fonts, fills, borders, cellStyleXfs,
  # cellXfs, cellStyles, dxfs, … — elixlsx emits neither `cellStyles` nor
  # `dxfs`, so appending just before `</styleSheet>` IS schema order.
  defp insert_dxfs(xml, dxfs) do
    block =
      IO.iodata_to_binary([
        ~s(<dxfs count="#{length(dxfs)}">),
        Enum.map(dxfs, &dxf_xml/1),
        "</dxfs>"
      ])

    String.replace(xml, "</styleSheet>", block <> "</styleSheet>", global: false)
  end

  # CT_Dxf's sequence is font, numFmt, fill, alignment, … and a CF style sets
  # only bold / italic / a solid background. DIFFERENTIAL formatting carries the
  # fill color in `bgColor` (a cell fill uses `fgColor`) — the import half
  # accepts either, this half writes the one Excel writes.
  defp dxf_xml(style) do
    bold = if Map.get(style, "b") == true, do: "<b/>", else: ""
    italic = if Map.get(style, "i") == true, do: "<i/>", else: ""
    font = if bold == "" and italic == "", do: "", else: "<font>#{bold}#{italic}</font>"

    fill =
      case Map.get(style, "bg") do
        "#" <> hex ->
          ~s(<fill><patternFill><bgColor rgb="FF#{String.upcase(hex)}"/></patternFill></fill>)

        _ ->
          ""
      end

    "<dxf>#{font}#{fill}</dxf>"
  end

  # ── conditional formatting → conditionalFormatting XML (CF-X) ───────────────

  # Barkpark op → the xlsx `cellIs` operator. `contains` is deliberately absent:
  # it is a `containsText` rule, not a `cellIs` one.
  @cf_cell_is %{
    "gt" => "greaterThan",
    "lt" => "lessThan",
    "eq" => "equal",
    "between" => "between"
  }

  # xlsx has no attribute for a rule's stored `"id"`, and `extLst` is the
  # spec's OWN escape hatch for producer-private data (CT_CfRule's last child).
  # Excel and LibreOffice ignore an `<ext>` whose uri they do not know;
  # `XlsxImport` reads it back so the id round-trips byte-for-byte.
  @cf_ext_uri "{7B1A4C2E-3D5F-4A88-9C10-2F6E8B0D4A17}"
  @cf_ext_ns "http://barkpark.cloud/xlsx/2026/cond-format"

  # `{%{sheet_index => conditionalFormatting xml}, [dxf style]}` for the whole
  # workbook: `dxfId` indexes ONE workbook-wide `<dxfs>` table, so the styles
  # are collected across every tab and deduped by first appearance.
  defp cond_format_plan(tabs) do
    tabs
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, []}, fn {tab, n}, {acc, dxfs} ->
      case exportable_rules(tab) do
        [] ->
          {acc, dxfs}

        rules ->
          {blocks, dxfs} =
            rules
            |> Enum.with_index(1)
            |> Enum.map_reduce(dxfs, fn {rule, priority}, dxfs ->
              {dxf_id, dxfs} = dxf_index(dxfs, rule.style)
              {cf_block(rule, dxf_id, priority), dxfs}
            end)

          {Map.put(acc, n, IO.iodata_to_binary(blocks)), dxfs}
      end
    end)
  end

  # A tab's stored rules, in list order (which IS the CF-D4 first-match
  # priority), filtered to the ones an xlsx cfRule can carry faithfully.
  #
  # TWO owners decide, neither of them re-implemented here: the kernel
  # (`CondFormat.parse_rules/1`, run ONE rule at a time so the raw map stays
  # alongside for the `"id"` the kernel drops) says what a rule IS, and the
  # storage gate (`Barkpark.Plugins.Sheets.cond_format_list_errors/2`) says
  # what a rule storage would accept. A rule the GATE refuses is dropped on
  # purpose: it is dead here (a string threshold never matches) but LIVE in
  # Excel (which coerces), and `XlsxImport` could not read it back without
  # handing the save path content the same gate would then reject.
  #
  # Duplicate sqrefs are collapsed to the first (CF-D4's one-rule-per-range,
  # which the gate also enforces) so the emitted package can never carry two
  # rules over one range.
  defp exportable_rules(tab) when is_map(tab) do
    case Map.get(tab, "cond_formats") do
      list when is_list(list) ->
        for raw <- list,
            is_map(raw),
            Barkpark.Plugins.Sheets.cond_format_list_errors([raw], 0) == [],
            [parsed] <- [CondFormat.parse_rules([raw])],
            spec = rule_spec(raw, parsed),
            spec != nil,
            do: spec

      _ ->
        []
    end
    |> Enum.uniq_by(& &1.sqref)
  end

  defp exportable_rules(_tab), do: []

  defp rule_spec(raw, %{range: {c1, r1, _c2, _r2} = range, condition: w, style: style}) do
    op = Map.get(w, "op")

    with true <- op == "contains" or is_map_key(@cf_cell_is, op),
         {:ok, literals} <- cf_literals(op, w) do
      %{
        id: cf_id(raw),
        sqref: format_range(range),
        anchor: Core.format_ref({c1, r1}),
        op: op,
        literals: literals,
        style: style
      }
    else
      _ -> nil
    end
  end

  defp cf_id(raw) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp format_range({c, r, c, r}), do: Core.format_ref({c, r})

  defp format_range({c1, r1, c2, r2}),
    do: Core.format_ref({c1, r1}) <> ":" <> Core.format_ref({c2, r2})

  # The rule's `when` value(s) as xlsx formula literals, in `<formula>` order.
  # A missing or unrepresentable value makes the rule UNEXPORTABLE (it stays
  # baked-only, moduledoc) rather than shipping a cfRule whose threshold is a
  # guess — an xlsx rule with the wrong threshold is worse than no rule.
  defp cf_literals("between", w) do
    with true <- Map.has_key?(w, "value") and Map.has_key?(w, "value2"),
         v1 when is_binary(v1) <- cf_literal(Map.get(w, "value")),
         v2 when is_binary(v2) <- cf_literal(Map.get(w, "value2")) do
      {:ok, [v1, v2]}
    else
      _ -> :error
    end
  end

  defp cf_literals(_op, w) do
    with true <- Map.has_key?(w, "value"),
         v when is_binary(v) <- cf_literal(Map.get(w, "value")) do
      {:ok, [v]}
    else
      _ -> :error
    end
  end

  # A stored `when` value as the xlsx formula literal that decodes back to the
  # SAME Elixir term: a number bare, a boolean `TRUE`/`FALSE`, a string in
  # double quotes with `""` escaping. Anything else has no literal → nil.
  defp cf_literal(true), do: "TRUE"
  defp cf_literal(false), do: "FALSE"
  defp cf_literal(v) when is_integer(v), do: Integer.to_string(v)
  defp cf_literal(v) when is_float(v), do: Float.to_string(v)
  defp cf_literal(v) when is_binary(v), do: ~s(") <> String.replace(v, ~s("), ~s("")) <> ~s(")
  defp cf_literal(_), do: nil

  # Position of `style` in the workbook-wide dxf table, appending it when new.
  defp dxf_index(dxfs, style) do
    case Enum.find_index(dxfs, &(&1 == style)) do
      nil -> {length(dxfs), dxfs ++ [style]}
      index -> {index, dxfs}
    end
  end

  # `contains` is a `containsText` rule: Excel wants BOTH the `text` attribute
  # and the canonical `SEARCH` formula. The formula carries the needle as a
  # TYPED literal (the `text` attribute can only ever be a string), which is
  # what lets the import half hand back a numeric needle as a number.
  defp cf_block(%{op: "contains", literals: [needle]} = rule, dxf_id, priority) do
    formula = "NOT(ISERROR(SEARCH(" <> escape_xml(needle) <> "," <> rule.anchor <> ")))"

    cf_wrap(rule, [
      ~s(<cfRule type="containsText" dxfId="#{dxf_id}" priority="#{priority}") <>
        ~s( operator="containsText" text="#{escape_attr(cf_needle_text(needle))}">),
      "<formula>",
      formula,
      "</formula>",
      cf_ext(rule.id),
      "</cfRule>"
    ])
  end

  defp cf_block(rule, dxf_id, priority) do
    operator = Map.fetch!(@cf_cell_is, rule.op)

    cf_wrap(rule, [
      ~s(<cfRule type="cellIs" dxfId="#{dxf_id}" priority="#{priority}" operator="#{operator}">),
      Enum.map(rule.literals, &["<formula>", escape_xml(&1), "</formula>"]),
      cf_ext(rule.id),
      "</cfRule>"
    ])
  end

  defp cf_wrap(rule, inner) do
    IO.iodata_to_binary([
      ~s(<conditionalFormatting sqref="#{rule.sqref}">),
      inner,
      "</conditionalFormatting>"
    ])
  end

  # The `text=` attribute is a plain string: unwrap a quoted literal, pass a
  # bare number / TRUE / FALSE through as its own text.
  defp cf_needle_text("\"" <> _ = literal) do
    literal |> binary_part(1, byte_size(literal) - 2) |> String.replace(~s(""), ~s("))
  end

  defp cf_needle_text(literal), do: literal

  defp cf_ext(nil), do: ""

  defp cf_ext(id) do
    ~s(<extLst><ext uri="#{@cf_ext_uri}" xmlns:bp="#{@cf_ext_ns}">) <>
      ~s(<bp:id>#{escape_xml(id)}</bp:id></ext></extLst>)
  end

  # ── deterministic ZIP mod-times (QR-C) ──────────────────────────────────────

  # Byte-surgical patch of the DOS mod time/date that `:zip.create` stamps from
  # the wall clock into every local-file and central-directory header. We walk
  # the central directory from the EOCD, and for each entry overwrite the CDH's
  # 4-byte time/date field (offset 12) and — via the CDH's stored relative
  # offset — the member's LFH time/date field (offset 10) with `@dos_datetime`.
  # No re-compression, no reordering: provably 4 bytes per header changed.
  #
  # FAIL-OPEN by contract: any structural surprise (bad signature, ZIP64,
  # out-of-bounds offset) returns the UNPATCHED binary — an export must never
  # break over a cosmetic timestamp. The determinism tests are the tripwire
  # that keeps this honest (they'd go red the instant the walk silently no-ops).
  defp patch_zip_mtimes(binary) when is_binary(binary) do
    with {:ok, cd_offset, count} <- read_eocd(binary),
         {:ok, header_offsets} <- walk_central_dir(binary, cd_offset, count) do
      header_offsets
      |> Enum.flat_map(fn {cdh_off, lfh_off} -> [cdh_off + 12, lfh_off + 10] end)
      |> apply_dos_patches(binary)
    else
      _ -> binary
    end
  rescue
    _ -> binary
  end

  defp patch_zip_mtimes(binary), do: binary

  # Scan from the tail for the End Of Central Directory signature (0x06054b50,
  # little-endian `50 4B 05 06`). Bounded to the last 64KB+22 (the max EOCD +
  # comment). Fails open on ZIP64 (a locator before the EOCD, or the 0xFFFF /
  # 0xFFFFFFFF sentinels) — sheet exports never approach the 4GB/65535-entry
  # limits, so a ZIP64 sighting means "not our shape", not "patch harder".
  defp read_eocd(binary) do
    size = byte_size(binary)
    scan_eocd(binary, size, max(size - 22, 0), max(size - 22 - 0xFFFF, 0))
  end

  defp scan_eocd(binary, size, pos, floor) when pos >= floor do
    case binary do
      <<_::binary-size(pos), 0x50, 0x4B, 0x05, 0x06, _disk::little-16, _cd_disk::little-16,
        _entries_disk::little-16, total_entries::little-16, _cd_size::little-32,
        cd_offset::little-32, _comment_len::little-16, _::binary>> ->
        cond do
          total_entries == 0xFFFF -> :error
          cd_offset == 0xFFFFFFFF -> :error
          zip64_locator?(binary, pos) -> :error
          cd_offset > size -> :error
          true -> {:ok, cd_offset, total_entries}
        end

      _ ->
        scan_eocd(binary, size, pos - 1, floor)
    end
  end

  defp scan_eocd(_binary, _size, _pos, _floor), do: :error

  # A ZIP64 EOCD locator (0x07064b50) sits in the 20 bytes immediately before a
  # ZIP64 archive's EOCD. Its presence means the offsets we just read may be
  # 0xFFFFFFFF sentinels — refuse and fail open.
  defp zip64_locator?(binary, pos) when pos >= 20 do
    loc = pos - 20
    match?(<<_::binary-size(loc), 0x50, 0x4B, 0x06, 0x07, _::binary>>, binary)
  end

  defp zip64_locator?(_binary, _pos), do: false

  # Walk exactly `count` central-directory headers from `offset`, collecting
  # `{cdh_offset, lfh_offset}` per entry. Any signature mismatch (CDH or the
  # LFH the CDH points at) returns :error → the caller fails open.
  defp walk_central_dir(binary, offset, count), do: walk_cdh(binary, offset, count, [])

  defp walk_cdh(_binary, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp walk_cdh(binary, offset, remaining, acc) when remaining > 0 do
    case binary do
      <<_::binary-size(offset), 0x50, 0x4B, 0x01, 0x02, _::binary-size(24), fname_len::little-16,
        extra_len::little-16, comment_len::little-16, _::binary-size(8), lfh_offset::little-32,
        _::binary>> ->
        if lfh_signature?(binary, lfh_offset) do
          next = offset + 46 + fname_len + extra_len + comment_len
          walk_cdh(binary, next, remaining - 1, [{offset, lfh_offset} | acc])
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp walk_cdh(_binary, _offset, _remaining, _acc), do: :error

  defp lfh_signature?(binary, offset) when is_integer(offset) and offset >= 0 do
    match?(<<_::binary-size(offset), 0x50, 0x4B, 0x03, 0x04, _::binary>>, binary)
  end

  defp lfh_signature?(_binary, _offset), do: false

  # Overwrite each 4-byte window at the given offsets with @dos_datetime, in one
  # left-to-right splice (offsets are sorted; the windows never overlap — CDH
  # and LFH headers are ≥ 30 bytes apart).
  defp apply_dos_patches(offsets, binary) do
    {chunks, last} =
      offsets
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn off, {acc, pos} ->
        {[acc, :binary.part(binary, pos, off - pos), @dos_datetime], off + 4}
      end)

    IO.iodata_to_binary([chunks, :binary.part(binary, last, byte_size(binary) - last)])
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

    # Conditional-format rules parsed ONCE per tab (CF-D). Non-list / malformed
    # input → [] (lenient kernel), so a tab with no rules costs nothing and
    # exports byte-identically to before.
    rules = CondFormat.parse_rules(Map.get(tab, "cond_formats"))

    rows =
      case max_row do
        0 ->
          [[]]

        max_row ->
          # A height-only sheet (heights but no cells) has max_col 0 — emit
          # empty rows so the height attr still rides along.
          col_range = if max_col >= 1, do: 1..max_col, else: []

          for r <- 1..max_row do
            for c <- col_range, do: encode_cell(Map.get(by_pos, {c, r}), {c, r}, rules)
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

  # A blank position has no cell to style — CF never matches a blank cell
  # (CondFormat classifies it :blank, which fires no op), so it stays nil.
  defp encode_cell(nil, _pos, _rules), do: nil

  defp encode_cell(cell, pos, rules) do
    # Bake the CF-computed style into the cell (CF-D): compose the manual "s"
    # with the first matching rule's style (CF-D3/D4 via the kernel). With no
    # rules or no match, style_for/3 is nil and compose(s, nil) == to_map(s),
    # so style_props sees exactly today's manual style — byte-stable.
    composed = CondFormat.compose(Map.get(cell, "s"), CondFormat.style_for(rules, pos, cell))
    props = style_props(composed) ++ fmt_props(cell)

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

  # `escape_xml/1` plus the double quote — for a value that lands inside a
  # double-quoted ATTRIBUTE (a `cfRule` `text=`, an `<ext>` payload).
  defp escape_attr(s), do: s |> escape_xml() |> String.replace(~s("), "&quot;")

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
      if(is_binary(bg) and CondFormat.valid_bg?(bg), do: [bg_color: bg], else: []),
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
