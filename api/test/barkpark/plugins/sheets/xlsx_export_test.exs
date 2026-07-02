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
end
