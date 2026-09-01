defmodule Barkpark.SheetsTest do
  @moduledoc """
  Unit tests for `Barkpark.Plugins.Sheets.Core` — A1 helpers and snapshot synthesis.
  Pure functions, no DB.
  """
  use ExUnit.Case, async: true

  doctest Barkpark.Plugins.Sheets.Core

  alias Barkpark.Plugins.Sheets.Core, as: Sheets

  # ── parse_ref/1 ────────────────────────────────────────────────────────────

  describe "parse_ref/1" do
    test "single-letter columns" do
      assert Sheets.parse_ref("A1") == {:ok, {1, 1}}
      assert Sheets.parse_ref("B12") == {:ok, {2, 12}}
      assert Sheets.parse_ref("Z1") == {:ok, {26, 1}}
    end

    test "multi-letter columns (bijective base-26)" do
      assert Sheets.parse_ref("AA1") == {:ok, {27, 1}}
      assert Sheets.parse_ref("AZ5") == {:ok, {52, 5}}
      assert Sheets.parse_ref("BA1") == {:ok, {53, 1}}
    end

    test "lower-case is tolerated" do
      assert Sheets.parse_ref("a1") == {:ok, {1, 1}}
      assert Sheets.parse_ref("aa3") == {:ok, {27, 3}}
    end

    test "malformed addresses are rejected" do
      assert Sheets.parse_ref("A0") == :error
      assert Sheets.parse_ref("123") == :error
      assert Sheets.parse_ref("ABC") == :error
      assert Sheets.parse_ref("A1B") == :error
      assert Sheets.parse_ref("A 1") == :error
      assert Sheets.parse_ref("") == :error
    end

    test "non-binary input returns :error" do
      assert Sheets.parse_ref(nil) == :error
      assert Sheets.parse_ref(42) == :error
    end
  end

  # ── format_ref/1 ───────────────────────────────────────────────────────────

  describe "format_ref/1" do
    test "formats single- and multi-letter columns" do
      assert Sheets.format_ref({1, 1}) == "A1"
      assert Sheets.format_ref({26, 1}) == "Z1"
      assert Sheets.format_ref({27, 1}) == "AA1"
      assert Sheets.format_ref({52, 5}) == "AZ5"
    end

    test "round-trips through parse_ref" do
      for col <- [1, 13, 26, 27, 52, 53, 100, 703], row <- [1, 5, 99] do
        addr = Sheets.format_ref({col, row})

        result = Sheets.parse_ref(addr)

        assert match?({:ok, {^col, ^row}}, result),
               "round-trip failed for {#{col}, #{row}} -> #{addr}, got #{inspect(result)}"
      end
    end
  end

  # ── get_tab/2 ──────────────────────────────────────────────────────────────

  describe "get_tab/2" do
    test "returns the tab at the given 0-based index" do
      content = %{"tabs" => [%{"name" => "Sheet1"}, %{"name" => "Sheet2"}]}
      assert %{"name" => "Sheet1"} = Sheets.get_tab(content, 0)
      assert %{"name" => "Sheet2"} = Sheets.get_tab(content, 1)
    end

    test "returns nil when out of range, missing, or malformed" do
      assert Sheets.get_tab(%{"tabs" => [%{"name" => "Sheet1"}]}, 5) == nil
      assert Sheets.get_tab(%{}, 0) == nil
      assert Sheets.get_tab(nil, 0) == nil
      assert Sheets.get_tab(%{"tabs" => "nope"}, 0) == nil
    end

    test "a negative index never wraps around" do
      content = %{"tabs" => [%{"name" => "Sheet1"}, %{"name" => "Sheet2"}]}
      assert Sheets.get_tab(content, -1) == nil
    end
  end

  # ── snapshot_for/2 ─────────────────────────────────────────────────────────

  describe "snapshot_for/2 — empty / missing / malformed" do
    test "no tabs, empty cells, out-of-range tab, nil content" do
      assert Sheets.snapshot_for(%{}, 0) == %{"rows" => [], "sv" => 2}

      assert Sheets.snapshot_for(%{"tabs" => [%{"cells" => %{}}]}, 0) == %{
               "rows" => [],
               "sv" => 2
             }

      assert Sheets.snapshot_for(%{"tabs" => [%{"name" => "T"}]}, 5) == %{"rows" => [], "sv" => 2}
      assert Sheets.snapshot_for(nil, 0) == %{"rows" => [], "sv" => 2}
    end

    test "malformed cell entries are skipped, not raised on" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{
              "A1" => %{"v" => "kept"},
              "NOT-A1" => %{"v" => "dropped"},
              "B1" => "not-a-map"
            }
          }
        ]
      }

      assert Sheets.snapshot_for(content, 0) == %{"rows" => [["kept"]], "sv" => 2}
    end
  end

  describe "snapshot_for/2 — dense grid from sparse cells" do
    test "single cell A1" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "hello"}}}]}
      assert Sheets.snapshot_for(content, 0) == %{"rows" => [["hello"]], "sv" => 2}
    end

    test "2x2 grid without frozen rows has no head" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{
              "A1" => %{"v" => "r1c1"},
              "B1" => %{"v" => "r1c2"},
              "A2" => %{"v" => "r2c1"},
              "B2" => %{"v" => "r2c2"}
            }
          }
        ]
      }

      snap = Sheets.snapshot_for(content, 0)
      assert snap["rows"] == [["r1c1", "r1c2"], ["r2c1", "r2c2"]]
      refute Map.has_key?(snap, "head")
    end

    test "gaps in the sparse grid pad with empty strings" do
      content = %{
        "tabs" => [
          %{"cells" => %{"A1" => %{"v" => "x"}, "C3" => %{"v" => "y"}}}
        ]
      }

      assert Sheets.snapshot_for(content, 0) == %{
               "rows" => [["x", "", ""], ["", "", ""], ["", "", "y"]],
               "sv" => 2
             }
    end

    test "frozen_rows: 1 promotes row 1 to head" do
      content = %{
        "tabs" => [
          %{
            "frozen_rows" => 1,
            "cells" => %{
              "A1" => %{"v" => "Name"},
              "B1" => %{"v" => "Score"},
              "A2" => %{"v" => "Alice"},
              "B2" => %{"v" => 42}
            }
          }
        ]
      }

      snap = Sheets.snapshot_for(content, 0)
      assert snap["head"] == ["Name", "Score"]
      assert snap["rows"] == [["Alice", "42"]]
    end

    test "frozen_rows: \"1\" (schema stores strings) also promotes row 1" do
      content = %{
        "tabs" => [
          %{"frozen_rows" => "1", "cells" => %{"A1" => %{"v" => "H"}, "A2" => %{"v" => "D"}}}
        ]
      }

      snap = Sheets.snapshot_for(content, 0)
      assert snap["head"] == ["H"]
      assert snap["rows"] == [["D"]]
    end

    test "head-only sheet (frozen row 1 is the only occupied row) has empty rows" do
      content = %{
        "tabs" => [%{"frozen_rows" => 1, "cells" => %{"A1" => %{"v" => "Only"}}}]
      }

      snap = Sheets.snapshot_for(content, 0)
      assert snap["head"] == ["Only"]
      assert snap["rows"] == []
    end

    test "frozen_rows: 0 means no head" do
      content = %{"tabs" => [%{"frozen_rows" => 0, "cells" => %{"A1" => %{"v" => "val"}}}]}

      snap = Sheets.snapshot_for(content, 0)
      refute Map.has_key?(snap, "head")
      assert snap["rows"] == [["val"]]
    end

    test "multi-tab: tab picked by 0-based index" do
      content = %{
        "tabs" => [
          %{"name" => "Tab1", "cells" => %{"A1" => %{"v" => "tab1"}}},
          %{"name" => "Tab2", "cells" => %{"A1" => %{"v" => "tab2"}}}
        ]
      }

      assert %{"rows" => [["tab1"]]} = Sheets.snapshot_for(content, 0)
      assert %{"rows" => [["tab2"]]} = Sheets.snapshot_for(content, 1)
    end

    test "cell value types: number, bool, missing v" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{
              "A1" => %{"v" => 3.14},
              "B1" => %{"v" => true},
              "C1" => %{"v" => false},
              "D1" => %{"v" => nil},
              "E1" => %{"f" => "=SUM(A2:A3)"}
            }
          }
        ]
      }

      assert Sheets.snapshot_for(content, 0) == %{
               "rows" => [["3.14", "TRUE", "FALSE", "", ""]],
               "sv" => 2
             }
    end
  end

  describe "snapshot_for/2 — col_widths" do
    test "sparse widths map densifies to a 1..max_col list" do
      content = %{
        "tabs" => [
          %{
            "col_widths" => %{"1" => 80, "2" => 120},
            "cells" => %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}}
          }
        ]
      }

      assert Sheets.snapshot_for(content, 0)["col_widths"] == [80, 120]
    end

    test "gaps in the widths map fill with zeros" do
      content = %{
        "tabs" => [
          %{
            "col_widths" => %{"1" => 50},
            "cells" => %{"A1" => %{"v" => "a"}, "C1" => %{"v" => "c"}}
          }
        ]
      }

      assert Sheets.snapshot_for(content, 0)["col_widths"] == [50, 0, 0]
    end

    test "empty or useless widths maps are omitted" do
      base = %{"cells" => %{"A1" => %{"v" => "x"}}}

      for widths <- [%{}, %{"9" => 40}, %{"1" => "wide"}, "not-a-map"] do
        content = %{"tabs" => [Map.put(base, "col_widths", widths)]}

        refute Map.has_key?(Sheets.snapshot_for(content, 0), "col_widths"),
               "expected col_widths omitted for #{inspect(widths)}"
      end
    end
  end
end
