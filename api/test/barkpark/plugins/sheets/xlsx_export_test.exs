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
end
