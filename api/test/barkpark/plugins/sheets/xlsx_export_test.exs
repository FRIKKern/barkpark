defmodule Barkpark.Plugins.Sheets.XlsxExportTest do
  @moduledoc """
  Unit tests for XlsxExport.to_binary/2 — export-side behaviour.

  Pure unit, no DB. Covers:
    * empty/missing tabs produce a valid xlsx binary with one default sheet
    * a single tab with cells produces a parseable xlsx binary
    * formula cells with a cached numeric value encode without error
    * date cells encode without error (serial conversion path)
    * garbage/non-map content returns {:error, _} rather than raising
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.XlsxExport
  alias Barkpark.Plugins.Sheets.XlsxImport

  defp import!(binary) do
    {:ok, content} = XlsxImport.to_content(binary)
    content
  end

  # ── to_binary/2 ──────────────────────────────────────────────────────────────

  describe "to_binary/2" do
    test "empty content map returns {:ok, binary} with a single default sheet" do
      assert {:ok, binary} = XlsxExport.to_binary(%{})
      assert is_binary(binary)
      assert byte_size(binary) > 0

      content = import!(binary)
      assert [%{"name" => "Sheet1"}] = content["tabs"]
    end

    test "missing tabs key is treated the same as empty tabs" do
      assert {:ok, binary} = XlsxExport.to_binary(%{"other" => "data"})
      content = import!(binary)
      assert length(content["tabs"]) == 1
    end

    test "a tab with string and numeric cells produces a parseable workbook" do
      content = %{
        "tabs" => [
          %{
            "name" => "Test",
            "cells" => %{
              "A1" => %{"v" => "hello"},
              "B1" => %{"v" => 42},
              "C1" => %{"v" => 3.14}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert [%{"name" => "Test", "cells" => cells}] = imported["tabs"]
      assert cells["A1"] == %{"v" => "hello"}
      assert cells["B1"] == %{"v" => 42}
      assert cells["C1"] == %{"v" => 3.14}
    end

    test "formula cell with cached numeric value encodes without error" do
      content = %{
        "tabs" => [
          %{
            "name" => "Calc",
            "cells" => %{
              "A1" => %{"v" => 10},
              "B1" => %{"v" => 20},
              "C1" => %{"f" => "SUM(A1:B1)", "v" => 30, "t" => "n"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      # The formula and its cached value survive the export→import trip
      c1 = get_in(imported, ["tabs", Access.at(0), "cells", "C1"])
      assert c1["f"] == "SUM(A1:B1)"
      assert c1["v"] == 30
    end

    # #NAME? is an error VALUE like every other `t: "e"` code — a LITERAL error
    # cell is written verbatim, so it leaves Barkpark as the error string rather
    # than as a silent blank. (A FORMULA cell's string cached value is the
    # pre-existing documented drop — an xlsx formula cell carries a numeric <v>
    # only — and #NAME? is not special there; see the "documented drops" suite
    # in xlsx_roundtrip_test.)
    test "a literal #NAME? cell survives the export -> import round trip verbatim" do
      content = %{
        "tabs" => [
          %{
            "name" => "Err",
            "cells" => %{
              "A1" => %{"v" => "Label"},
              "B1" => %{"v" => "#NAME?", "t" => "e"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      b1 = get_in(import!(binary), ["tabs", Access.at(0), "cells", "B1"])

      assert b1["v"] == "#NAME?"
    end

    test "date cell encodes without error and the value survives as a date" do
      content = %{
        "tabs" => [
          %{
            "name" => "Dates",
            "cells" => %{
              "A1" => %{"v" => "2024-03-15", "t" => "date", "fmt" => "date"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      a1 = get_in(imported, ["tabs", Access.at(0), "cells", "A1"])
      assert a1["t"] == "date"
      assert a1["v"] == "2024-03-15"
    end

    test "a far cell (XFD1048576) is clamped, not densified into an OOM" do
      # A1 plus the far corner of the Excel grid. Without the two-axis cap this
      # densifies to ~17.2B positions and OOMs the node; clamped it completes
      # fast and bounded.
      content = %{
        "tabs" => [
          %{
            "name" => "Huge",
            "cells" => %{
              "A1" => %{"v" => 1},
              "XFD1048576" => %{"v" => 1}
            }
          }
        ]
      }

      task = Task.async(fn -> XlsxExport.to_binary(content) end)
      assert {:ok, {:ok, bin}} = Task.yield(task, 30_000) || Task.shutdown(task)
      assert is_binary(bin)
      assert byte_size(bin) > 0
    end

    test "tab name longer than 31 chars is truncated to 31" do
      long_name = String.duplicate("X", 40)

      content = %{
        "tabs" => [%{"name" => long_name, "cells" => %{"A1" => %{"v" => 1}}}]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)

      assert [%{"name" => name}] = imported["tabs"]
      assert String.length(name) == 31
    end
  end

  # PART C — engine-only functions (no Excel spelling) and non-numeric cached
  # values. Exported as a formula they open `#NAME?` and the computed value is
  # lost; exported as their literal value (the CSV posture) the value survives.
  describe "engine-only functions and non-numeric cached values" do
    defp c1(imported), do: get_in(imported, ["tabs", Access.at(0), "cells", "C1"])

    test "a SPARKLINE cell exports its bar string as a literal, not a #NAME? formula" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{"C1" => %{"f" => "=SPARKLINE(A1:B1)", "v" => "▁▅█", "t" => "s"}}
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      c1 = c1(import!(binary))

      assert c1["v"] == "▁▅█"
      # exported as a value, NOT a formula — no <f>SPARKLINE for Excel to choke on
      refute Map.has_key?(c1, "f")
    end

    test "a COUNTUNIQUE cell exports its number as a literal" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{"C1" => %{"f" => "COUNTUNIQUE(A1:A4)", "v" => 3, "t" => "n"}}
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      c1 = c1(import!(binary))

      assert c1["v"] == 3
      refute Map.has_key?(c1, "f")
    end

    test "a COUNTUNIQUE nested in arithmetic (2*COUNTUNIQUE) exports the literal, not #NAME?" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{
              "A1" => %{"v" => 1},
              "A2" => %{"v" => 3},
              "C1" => %{"f" => "2*COUNTUNIQUE(A1:A2)", "v" => 4, "t" => "n"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      xml = sheet1_xml(binary)

      # the engine-only name must not reach Excel in any form
      refute xml =~ "COUNTUNIQUE"

      # the cell is a plain cached-value literal: <v>4</v>, no <f>
      cell = cell_element(xml, "C1")
      assert cell =~ "<v>4</v>"
      refute cell =~ "<f"
    end

    test "a COUNTUNIQUE nested inside IF exports the literal, not #NAME?" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{
              "A1" => %{"v" => 1},
              "A2" => %{"v" => 5},
              "C1" => %{"f" => "IF(A1>0,COUNTUNIQUE(A1:A2),0)", "v" => 2, "t" => "n"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      xml = sheet1_xml(binary)

      refute xml =~ "COUNTUNIQUE"

      cell = cell_element(xml, "C1")
      assert cell =~ "<v>2</v>"
      refute cell =~ "<f"
    end

    test "COUNTUNIQUE( only inside a string literal still exports its formula untouched" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{
              "A1" => %{"v" => 7},
              "C1" => %{
                "f" => ~s[CONCAT("COUNTUNIQUE(x)",A1)],
                "v" => "COUNTUNIQUE(x)7",
                "t" => "s"
              }
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      xml = sheet1_xml(binary)

      cell = cell_element(xml, "C1")
      assert cell =~ ~s[<f>CONCAT("COUNTUNIQUE(x)",A1)</f>]
    end

    test "a real-Excel formula with a string cached value keeps its formula" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{
              "A1" => %{"v" => "hi"},
              "C1" => %{"f" => ~s(A1&"x"), "v" => "hix", "t" => "s"}
            }
          }
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      c1 = c1(import!(binary))

      # a non-engine-only function stays a formula (Excel recomputes it)
      assert c1["f"] == ~s(A1&"x")
    end

    # Raw worksheet XML out of the xlsx zip — lets tests assert on the exact
    # bytes Excel will read (<f> vs <v>), not just the round-trip view.
    defp sheet1_xml(binary) do
      {:ok, entries} = :zip.extract(binary, [:memory])

      {_name, xml} =
        Enum.find(entries, fn {name, _} ->
          List.to_string(name) == "xl/worksheets/sheet1.xml"
        end)

      xml
    end

    defp cell_element(xml, ref) do
      [element] = Regex.run(~r/<c r="#{ref}"[^>]*>.*?<\/c>/s, xml)
      element
    end
  end

  # PART CF-D — conditional-format styles bake into the exported cell.
  # The stored tab `"cond_formats"` rules are evaluated (kernel-only, no forked
  # eval) and composed with the manual `"s"` at export; the RULES are not
  # exported as conditionalFormatting XML (CF-D2), so a re-import reads the
  # baked fill as a plain manual style (pinned in xlsx_roundtrip_test.exs).
  describe "conditional formatting bakes into exported cells" do
    defp c(imported, addr), do: get_in(imported, ["tabs", Access.at(0), "cells", addr])

    defp export_import(content) do
      assert {:ok, binary} = XlsxExport.to_binary(content)
      import!(binary)
    end

    test "a gt rule fills + bolds the matched cell; the unmatched cell keeps neither (CF-D5)" do
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "cond_formats" => [
              %{
                "id" => "r1",
                "range" => "B1:B2",
                "when" => %{"op" => "gt", "value" => 100},
                "style" => %{"bg" => "#ff0000", "b" => true}
              }
            ],
            "cells" => %{"B1" => %{"v" => 150}, "B2" => %{"v" => 50}}
          }
        ]
      }

      imported = export_import(content)

      # matched: the CF fill + bold are baked into the exported cell
      assert c(imported, "B1")["s"]["bg"] == "#ff0000"
      assert c(imported, "B1")["s"]["b"] == true

      # unmatched: no CF contribution — no bg, no bold (no ghost style)
      refute get_in(c(imported, "B2"), ["s", "bg"])
      refute get_in(c(imported, "B2"), ["s", "b"])
    end

    test "CF composes over a manual style: CF wins bg, manual al + b survive (CF-D3)" do
      # The rule sets ONLY bg, so the manual bold and alignment must survive.
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "cond_formats" => [
              %{
                "id" => "r1",
                "range" => "A1",
                "when" => %{"op" => "gt", "value" => 100},
                "style" => %{"bg" => "#00ff00"}
              }
            ],
            "cells" => %{"A1" => %{"v" => 150, "s" => %{"al" => "center", "b" => true}}}
          }
        ]
      }

      s = c(export_import(content), "A1")["s"]

      # CF wins the bg it set…
      assert s["bg"] == "#00ff00"
      # …and the manual keys the rule did NOT set survive unchanged
      assert s["al"] == "center"
      assert s["b"] == true
    end

    test "first matching rule wins under overlapping ranges (CF-D4, no stacking)" do
      # A1 sits in both ranges and satisfies both conditions; the FIRST rule in
      # list order supplies the whole CF contribution.
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "cond_formats" => [
              %{
                "id" => "first",
                "range" => "A1:A3",
                "when" => %{"op" => "gt", "value" => 10},
                "style" => %{"bg" => "#ff0000"}
              },
              %{
                "id" => "second",
                "range" => "A1:A5",
                "when" => %{"op" => "gt", "value" => 10},
                "style" => %{"bg" => "#0000ff"}
              }
            ],
            "cells" => %{"A1" => %{"v" => 50}}
          }
        ]
      }

      assert c(export_import(content), "A1")["s"]["bg"] == "#ff0000"
    end

    test "malformed cond_formats never raises — export succeeds, cells unstyled (CF-D5 totality)" do
      # A non-list value, and a list of garbage entries, both flow through the
      # lenient kernel to [] rather than blowing up the export.
      for bad <- ["not a list", 42, [%{"garbage" => 1}, "string", 7, nil]] do
        content = %{
          "tabs" => [%{"name" => "CF", "cond_formats" => bad, "cells" => %{"A1" => %{"v" => 5}}}]
        }

        assert {:ok, binary} = XlsxExport.to_binary(content)
        assert is_binary(binary)
        # the cell exports as a plain value — no style crept in
        refute Map.has_key?(c(import!(binary), "A1"), "s")
      end
    end

    test "no-rules content exports byte-identically to before (empty compose is a true no-op)" do
      # A doc carrying manual styles but no CF rules. The compose call collapses
      # to the manual style, so the bytes must match the SAME doc exported with
      # (a) no cond_formats key, (b) an empty list, and (c) a rule that matches
      # NOTHING — every no-match path must leave the export identical.
      base_cells = %{
        "A1" => %{"v" => "Header", "s" => %{"b" => true, "bg" => "#eeeeee"}},
        "A2" => %{"v" => 42},
        "A3" => %{"v" => "plain", "s" => %{"al" => "right"}}
      }

      no_key = %{"tabs" => [%{"name" => "T", "cells" => base_cells}]}
      empty_list = %{"tabs" => [%{"name" => "T", "cells" => base_cells, "cond_formats" => []}]}

      non_matching = %{
        "tabs" => [
          %{
            "name" => "T",
            "cells" => base_cells,
            "cond_formats" => [
              %{
                "id" => "never",
                "range" => "A1:A3",
                "when" => %{"op" => "gt", "value" => 999_999},
                "style" => %{"bg" => "#ff0000"}
              }
            ]
          }
        ]
      }

      assert {:ok, bin_no_key} = XlsxExport.to_binary(no_key)
      assert {:ok, bin_empty} = XlsxExport.to_binary(empty_list)
      assert {:ok, bin_non_match} = XlsxExport.to_binary(non_matching)

      assert bin_empty == bin_no_key
      assert bin_non_match == bin_no_key
    end

    test "CF applies on a frozen head row too (CF-AM2 — CF follows manual on all rows)" do
      # xlsx emits manual styles on every row including a frozen head; CF rides
      # the same path, so a rule over row 1 bakes into the exported head cell.
      content = %{
        "tabs" => [
          %{
            "name" => "CF",
            "frozen_rows" => 1,
            "cond_formats" => [
              %{
                "id" => "head",
                "range" => "A1:A1",
                "when" => %{"op" => "gt", "value" => 0},
                "style" => %{"bg" => "#123456"}
              }
            ],
            "cells" => %{"A1" => %{"v" => 5}}
          }
        ]
      }

      assert c(export_import(content), "A1")["s"]["bg"] == "#123456"
    end
  end

  # PART QR-C — deterministic export timestamps. The xlsx binary carries two
  # wall-clock stamps (docProps/core.xml dates at 1s resolution; the ZIP DOS
  # mod-time in every header at 2s resolution) that made "export twice, compare"
  # tests flake across a clock tick. Both are now pinned, so identical content
  # exports to identical bytes. These probes assert the FIXED values directly —
  # they fail deterministically on the old wall-clock code, not just when two
  # exports happen to straddle a tick.
  describe "deterministic export timestamps (QR-C)" do
    # The pinned constants (mirror of the export module's private attributes).
    @fixed_core_timestamp "2020-01-01T00:00:00Z"
    # DOS time 0x0000 (00:00:00) + date 0x0021 (1980-01-01), little-endian.
    @fixed_dos_datetime <<0x00, 0x00, 0x21, 0x00>>

    defp export!(content) do
      assert {:ok, binary} = XlsxExport.to_binary(content)
      binary
    end

    defp sample_content do
      %{
        "tabs" => [
          %{
            "name" => "Det",
            "cells" => %{
              "A1" => %{"v" => "Header", "s" => %{"b" => true, "bg" => "#eeeeee"}},
              "B1" => %{"v" => 42},
              "C1" => %{"f" => "SUM(A1:B1)", "v" => 30, "t" => "n"}
            }
          },
          %{"name" => "Two", "cells" => %{"A1" => %{"v" => 7}}}
        ]
      }
    end

    test "(a) docProps/core.xml carries the fixed timestamp, not the wall clock" do
      {:ok, entries} = :zip.extract(export!(sample_content()), [:memory])

      {_name, core_xml} =
        Enum.find(entries, fn {name, _} -> List.to_string(name) == "docProps/core.xml" end)

      # :zip.extract returns file CONTENT as a binary (names stay charlists).
      assert core_xml =~ @fixed_core_timestamp
      # dcterms:created AND dcterms:modified both pinned — no current-year stamp.
      refute core_xml =~ "#{Date.utc_today().year}"
    end

    test "(b) every LFH and CDH mod time/date field equals the fixed DOS constant" do
      datetimes = zip_header_datetimes(export!(sample_content()))

      # A real multi-member workbook: worksheets, workbook.xml, styles, rels,
      # content types, docProps — so this is a meaningful sample, not one entry.
      assert length(datetimes) >= 2 * 6

      for dt <- datetimes, do: assert(dt == @fixed_dos_datetime)
    end

    test "(c) exporting identical content twice is byte-identical (umbrella pin)" do
      content = sample_content()
      assert export!(content) == export!(content)
    end

    test "the exported binary is still a valid, re-importable xlsx after patching" do
      # The byte surgery must not corrupt the ZIP — :zip.extract + a real import
      # round-trip is the loud tripwire (mirrors xlsx_roundtrip_test.exs).
      imported = import!(export!(sample_content()))
      assert [%{"name" => "Det"}, %{"name" => "Two"}] = imported["tabs"]
      assert get_in(imported, ["tabs", Access.at(0), "cells", "B1"]) == %{"v" => 42}
    end

    # Structural ZIP walk: from the EOCD, follow the central directory and, for
    # each entry, read the CDH mod time/date (offset 12) and the member's LFH
    # mod time/date (offset 10, via the CDH's relative-offset field at 42).
    # Independent of the production walk, so it can catch a bug in it.
    defp zip_header_datetimes(binary) do
      {cd_offset, count} = read_eocd!(binary)
      collect_cdh(binary, cd_offset, count, [])
    end

    defp read_eocd!(binary) do
      # Last occurrence of the EOCD signature (no comment in elixlsx output, so
      # it is the final 22 bytes, but scan to be safe).
      pos = last_index(binary, <<0x50, 0x4B, 0x05, 0x06>>)

      <<_::binary-size(pos), 0x50, 0x4B, 0x05, 0x06, _::binary-size(6), total_entries::little-16,
        _cd_size::little-32, cd_offset::little-32, _::binary>> = binary

      {cd_offset, total_entries}
    end

    defp collect_cdh(_binary, _offset, 0, acc), do: Enum.reverse(acc)

    defp collect_cdh(binary, offset, remaining, acc) do
      <<_::binary-size(offset), 0x50, 0x4B, 0x01, 0x02, _::binary-size(8), cdh_dt::binary-size(4),
        _::binary-size(12), fname_len::little-16, extra_len::little-16, comment_len::little-16,
        _::binary-size(8), lfh_offset::little-32, _::binary>> = binary

      <<_::binary-size(lfh_offset), 0x50, 0x4B, 0x03, 0x04, _::binary-size(6),
        lfh_dt::binary-size(4), _::binary>> = binary

      next = offset + 46 + fname_len + extra_len + comment_len
      collect_cdh(binary, next, remaining - 1, [lfh_dt, cdh_dt | acc])
    end

    defp last_index(binary, needle) do
      binary
      |> :binary.matches(needle)
      |> List.last()
      |> elem(0)
    end
  end

  # PART QL-D7 — tab color. A per-tab `"color"` (#rrggbb) is stamped into the
  # worksheet's <sheetPr> as <tabColor rgb="FFRRGGBB"/> by a zip post-process
  # (elixlsx has no tab-color knob). A color-less doc skips the whole
  # post-process and stays byte-identical to today.
  describe "tab color (QL-D7)" do
    defp sheet_n_xml(binary, n) do
      {:ok, entries} = :zip.extract(binary, [:memory])
      target = ~c"xl/worksheets/sheet#{n}.xml"
      {_name, xml} = Enum.find(entries, fn {name, _} -> name == target end)
      # :zip.extract returns member CONTENT as a binary (names stay charlists).
      to_string(xml)
    end

    test "a colored tab stamps <tabColor rgb=FF…> in its worksheet's <sheetPr>" do
      content = %{
        "tabs" => [%{"name" => "Red", "color" => "#ff0000", "cells" => %{"A1" => %{"v" => 1}}}]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      assert sheet_n_xml(binary, 1) =~ ~s(<tabColor rgb="FFFF0000"/>)
    end

    test "an invalid color value is skipped (no tabColor, no crash)" do
      for bad <- ["#ggg", "red", "#12345", 42, nil] do
        content = %{
          "tabs" => [%{"name" => "T", "color" => bad, "cells" => %{"A1" => %{"v" => 1}}}]
        }

        assert {:ok, binary} = XlsxExport.to_binary(content)
        refute sheet_n_xml(binary, 1) =~ "tabColor"
      end
    end

    test "a no-color doc is byte-identical to the SAME doc exported without the post-process path" do
      # A doc carrying no "color" on any tab must take the current export path
      # untouched — proven by (a) no tabColor in the bytes and (b) an identical
      # binary to a re-export (the QR-C determinism the post-process preserves).
      content = %{
        "tabs" => [
          %{"name" => "A", "cells" => %{"A1" => %{"v" => 1}}},
          %{"name" => "B", "cells" => %{"A1" => %{"v" => 2}}}
        ]
      }

      assert {:ok, bin1} = XlsxExport.to_binary(content)
      assert {:ok, bin2} = XlsxExport.to_binary(content)

      refute sheet_n_xml(bin1, 1) =~ "tabColor"
      assert bin1 == bin2
    end

    test "a colored export is still deterministic (rezip is a pure function of content)" do
      content = %{
        "tabs" => [%{"name" => "C", "color" => "#1a2b3c", "cells" => %{"A1" => %{"v" => 1}}}]
      }

      assert {:ok, bin1} = XlsxExport.to_binary(content)
      assert {:ok, bin2} = XlsxExport.to_binary(content)
      assert bin1 == bin2
    end

    test "the rezipped colored package remains a valid, re-importable xlsx" do
      content = %{
        "tabs" => [
          %{"name" => "C", "color" => "#00aa00", "cells" => %{"A1" => %{"v" => 5}}}
        ]
      }

      assert {:ok, binary} = XlsxExport.to_binary(content)
      imported = import!(binary)
      assert hd(imported["tabs"])["color"] == "#00aa00"
      assert get_in(imported, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => 5}
    end
  end
end
