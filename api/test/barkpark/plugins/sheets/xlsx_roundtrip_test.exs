defmodule Barkpark.Plugins.Sheets.XlsxRoundtripTest do
  @moduledoc """
  M5 xlsx conversion locks — pure unit tests, no DB.

  Import fixtures are built IN-TEST with elixlsx (no binary fixtures in
  git); the full round-trip test drives sheet content → `XlsxExport` →
  `XlsxImport` and asserts values, formulas, fmt hints, col widths,
  merges, styles, tab names and frozen panes all survive — the M5
  round-trip exactness target.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.{Fmt, XlsxExport, XlsxImport}
  alias Barkpark.Plugins.Sheets.Engine
  alias Elixlsx.{Sheet, Workbook}

  defp write_xlsx(sheets) do
    {:ok, {_name, binary}} = Elixlsx.write_to_memory(%Workbook{sheets: sheets}, "fixture.xlsx")
    binary
  end

  defp import!(binary) do
    {:ok, content} = XlsxImport.to_content(binary)
    content
  end

  defp cell(content, tab, addr), do: get_in(content, ["tabs", Access.at(tab), "cells", addr])

  # Canonical content: every feature the model represents for xlsx.
  # Formula cells carry the engine-computed v/t (what a real saved sheet
  # holds); literals carry t only for date/datetime, bg is lowercase —
  # the model's canonical forms, which the converters preserve exactly.
  defp canonical_content do
    %{
      "tabs" => [
        %{
          "name" => "Budget",
          "frozen_rows" => 1,
          "frozen_cols" => 1,
          "col_widths" => %{"1" => 140, "3" => 70},
          "row_heights" => %{"2" => 40},
          "merges" => ["A1:B1"],
          "cells" => %{
            "A1" => %{"v" => "Q3 Budget", "s" => %{"b" => true, "al" => "center"}},
            "A2" => %{"v" => "Item", "s" => %{"b" => true, "bg" => "#eeeeee"}},
            "B2" => %{"v" => "Cost", "s" => %{"i" => true}},
            "A3" => %{"v" => "Ops"},
            "B3" => %{"v" => 1200.5, "fmt" => "currency"},
            "A4" => %{"v" => "Tax", "s" => %{"al" => "right"}},
            "B4" => %{"v" => 0.25, "fmt" => "percent"},
            "B5" => %{"f" => "SUM(B3:B4)", "v" => 1200.75, "t" => "n"},
            "C3" => %{"v" => 42},
            "C4" => %{"v" => true},
            "C5" => %{"v" => "an & odd <value>"}
          }
        },
        %{
          "name" => "Dates",
          "cells" => %{
            "A1" => %{"v" => "2026-06-12", "t" => "date", "fmt" => "date"},
            "B1" => %{"v" => "2026-06-12T08:30:00", "t" => "datetime", "fmt" => "datetime"},
            "C1" => %{"v" => 3.25, "fmt" => "fixed"},
            "D1" => %{"v" => 12_345, "fmt" => "thousands"},
            "E1" => %{"f" => "IF(C1>3,\"hi\",\"lo\")", "v" => "hi", "t" => "s"}
          }
        }
      ]
    }
  end

  # ── import fixtures (elixlsx-built) ─────────────────────────────────────────

  describe "xlsx import" do
    test "values, types and tab names map; integral floats normalize to ints" do
      content =
        [
          %Sheet{name: "Data", rows: [["text", 42, 2.5, true], [""]]},
          %Sheet{name: "Second", rows: [["other"]]}
        ]
        |> write_xlsx()
        |> import!()

      assert [%{"name" => "Data"}, %{"name" => "Second"}] =
               Enum.map(content["tabs"], &Map.take(&1, ["name"]))

      assert cell(content, 0, "A1") == %{"v" => "text"}
      assert cell(content, 0, "B1") == %{"v" => 42}
      assert cell(content, 0, "C1") == %{"v" => 2.5}
      assert cell(content, 0, "D1") == %{"v" => true}
      assert cell(content, 1, "A1") == %{"v" => "other"}
    end

    test "dates and datetimes become ISO-8601 with t + fmt hints" do
      content =
        [
          %Sheet{
            name: "Dates",
            rows: [
              [
                [{{2026, 6, 12}, {0, 0, 0}}, num_format: "yyyy-mm-dd"],
                [{{2026, 6, 12}, {8, 30, 0}}, num_format: "yyyy-mm-dd h:mm:ss"]
              ]
            ]
          }
        ]
        |> write_xlsx()
        |> import!()

      assert cell(content, 0, "A1") == %{"v" => "2026-06-12", "t" => "date", "fmt" => "date"}

      assert cell(content, 0, "B1") == %{
               "v" => "2026-06-12T08:30:00",
               "t" => "datetime",
               "fmt" => "datetime"
             }
    end

    test "number formats classify into the fmt vocabulary" do
      content =
        [
          %Sheet{
            name: "Fmt",
            rows: [
              [
                [1.5, num_format: "0.00"],
                [0.25, num_format: "0.00%"],
                [99.9, num_format: "$#,##0.00"],
                [12_345, num_format: "#,##0"],
                7
              ]
            ]
          }
        ]
        |> write_xlsx()
        |> import!()

      assert cell(content, 0, "A1")["fmt"] == "fixed"
      assert cell(content, 0, "B1")["fmt"] == "percent"
      assert cell(content, 0, "C1")["fmt"] == "currency"
      assert cell(content, 0, "D1")["fmt"] == "thousands"
      # general carries no fmt key
      assert cell(content, 0, "E1") == %{"v" => 7}
    end

    test "basic styles map to s (bg normalized lowercase)" do
      content =
        [
          %Sheet{
            name: "Style",
            rows: [
              [
                ["bold", bold: true],
                ["italic", italic: true],
                ["bg", bg_color: "#FFCC00"],
                ["mid", align_horizontal: :center]
              ]
            ]
          }
        ]
        |> write_xlsx()
        |> import!()

      assert cell(content, 0, "A1")["s"] == %{"b" => true}
      assert cell(content, 0, "B1")["s"] == %{"i" => true}
      assert cell(content, 0, "C1")["s"] == %{"bg" => "#ffcc00"}
      assert cell(content, 0, "D1")["s"] == %{"al" => "center"}
    end

    test "merges, col widths and frozen panes map to tab layout" do
      content =
        [
          %Sheet{
            name: "Layout",
            rows: [["Title", nil], ["a", "b"]],
            merge_cells: [{"A1", "B1"}],
            col_widths: %{1 => 20.0, 2 => 10.0},
            pane_freeze: {1, 0}
          }
        ]
        |> write_xlsx()
        |> import!()

      tab = hd(content["tabs"])
      assert tab["merges"] == ["A1:B1"]
      assert tab["col_widths"] == %{"1" => 140, "2" => 70}
      assert tab["frozen_rows"] == 1
      refute Map.has_key?(tab, "frozen_cols")
    end

    test "formulas import as f (cached numeric value rides as v); engine recompute resolves" do
      content =
        [
          %Sheet{
            name: "Calc",
            rows: [[2, 3, [{:formula, "SUM(A1:B1)", value: 5}]]]
          }
        ]
        |> write_xlsx()
        |> import!()

      assert cell(content, 0, "C1") == %{"f" => "SUM(A1:B1)", "v" => 5}

      recomputed = Engine.recompute(content)

      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "C1"]) ==
               %{"f" => "SUM(A1:B1)", "v" => 5, "t" => "n"}
    end

    test "unknown functions keep the file's cached value and gain stale (bound grill decision)" do
      content =
        [%Sheet{name: "Calc", rows: [[[{:formula, "NPV(0.1,A2:A9)", value: 123.45}]]]}]
        |> write_xlsx()
        |> import!()

      assert cell(content, 0, "A1") == %{"f" => "NPV(0.1,A2:A9)", "v" => 123.45}

      recomputed = Engine.recompute(content)

      # The kept-import arm of the unsupported-function ruling: the value Excel
      # computed keeps rendering, and `stale_fn` names what could not be
      # re-evaluated so the surfaces can say so out loud.
      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "A1"]) ==
               %{
                 "f" => "NPV(0.1,A2:A9)",
                 "v" => 123.45,
                 "stale" => true,
                 "stale_fn" => "NPV"
               }
    end

    test "a merge reaching past the data clips to the occupied bounds" do
      content =
        [%Sheet{name: "Clip", rows: [["Title", nil], ["a", "b"]], merge_cells: [{"A1", "E1"}]}]
        |> write_xlsx()
        |> import!()

      assert hd(content["tabs"])["merges"] == ["A1:B1"]
    end

    test "hostile merge ranges clip; ranges over the area cap drop deterministically" do
      # occupied bounds are CV150 (100 cols × 150 rows). "A1:E1" stays as-is;
      # "A1:ZZZ1000000" clips to "A1:CV150" — 15_000 cells > the 10_000 area
      # cap — and drops.
      rows = [["Title", "x"]] ++ List.duplicate([], 148) ++ [List.duplicate(nil, 99) ++ ["deep"]]

      content =
        [%Sheet{name: "M", rows: rows, merge_cells: [{"A1", "E1"}, {"A1", "ZZZ1000000"}]}]
        |> write_xlsx()
        |> import!()

      assert hd(content["tabs"])["merges"] == ["A1:E1"]
    end

    test "a non-xlsx binary is a clear error" do
      assert {:error, message} = XlsxImport.to_content("definitely not a zip")
      assert message =~ "invalid xlsx"
    end

    test "a package that opens but fails full extraction is a clean error, never a raise" do
      # open_package succeeds (the zip directory + workbook.xml stay intact),
      # so import reaches the SECOND zip pass in parse_layout — a raw
      # :zip.extract over the same bytes. A corrupt worksheet deflate stream
      # makes that eager full-inflate blow up; parse_layout's rescue maps it to
      # the same {:error, _} the import controller turns into a 422, instead of
      # letting the exception escape as a 500.
      good =
        XlsxExport.to_binary(%{"tabs" => [%{"name" => "S", "cells" => big_cells()}]}) |> ok!()

      bad = corrupt_last_member(good)

      # It really does still open — proving the failure is in parse_layout, not open_package.
      assert {:ok, _} = XlsxReader.open(bad, source: :binary)
      assert {:error, _} = XlsxImport.to_content(bad)
    end

    test "a hand-crafted ref beyond the grid bounds drops (gate-legal by construction)" do
      # Excel itself cannot write a ref past XFD/1_048_576 — only a
      # hand-crafted package can. The cell drops; the in-grid cell survives.
      content = import!(hostile_xlsx())

      assert [%{"name" => "Hostile", "cells" => cells}] = content["tabs"]
      assert cells == %{"A1" => %{"v" => 1}}
    end

    test "an unbounded <col max> is clamped to the grid — no whole-BEAM OOM" do
      # A few-dozen-byte <col min=1 max=2_000_000_000> would build a
      # ~2-billion-entry col_widths map (OOM bomb) without the clamp. The
      # import must return promptly with at most grid_max_col keys.
      {:ok, binary} = XlsxExport.to_binary(%{})
      max_col = Barkpark.Plugins.Sheets.grid_max_col()

      content =
        binary
        |> patch_cols(~s(<cols><col min="1" max="2000000000" width="10"/></cols>))
        |> import!()

      col_widths = hd(content["tabs"])["col_widths"]
      assert map_size(col_widths) == max_col
    end

    test "an in-bounds-min but over-grid <col max> clamps to grid_max_col keys" do
      {:ok, binary} = XlsxExport.to_binary(%{})
      max_col = Barkpark.Plugins.Sheets.grid_max_col()

      content =
        binary
        |> patch_cols(~s(<cols><col min="1" max="20000" width="10"/></cols>))
        |> import!()

      assert map_size(hd(content["tabs"])["col_widths"]) == max_col
    end
  end

  # Rebuild an exported package with a <cols> block spliced in before
  # <sheetData> in the first worksheet — the surface a hostile importer hits.
  defp patch_cols(binary, cols_xml) do
    rewrite_sheet1(
      binary,
      &String.replace(&1, "<sheetData", cols_xml <> "<sheetData", global: false)
    )
  end

  # Rewrite the first worksheet's XML through `fun` and repackage — the zip
  # surface a hostile/hand-authored importer hits.
  defp rewrite_sheet1(binary, fun) do
    {:ok, entries} = :zip.extract(binary, [:memory])

    patched =
      Enum.map(entries, fn
        {~c"xl/worksheets/sheet1.xml" = name, xml} -> {name, xml |> to_string() |> fun.()}
        entry -> entry
      end)

    {:ok, {_name, out}} = :zip.create(~c"t.xlsx", patched, [:memory])
    out
  end

  defp ok!({:ok, binary}), do: binary

  # A cell set large enough that the worksheet part is actually deflated (not
  # zip-stored), so corrupting its stream reaches inflate.
  defp big_cells, do: for(i <- 1..300, into: %{}, do: {"A#{i}", %{"v" => i}})

  # Corrupt the first bytes of the LAST zip member's compressed data — the
  # worksheet part elixlsx/XlsxExport writes last. The central directory and the
  # earlier members (workbook.xml, rels) stay intact, so XlsxReader.open still
  # succeeds while a full :zip.extract over the same bytes fails to inflate.
  defp corrupt_last_member(binary) do
    locals = for {p, _} <- :binary.matches(binary, <<0x50, 0x4B, 0x03, 0x04>>), do: p
    last = List.last(locals)

    <<_::binary-size(last), _sig::32, _ver::16, _flag::16, _method::16, _time::16, _date::16,
      _crc::32, _csize::32, _usize::32, nlen::little-16, elen::little-16, _::binary>> = binary

    data_start = last + 30 + nlen + elen

    <<pre::binary-size(data_start), b1, b2, b3, b4, b5, b6, post::binary>> = binary

    flipped =
      <<:erlang.bxor(b1, 0xFF), :erlang.bxor(b2, 0xFF), :erlang.bxor(b3, 0xFF),
        :erlang.bxor(b4, 0xFF), :erlang.bxor(b5, 0xFF), :erlang.bxor(b6, 0xFF)>>

    pre <> flipped <> post
  end

  # The raw XML of the first worksheet in an exported package.
  defp sheet1_xml(binary) do
    {:ok, entries} = :zip.extract(binary, [:memory])
    {_name, xml} = Enum.find(entries, fn {name, _} -> name == ~c"xl/worksheets/sheet1.xml" end)
    to_string(xml)
  end

  # Minimal hand-built package carrying a cell ref beyond the grid bounds —
  # elixlsx (correctly) cannot produce one.
  defp hostile_xlsx do
    package(
      """
      <row r="1">
        <c r="A1" t="n"><v>1</v></c>
        <c r="ZZZZ1" t="n"><v>9</v></c>
      </row>
      """,
      name: "Hostile"
    )
  end

  # A hand-built single-worksheet xlsx package wrapping the given `<sheetData>`
  # inner XML — the surface for features elixlsx cannot author (shared
  # formulas, inline strings, error-cached cells). `opts[:name]` sets the tab
  # name (default "Sheet1").
  defp package(sheet_data, opts \\ []) do
    name = Keyword.get(opts, :name, "Sheet1")
    sheet_pr = Keyword.get(opts, :sheet_pr, "")

    sheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      #{sheet_pr}
      <sheetData>
        #{sheet_data}
      </sheetData>
    </worksheet>
    """

    workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="#{name}" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    workbook_rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
                    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
                    Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    root_rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
                    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
                    Target="xl/workbook.xml"/>
    </Relationships>
    """

    content_types = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    files = [
      {~c"[Content_Types].xml", content_types},
      {~c"_rels/.rels", root_rels},
      {~c"xl/workbook.xml", workbook},
      {~c"xl/_rels/workbook.xml.rels", workbook_rels},
      {~c"xl/worksheets/sheet1.xml", sheet}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"package.xlsx", files, [:memory])
    binary
  end

  # ── fmt vocabulary ──────────────────────────────────────────────────────────

  describe "Fmt" do
    test "every canonical export format classifies back to its own class" do
      # Display-only classes (checkbox) have no num_format — they are not part
      # of the xlsx round trip; the invariant holds for the xlsx-mappable ones.
      for fmt <- Fmt.vocabulary(), Fmt.num_format(fmt) != nil do
        assert fmt |> Fmt.num_format() |> Fmt.classify_format() == fmt
      end
    end

    test "builtin ids classify; general/unknown classify to nil" do
      assert Fmt.classify(9, %{}) == "percent"
      assert Fmt.classify(14, %{}) == "date"
      assert Fmt.classify(22, %{}) == "datetime"
      assert Fmt.classify(44, %{}) == "currency"
      assert Fmt.classify(0, %{}) == nil
      assert Fmt.classify(164, %{"164" => "General"}) == nil
      assert Fmt.classify(164, %{"164" => "[$kr-414] #,##0.00"}) == "currency"
      assert Fmt.classify(164, %{"164" => "[Red]0.00"}) == "fixed"
      assert Fmt.classify(164, %{"164" => "hh:mm"}) == "datetime"
      assert Fmt.classify(nil, %{}) == nil
    end
  end

  # ── full round trip ─────────────────────────────────────────────────────────

  describe "round trip — sheet → xlsx → sheet" do
    test "values, formulas, fmt, col widths, merges, styles and panes survive" do
      original = canonical_content()

      {:ok, binary} = XlsxExport.to_binary(original)
      imported = binary |> import!() |> Engine.recompute()

      assert imported == original
    end

    test "numeric cached formula values survive even before recompute" do
      {:ok, binary} = XlsxExport.to_binary(canonical_content())
      imported = import!(binary)

      assert cell(imported, 0, "B5") == %{"f" => "SUM(B3:B4)", "v" => 1200.75}
    end

    test "a row height emits <row ht customHeight> in the package XML (40px → 30.0pt)" do
      {:ok, binary} = XlsxExport.to_binary(canonical_content())
      # Budget is sheet1; row 2 carries the 40px height → 40 × 0.75 = 30.0pt.
      xml = sheet1_xml(binary)

      assert xml =~ ~s(<row r="2" customHeight="1" ht="30.0")
    end

    test "a height on an empty trailing row survives export (locks the row-extent extension)" do
      # Cells reach only row 1, but a height is set on row 5. Without the
      # max_row extension elixlsx would emit only row 1 and drop the height.
      content = %{
        "tabs" => [
          %{"name" => "Tall", "cells" => %{"A1" => %{"v" => 1}}, "row_heights" => %{"5" => 40}}
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert hd(imported["tabs"])["row_heights"] == %{"5" => 40}
    end

    test "empty content exports to a valid single-sheet workbook" do
      {:ok, binary} = XlsxExport.to_binary(%{})
      assert %{"tabs" => [%{"name" => "Sheet1"}]} = import!(binary)
    end
  end

  # ── Excel-authored leg (features elixlsx cannot produce) ────────────────────

  describe "Excel-authored leg" do
    test "a shared-formula follower is rebased to its own offset; recompute keeps its value" do
      content =
        package("""
        <row r="1">
          <c r="A1" t="n"><v>2</v></c>
          <c r="B1" t="n"><v>3</v></c>
          <c r="C1" t="n"><f t="shared" ref="C1:C2" si="0">SUM(A1:B1)</f><v>5</v></c>
        </row>
        <row r="2">
          <c r="A2" t="n"><v>20</v></c>
          <c r="B2" t="n"><v>30</v></c>
          <c r="C2" t="n"><f t="shared" si="0"/><v>50</v></c>
        </row>
        """)
        |> import!()

      # The master keeps its own formula; the follower carries ITS OWN rebased
      # formula — NOT the master's verbatim "SUM(A1:B1)" (the imported bug).
      assert cell(content, 0, "C1") == %{"f" => "SUM(A1:B1)", "v" => 5}
      assert cell(content, 0, "C2") == %{"f" => "SUM(A2:B2)", "v" => 50}

      recomputed = Engine.recompute(content)

      # Recompute reproduces the follower's cached 50; the master-text bug would
      # have overwritten it with 5.
      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "C2"]) ==
               %{"f" => "SUM(A2:B2)", "v" => 50, "t" => "n"}
    end

    test "an error-cached formula recomputes to its error value" do
      content =
        package("""
        <row r="1"><c r="A1" t="e"><f>1/0</f><v>#DIV/0!</v></c></row>
        """)
        |> import!()

      assert cell(content, 0, "A1") == %{"f" => "1/0", "v" => "#DIV/0!"}

      recomputed = Engine.recompute(content)

      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "A1"]) ==
               %{"f" => "1/0", "v" => "#DIV/0!", "t" => "e"}
    end

    test "an inline-string cell imports its text value" do
      content =
        package("""
        <row r="1"><c r="A1" t="inlineStr"><is><t>hi there</t></is></c></row>
        """)
        |> import!()

      assert cell(content, 0, "A1") == %{"v" => "hi there"}
    end

    test "an Excel-authored row height (points) imports to px" do
      # elixlsx emits <row ht customHeight="1">; 30pt ÷ 0.75 = 40px.
      content =
        [%Sheet{name: "H", rows: [["a"], ["b"]], row_heights: %{2 => 30}}]
        |> write_xlsx()
        |> import!()

      assert hd(content["tabs"])["row_heights"] == %{"2" => 40}
    end
  end

  # ── documented drops (survivor-set documentation) ───────────────────────────

  describe "documented drops" do
    test "a stale formula's string cached value is dropped; f + stale survive" do
      content = %{
        "tabs" => [
          %{
            "name" => "Drop",
            "cells" => %{"A1" => %{"f" => "FOO(1)", "v" => "cached", "t" => "s"}}
          }
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = binary |> import!() |> Engine.recompute()

      # The documented STRING-CACHED-VALUE drop: an xlsx formula cell only
      # carries a NUMERIC cached <v>, so "cached" is not exported. On reimport
      # the unknown-fn formula has NO value left to preserve — and since the
      # unsupported-function ruling (2026-09-02) a cell with nothing cached is
      # not a quiet stale dot but the error itself: #NAME?.
      assert cell(imported, 0, "A1") == %{"f" => "FOO(1)", "v" => "#NAME?", "t" => "e"}
    end

    test "an auto-fit row height (no customHeight) is dropped on import" do
      # A <row ht> WITHOUT customHeight="1" is an auto-fit hint, not an
      # explicit height — the importer reads only customHeight rows.
      {:ok, binary} = XlsxExport.to_binary(%{})

      imported =
        binary
        |> rewrite_sheet1(&String.replace(&1, "<row ", ~s(<row ht="30" ), global: false))
        |> import!()

      refute Map.has_key?(hd(imported["tabs"]), "row_heights")
    end
  end

  # ── conditional formatting: the CF-D2 v1 baked-not-exported contract ────────

  describe "conditional formatting (CF-D2 v1 asymmetry)" do
    # v1 bakes the CF-COMPUTED style into the exported cell but does NOT export
    # the rules as xlsx conditionalFormatting XML (CF-D2). The accepted,
    # deliberate asymmetry: export→import of a CF-matched cell yields the baked
    # fill as a MANUAL "s" (visually faithful, lossy on the rule) and the tab
    # carries no cond_formats back. This test PINS that contract.
    test "a CF-matched cell re-imports as a manual style; the rule itself does not survive" do
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "cond_formats" => [
              %{
                "id" => "r1",
                "range" => "A1:A2",
                "when" => %{"op" => "gt", "value" => 100},
                "style" => %{"bg" => "#ff0000", "b" => true}
              }
            ],
            "cells" => %{"A1" => %{"v" => 150}, "A2" => %{"v" => 50}}
          }
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      # the matched cell's CF fill/bold survive as a plain manual style…
      assert cell(imported, 0, "A1")["s"] == %{"bg" => "#ff0000", "b" => true}
      # …the unmatched cell gains no style…
      refute Map.has_key?(cell(imported, 0, "A2"), "s")
      # …and the RULE is gone (not exported as conditionalFormatting — CF-D2).
      refute Map.has_key?(hd(imported["tabs"]), "cond_formats")
    end
  end

  # ── tab color (QL-D7 — zip post-process round-trip) ─────────────────────────

  describe "tab color" do
    test "per-tab colors survive export → import (FF alpha stripped, lowercased)" do
      content = %{
        "tabs" => [
          %{"name" => "Red", "color" => "#ff0000", "cells" => %{"A1" => %{"v" => 1}}},
          %{"name" => "Green", "color" => "#00aa00", "cells" => %{"A1" => %{"v" => 2}}},
          %{"name" => "Plain", "cells" => %{"A1" => %{"v" => 3}}}
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert Enum.map(imported["tabs"], &Map.get(&1, "color")) == ["#ff0000", "#00aa00", nil]
      # the colored worksheet carries the ARGB tabColor; the plain one does not
      assert sheet_n_xml(binary, 1) =~ ~s(<tabColor rgb="FFFF0000"/>)
      assert sheet_n_xml(binary, 2) =~ ~s(<tabColor rgb="FF00AA00"/>)
      refute sheet_n_xml(binary, 3) =~ "tabColor"
    end

    test "the tabColor rides inside <sheetPr>, before <pageSetUpPr> (schema order)" do
      content = %{
        "tabs" => [%{"name" => "R", "color" => "#1a2b3c", "cells" => %{"A1" => %{"v" => 1}}}]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      xml = sheet_n_xml(binary, 1)

      assert xml =~ ~r{<sheetPr[^>]*><tabColor rgb="FF1A2B3C"/>}
      # tabColor must precede pageSetUpPr for a schema-valid sheetPr
      [_, before_page] = Regex.run(~r/(.*)<pageSetUpPr/s, xml)
      assert before_page =~ "tabColor"
    end

    test "a color-less doc exports with no <tabColor> and is byte-identical across exports" do
      content = %{
        "tabs" => [
          %{"name" => "A", "cells" => %{"A1" => %{"v" => 1}}},
          %{"name" => "B", "cells" => %{"A1" => %{"v" => 2}}}
        ]
      }

      {:ok, bin1} = XlsxExport.to_binary(content)
      {:ok, bin2} = XlsxExport.to_binary(content)

      refute sheet_n_xml(bin1, 1) =~ "tabColor"
      # no-color path skips the whole post-process → still deterministic bytes
      assert bin1 == bin2
    end

    test "a themed/indexed tabColor (no rgb) is ignored on import, never crashes" do
      content =
        package(
          ~s(<row r="1"><c r="A1" t="n"><v>1</v></c></row>),
          name: "Themed",
          sheet_pr: ~s(<sheetPr><tabColor theme="4" tint="0.4"/></sheetPr>)
        )
        |> import!()

      refute Map.has_key?(hd(content["tabs"]), "color")
      assert cell(content, 0, "A1") == %{"v" => 1}
    end

    test "an explicit-rgb tabColor from an Excel-authored sheet imports to #rrggbb" do
      content =
        package(
          ~s(<row r="1"><c r="A1" t="n"><v>1</v></c></row>),
          name: "Colored",
          sheet_pr: ~s(<sheetPr filterMode="false"><tabColor rgb="FF3366CC"/></sheetPr>)
        )
        |> import!()

      assert hd(content["tabs"])["color"] == "#3366cc"
    end
  end

  # Raw XML of the Nth worksheet (1-based) out of an exported package.
  defp sheet_n_xml(binary, n) do
    {:ok, entries} = :zip.extract(binary, [:memory])
    target = ~c"xl/worksheets/sheet#{n}.xml"
    {_name, xml} = Enum.find(entries, fn {name, _} -> name == target end)
    to_string(xml)
  end

  # ── tab-name locks (sanitize + case-insensitive dedupe on export) ───────────

  describe "tab-name locks" do
    test "two tabs sharing a name dedupe to Data / Data 2 with both cell sets intact" do
      content = %{
        "tabs" => [
          %{"name" => "Data", "cells" => %{"A1" => %{"v" => "first"}}},
          %{"name" => "Data", "cells" => %{"A1" => %{"v" => "second"}}}
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert Enum.map(imported["tabs"], & &1["name"]) == ["Data", "Data 2"]
      assert cell(imported, 0, "A1") == %{"v" => "first"}
      assert cell(imported, 1, "A1") == %{"v" => "second"}
    end

    test "illegal name chars are replaced with spaces" do
      content = %{"tabs" => [%{"name" => "Q1/Q2", "cells" => %{"A1" => %{"v" => 1}}}]}

      {:ok, binary} = XlsxExport.to_binary(content)

      assert [%{"name" => "Q1 Q2"}] = import!(binary)["tabs"]
    end

    test "names colliding only after the 31-char slice keep both tabs' data distinct" do
      base = String.duplicate("A", 31)
      # first 31 chars are identical to base, so both slice to the same name
      long = base <> "XYZ"

      content = %{
        "tabs" => [
          %{"name" => base, "cells" => %{"A1" => %{"v" => "one"}}},
          %{"name" => long, "cells" => %{"A1" => %{"v" => "two"}}}
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      [n1, n2] = Enum.map(imported["tabs"], & &1["name"])
      assert n1 == base
      assert n2 != n1
      assert String.length(n2) <= 31
      assert cell(imported, 0, "A1") == %{"v" => "one"}
      assert cell(imported, 1, "A1") == %{"v" => "two"}
    end
  end

  # ── AVG → AVERAGE dialect (export) ──────────────────────────────────────────

  describe "AVG dialect" do
    test "AVG is exported as AVERAGE and recomputes identically" do
      content = %{
        "tabs" => [
          %{
            "name" => "Avg",
            "cells" => %{
              "A1" => %{"v" => 2},
              "A2" => %{"v" => 4},
              "B1" => %{"f" => "AVG(A1:A2)", "v" => 3, "t" => "n"}
            }
          }
        ]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      # Exported as AVERAGE so Excel does not #NAME? on recalc.
      assert cell(imported, 0, "B1")["f"] == "AVERAGE(A1:A2)"

      recomputed = Engine.recompute(imported)

      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "B1"]) ==
               %{"f" => "AVERAGE(A1:A2)", "v" => 3, "t" => "n"}
    end

    test "AVG inside a string literal is left untouched" do
      content = %{
        "tabs" => [%{"name" => "Lit", "cells" => %{"A1" => %{"f" => ~S/AVG(A2:A3)&" AVG("/}}}]
      }

      {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert cell(imported, 0, "A1")["f"] == ~S/AVERAGE(A2:A3)&" AVG("/
    end
  end
end
