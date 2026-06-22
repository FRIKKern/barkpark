defmodule Barkpark.Plugins.Sheets.StructureTest do
  @moduledoc """
  Pure-function locks for `Barkpark.Plugins.Sheets.Structure` — the Excel
  ref-shift matrix (`rewrite_formula/3`: refs before/at/after the change
  point, ranges spanning, deletes producing literal `#REF!`, quoted-string
  literals never rewritten, `$A$1` shifting like `A1`), the tab-level
  rewrites (cell keys, merges, `row_heights`/`col_widths`, frozen bands),
  the grid-bounds insert cap, and the layout setters.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Structure

  # ── rewrite_formula: rows, insert ───────────────────────────────────────────

  describe "rewrite_formula — insert rows" do
    test "refs before the insert point stay verbatim" do
      assert Structure.rewrite_formula("A1+A2", :row, {:insert, 3, 2}) == "A1+A2"
    end

    test "a ref AT the insert point shifts by count" do
      assert Structure.rewrite_formula("A3*2", :row, {:insert, 3, 2}) == "A5*2"
    end

    test "refs after the insert point shift by count" do
      assert Structure.rewrite_formula("A7-1", :row, {:insert, 3, 2}) == "A9-1"
    end

    test "a range spanning the insert point expands" do
      assert Structure.rewrite_formula("SUM(A1:A5)", :row, {:insert, 3, 2}) == "SUM(A1:A7)"
    end

    test "a range entirely below the insert point shifts whole" do
      assert Structure.rewrite_formula("SUM(A4:A6)", :row, {:insert, 2, 1}) == "SUM(A5:A7)"
    end

    test "quoted-string literals are NEVER rewritten — escapes included" do
      f = "IF(A2>0,\"A1 ok\",\"B2 \"\"quoted\"\" lit\")&C4"

      assert Structure.rewrite_formula(f, :row, {:insert, 1, 1}) ==
               "IF(A3>0,\"A1 ok\",\"B2 \"\"quoted\"\" lit\")&C5"
    end

    test "$A$1 is treated as A1 (the engine convention) — markers survive a shift" do
      assert Structure.rewrite_formula("$A$3+1", :row, {:insert, 2, 1}) == "$A$4+1"
      assert Structure.rewrite_formula("$A$1*2", :row, {:insert, 2, 1}) == "$A$1*2"
    end

    test "a ref-shaped word followed by ( is a function name, not a ref" do
      assert Structure.rewrite_formula("LOG10(A3)", :row, {:insert, 1, 1}) == "LOG10(A4)"
    end

    test "whitespace is preserved, including inside a range" do
      assert Structure.rewrite_formula("A1 + A9", :row, {:insert, 5, 1}) == "A1 + A10"
      assert Structure.rewrite_formula("SUM(A1 : A5)", :row, {:insert, 3, 2}) == "SUM(A1 : A7)"
    end

    test "a ref shifted past the grid row bound becomes literal #REF!" do
      assert Structure.rewrite_formula("A1048576+1", :row, {:insert, 1, 1}) == "#REF!+1"
    end

    test "mixed-format range corners shift per corner, each keeping its own text" do
      assert Structure.rewrite_formula("SUM($A$2:B5)", :row, {:insert, 3, 1}) == "SUM($A$2:B6)"
    end
  end

  # ── rewrite_formula: rows, delete ───────────────────────────────────────────

  describe "rewrite_formula — delete rows" do
    test "a ref INTO the deleted span becomes the literal #REF! in the string" do
      assert Structure.rewrite_formula("A3*2", :row, {:delete, 2, 3}) == "#REF!*2"
    end

    test "refs after the span shift back; refs before stay verbatim" do
      assert Structure.rewrite_formula("A9", :row, {:delete, 2, 3}) == "A6"
      assert Structure.rewrite_formula("A1", :row, {:delete, 2, 3}) == "A1"
    end

    test "a range fully inside the span becomes #REF!" do
      assert Structure.rewrite_formula("SUM(A2:A4)", :row, {:delete, 1, 5}) == "SUM(#REF!)"
    end

    test "a range clipped at its head re-anchors at the deletion point" do
      assert Structure.rewrite_formula("SUM(A2:A10)", :row, {:delete, 1, 3}) == "SUM(A1:A7)"
    end

    test "a range clipped at its tail ends just before the span" do
      assert Structure.rewrite_formula("SUM(A2:A6)", :row, {:delete, 5, 4}) == "SUM(A2:A4)"
    end

    test "a range straddling the whole span shrinks by count" do
      assert Structure.rewrite_formula("SUM(A1:A10)", :row, {:delete, 3, 2}) == "SUM(A1:A8)"
    end

    test "a clipped range re-emits canonical $-less corners" do
      assert Structure.rewrite_formula("SUM($A$2:$A$10)", :row, {:delete, 1, 3}) == "SUM(A1:A7)"
    end

    test "a quoted literal that looks like the dead ref stays put" do
      assert Structure.rewrite_formula(~s("A3"&A3), :row, {:delete, 3, 1}) == ~s("A3"&#REF!)
    end
  end

  # ── rewrite_formula: cols ───────────────────────────────────────────────────

  describe "rewrite_formula — columns" do
    test "insert cols shifts column letters at/after the insert point" do
      assert Structure.rewrite_formula("SUM(B1:D1)", :col, {:insert, 2, 1}) == "SUM(C1:E1)"
      assert Structure.rewrite_formula("A1+B1", :col, {:insert, 2, 1}) == "A1+C1"
    end

    test "delete cols: dead ref, shift-back, untouched" do
      assert Structure.rewrite_formula("B2*2", :col, {:delete, 2, 1}) == "#REF!*2"
      assert Structure.rewrite_formula("D2", :col, {:delete, 2, 1}) == "C2"
      assert Structure.rewrite_formula("A2", :col, {:delete, 2, 1}) == "A2"
    end

    test "delete cols clips a partially covered range" do
      assert Structure.rewrite_formula("SUM(A1:D1)", :col, {:delete, 2, 2}) == "SUM(A1:B1)"
    end

    test "a row op never touches the column axis and vice versa" do
      assert Structure.rewrite_formula("B2", :row, {:delete, 3, 1}) == "B2"
      assert Structure.rewrite_formula("B2", :col, {:delete, 3, 1}) == "B2"
    end
  end

  # ── tab rewrites: rows ──────────────────────────────────────────────────────

  describe "insert_rows/3" do
    test "cell keys shift, formulas rewrite, merges/heights re-key, frozen stays" do
      tab = %{
        "name" => "T",
        "cells" => %{
          "A1" => %{"v" => 1},
          "A2" => %{"v" => 2},
          "B2" => %{"f" => "A1+A2"}
        },
        "merges" => ["A2:B3"],
        "row_heights" => %{"1" => 20, "2" => 30},
        "frozen_rows" => "1"
      }

      {:ok, out} = Structure.insert_rows(tab, 2, 1)

      assert out["cells"] == %{
               "A1" => %{"v" => 1},
               "A3" => %{"v" => 2},
               "B3" => %{"f" => "A1+A3"}
             }

      assert out["merges"] == ["A3:B4"]
      assert out["row_heights"] == %{"1" => 20, "3" => 30}
      assert out["frozen_rows"] == "1"
    end

    test "a merge spanning the insert point expands" do
      {:ok, out} = Structure.insert_rows(%{"cells" => %{}, "merges" => ["A2:B3"]}, 3, 1)
      assert out["merges"] == ["A2:B4"]
    end

    test "an insert that would push occupied cells past the grid bounds errors cleanly" do
      tab = %{"cells" => %{"A1048576" => %{"v" => "edge"}}}
      assert {:error, "grid_bounds_exceeded", _} = Structure.insert_rows(tab, 1, 1)
      # …but inserting BELOW the occupied edge is fine.
      assert {:error, "grid_bounds_exceeded", _} = Structure.insert_rows(tab, 1_048_576, 1)
      {:ok, _} = Structure.insert_rows(%{"cells" => %{"A5" => %{"v" => 1}}, "merges" => []}, 6, 10)
    end

    test "invalid at/count error cleanly" do
      assert {:error, "invalid_at", _} = Structure.insert_rows(%{}, 0, 1)
      assert {:error, "invalid_at", _} = Structure.insert_rows(%{}, "x", 1)
      assert {:error, "invalid_at", _} = Structure.insert_rows(%{}, 1_048_577, 1)
      assert {:error, "invalid_count", _} = Structure.insert_rows(%{}, 1, 0)
      assert {:error, "invalid_count", _} = Structure.delete_rows(%{}, 1, nil)
    end
  end

  describe "delete_rows/3" do
    test "cells in the span drop, later keys shift back, formulas gain #REF!" do
      tab = %{
        "cells" => %{
          "A1" => %{"v" => 1},
          "A2" => %{"v" => 2},
          "A3" => %{"v" => 3},
          "B3" => %{"f" => "A2*2"}
        }
      }

      {:ok, out} = Structure.delete_rows(tab, 2, 1)

      assert out["cells"] == %{
               "A1" => %{"v" => 1},
               "A2" => %{"v" => 3},
               "B2" => %{"f" => "#REF!*2"}
             }
    end

    test "merges clip, fully-deleted and single-cell remnants drop" do
      tab = %{
        "cells" => %{},
        "merges" => ["A1:A2", "A1:B3", "A4:B5"]
      }

      # Deleting row 2: A1:A2 clips to the single cell A1:A1 → dropped;
      # A1:B3 clips to A1:B2; A4:B5 shifts whole to A3:B4.
      {:ok, out} = Structure.delete_rows(tab, 2, 1)
      assert out["merges"] == ["A1:B2", "A3:B4"]

      # Deleting rows 1..3 swallows A1:B3 entirely → dropped.
      {:ok, out2} = Structure.delete_rows(tab, 1, 3)
      assert out2["merges"] == ["A1:B2"]
    end

    test "row_heights drop in-span keys and re-key the rest" do
      tab = %{"cells" => %{}, "row_heights" => %{"1" => 18, "2" => 30, "5" => 44}}
      {:ok, out} = Structure.delete_rows(tab, 2, 2)
      assert out["row_heights"] == %{"1" => 18, "3" => 44}
    end

    test "frozen_rows shrinks by its overlap with the span, preserving the stored type" do
      {:ok, out} = Structure.delete_rows(%{"cells" => %{}, "frozen_rows" => "3"}, 2, 5)
      assert out["frozen_rows"] == "1"

      {:ok, out2} = Structure.delete_rows(%{"cells" => %{}, "frozen_rows" => 3}, 1, 10)
      assert out2["frozen_rows"] == 0

      # A delete entirely below the band leaves it untouched.
      {:ok, out3} = Structure.delete_rows(%{"cells" => %{}, "frozen_rows" => 2}, 5, 3)
      assert out3["frozen_rows"] == 2
    end
  end

  # ── tab rewrites: cols ──────────────────────────────────────────────────────

  describe "insert_cols/3 and delete_cols/3" do
    test "cell keys shift on the column axis; col_widths re-key; frozen_cols clamps" do
      tab = %{
        "cells" => %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}, "C1" => %{"f" => "B1&\"B1\""}},
        "col_widths" => %{"1" => 80, "2" => 120},
        "frozen_cols" => "2"
      }

      {:ok, ins} = Structure.insert_cols(tab, 2, 2)
      assert ins["cells"] == %{"A1" => %{"v" => "a"}, "D1" => %{"v" => "b"}, "E1" => %{"f" => "D1&\"B1\""}}
      assert ins["col_widths"] == %{"1" => 80, "4" => 120}
      assert ins["frozen_cols"] == "2"

      {:ok, del} = Structure.delete_cols(tab, 2, 1)
      assert del["cells"] == %{"A1" => %{"v" => "a"}, "B1" => %{"f" => "#REF!&\"B1\""}}
      assert del["col_widths"] == %{"1" => 80}
      assert del["frozen_cols"] == "1"
    end

    test "insert past the column bound errors cleanly" do
      tab = %{"cells" => %{"XFD1" => %{"v" => "edge"}}}
      assert {:error, "grid_bounds_exceeded", _} = Structure.insert_cols(tab, 1, 1)
    end
  end

  # ── layout setters ──────────────────────────────────────────────────────────

  describe "set_col_width/3 and set_row_height/3" do
    test "sets, overwrites and clears entries (nil removes; floats round)" do
      {:ok, t1} = Structure.set_col_width(%{}, 2, 120)
      assert t1["col_widths"] == %{"2" => 120}

      {:ok, t2} = Structure.set_col_width(t1, 2, 90.6)
      assert t2["col_widths"] == %{"2" => 91}

      {:ok, t3} = Structure.set_col_width(t2, 2, nil)
      assert t3["col_widths"] == %{}

      {:ok, h1} = Structure.set_row_height(%{"row_heights" => %{"1" => 18}}, 4, 44)
      assert h1["row_heights"] == %{"1" => 18, "4" => 44}

      # Clearing an entry that never existed is a no-op, not an error.
      {:ok, h2} = Structure.set_row_height(%{}, 9, nil)
      assert h2["row_heights"] == %{}
    end

    test "invalid index or px errors cleanly" do
      assert {:error, "invalid_index", _} = Structure.set_col_width(%{}, 0, 100)
      assert {:error, "invalid_index", _} = Structure.set_col_width(%{}, 16_385, 100)
      assert {:error, "invalid_index", _} = Structure.set_row_height(%{}, "2", 100)
      assert {:error, "invalid_px", _} = Structure.set_col_width(%{}, 1, -5)
      assert {:error, "invalid_px", _} = Structure.set_row_height(%{}, 1, "wide")
    end
  end
end
