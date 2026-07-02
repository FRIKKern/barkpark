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

      assert get_in(recomputed, ["tabs", Access.at(0), "cells", "A1"]) ==
               %{"f" => "NPV(0.1,A2:A9)", "v" => 123.45, "stale" => true}
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
    {:ok, entries} = :zip.extract(binary, [:memory])

    patched =
      Enum.map(entries, fn
        {~c"xl/worksheets/sheet1.xml" = name, xml} ->
          xml =
            xml
            |> to_string()
            |> String.replace("<sheetData", cols_xml <> "<sheetData", global: false)

          {name, xml}

        entry ->
          entry
      end)

    {:ok, {_name, out}} = :zip.create(~c"t.xlsx", patched, [:memory])
    out
  end

  # Minimal hand-built package carrying a cell ref beyond the grid bounds —
  # elixlsx (correctly) cannot produce one.
  defp hostile_xlsx do
    sheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        <row r="1">
          <c r="A1" t="n"><v>1</v></c>
          <c r="ZZZZ1" t="n"><v>9</v></c>
        </row>
      </sheetData>
    </worksheet>
    """

    workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="Hostile" sheetId="1" r:id="rId1"/></sheets>
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

    {:ok, {_name, binary}} = :zip.create(~c"hostile.xlsx", files, [:memory])
    binary
  end

  # ── fmt vocabulary ──────────────────────────────────────────────────────────

  describe "Fmt" do
    test "every canonical export format classifies back to its own class" do
      for fmt <- Fmt.vocabulary() do
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

    test "empty content exports to a valid single-sheet workbook" do
      {:ok, binary} = XlsxExport.to_binary(%{})
      assert %{"tabs" => [%{"name" => "Sheet1"}]} = import!(binary)
    end
  end
end
