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

      {:ok, _} =
        Structure.insert_rows(%{"cells" => %{"A5" => %{"v" => 1}}, "merges" => []}, 6, 10)
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

      assert ins["cells"] == %{
               "A1" => %{"v" => "a"},
               "D1" => %{"v" => "b"},
               "E1" => %{"f" => "D1&\"B1\""}
             }

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

  # ── rebase_formula: copy/fill semantics ($-anchor aware) ────────────────────

  describe "rebase_formula/3" do
    test "a relative ref shifts by (dcol, drow)" do
      assert Structure.rebase_formula("A1", 1, 1) == "B2"
    end

    test "a fully-anchored ref never moves" do
      assert Structure.rebase_formula("$A$1", 5, 7) == "$A$1"
    end

    test "a row-anchored ref ($A1) shifts only its column" do
      assert Structure.rebase_formula("$A1", 2, 3) == "$A4"
    end

    test "a col-anchored ref (A$1) shifts only its row" do
      assert Structure.rebase_formula("A$1", 2, 3) == "C$1"
    end

    test "a ref pushed out of bounds collapses to a literal #REF!" do
      assert Structure.rebase_formula("A1", 0, -1) == "#REF!"
      assert Structure.rebase_formula("A1", -1, 0) == "#REF!"
    end

    test "string literals are never rebased — only the trailing ref shifts" do
      assert Structure.rebase_formula("\"A1\"&A1", 1, 0) == "\"A1\"&B1"
    end

    test "function names are never rebased" do
      assert Structure.rebase_formula("LOG10(A1)", 0, 1) == "LOG10(A2)"
    end

    test "a range rebases both corners" do
      assert Structure.rebase_formula("SUM(A1:B2)", 1, 1) == "SUM(B2:C3)"
    end

    test "a range corner clipped out of bounds collapses the range token to #REF!" do
      # The range token itself becomes the literal `#REF!` in place — the
      # surrounding call structure stays (the engine errors at compute time),
      # matching how `rewrite_formula/3` embeds delete-produced `#REF!`.
      assert Structure.rebase_formula("SUM(A1:B2)", 0, -1) == "SUM(#REF!)"
    end

    test "range whitespace/separator is preserved on rebase" do
      assert Structure.rebase_formula("A1 : B2", 1, 1) == "B2 : C3"
    end

    test "mixed anchors within one range rebase independently" do
      assert Structure.rebase_formula("SUM($A1:B$2)", 2, 3) == "SUM($A4:D$2)"
    end
  end

  # ── cond_formats rebase (CF-D7) ─────────────────────────────────────────────

  describe "insert_rows/3 — cond_formats" do
    test "a range below the insert point shifts whole; other keys + order survive" do
      tab = %{
        "cells" => %{},
        "cond_formats" => [
          %{
            "id" => "a",
            "range" => "B4:C6",
            "when" => %{"op" => "gt", "value" => 1},
            "style" => %{"bg" => "#ff0000"}
          },
          %{
            "id" => "b",
            "range" => "A1",
            "when" => %{"op" => "lt", "value" => 0},
            "style" => %{"bg" => "#00ff00"}
          }
        ]
      }

      {:ok, out} = Structure.insert_rows(tab, 2, 2)

      assert out["cond_formats"] == [
               %{
                 "id" => "a",
                 "range" => "B6:C8",
                 "when" => %{"op" => "gt", "value" => 1},
                 "style" => %{"bg" => "#ff0000"}
               },
               %{
                 "id" => "b",
                 "range" => "A1",
                 "when" => %{"op" => "lt", "value" => 0},
                 "style" => %{"bg" => "#00ff00"}
               }
             ]
    end

    test "a range spanning the insert point grows" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B10")]}
      {:ok, out} = Structure.insert_rows(tab, 5, 3)
      assert out["cond_formats"] == [cf("a", "B2:B13")]
    end

    test "a range entirely above the insert point stays put" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B4")]}
      {:ok, out} = Structure.insert_rows(tab, 9, 2)
      assert out["cond_formats"] == [cf("a", "B2:B4")]
    end
  end

  describe "delete_rows/3 — cond_formats" do
    test "a range clipped down to a single cell KEEPS its rule as \"B2\" (the CF divergence)" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B5")]}
      {:ok, out} = Structure.delete_rows(tab, 3, 5)
      assert out["cond_formats"] == [cf("a", "B2")]
    end

    test "deleting the whole range drops the rule" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B5"), cf("b", "D1:D2")]}
      {:ok, out} = Structure.delete_rows(tab, 2, 4)
      assert out["cond_formats"] == [cf("b", "D1")]
    end

    test "a partially covered range clips and keeps range form" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:D10")]}
      {:ok, out} = Structure.delete_rows(tab, 1, 3)
      assert out["cond_formats"] == [cf("a", "B1:D7")]
    end

    test "two ranges clipping onto the SAME normalized range keep only the first (gate-invariant)" do
      # B2:B3 and B2:B4 both collapse to "B2" when rows 3-4 go; the save
      # gate rejects duplicate normalized ranges (CF-D4), so the rebase
      # must not emit both — first in list order survives.
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B3"), cf("b", "B2:B4")]}
      {:ok, out} = Structure.delete_rows(tab, 3, 2)
      assert out["cond_formats"] == [cf("a", "B2")]
    end

    test "a clipped range colliding with an earlier untouched rule drops (first survives)" do
      # a clips B2:B5 -> B2, colliding with b's pre-existing "B2" behind it:
      # a came first, a's clipped form wins; b drops.
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2:B5"), cf("b", "B2")]}
      {:ok, out} = Structure.delete_rows(tab, 3, 5)
      assert out["cond_formats"] == [cf("a", "B2")]
    end
  end

  describe "insert_cols/3 and delete_cols/3 — cond_formats" do
    test "insert cols grows a spanning range and shifts a later one" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B1:D1"), cf("b", "F1")]}
      {:ok, out} = Structure.insert_cols(tab, 3, 1)
      assert out["cond_formats"] == [cf("a", "B1:E1"), cf("b", "G1")]
    end

    test "delete cols clipping to a single cell keeps the rule" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B1:E1")]}
      {:ok, out} = Structure.delete_cols(tab, 3, 5)
      assert out["cond_formats"] == [cf("a", "B1")]
    end

    test "delete cols dropping the whole range removes it" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "C1:D9")]}
      {:ok, out} = Structure.delete_cols(tab, 2, 4)
      assert out["cond_formats"] == []
    end
  end

  describe "cond_formats rebase — totality" do
    test "a malformed entry passes through untouched, never raises" do
      tab = %{
        "cells" => %{},
        "cond_formats" => [
          "not-a-map",
          %{"id" => "x", "range" => 42},
          %{"id" => "y", "range" => "nonsense"},
          cf("a", "A5")
        ]
      }

      {:ok, out} = Structure.insert_rows(tab, 1, 1)

      assert out["cond_formats"] == [
               "not-a-map",
               %{"id" => "x", "range" => 42},
               %{"id" => "y", "range" => "nonsense"},
               cf("a", "A6")
             ]
    end

    test "a single-cell range shifts as a single cell" do
      tab = %{"cells" => %{}, "cond_formats" => [cf("a", "B2")]}
      {:ok, out} = Structure.insert_rows(tab, 1, 1)
      assert out["cond_formats"] == [cf("a", "B3")]
    end

    test "identical malformed entries never join the range dedupe — both survive" do
      tab = %{"cells" => %{}, "cond_formats" => ["not-a-map", "not-a-map"]}
      {:ok, out} = Structure.insert_rows(tab, 1, 1)
      assert out["cond_formats"] == ["not-a-map", "not-a-map"]
    end
  end

  # ── sort_rows: comparator ladder (SF-D4) ────────────────────────────────────

  describe "sort_rows — comparator total ladder" do
    test "ascending: numbers < text < FALSE < TRUE < errors < blanks" do
      # rows 1..6, one of each value class, scrambled.
      tab =
        tab_with(%{
          "A1" => %{"v" => true},
          # A2 blank (no cell)
          "A3" => %{"v" => 5},
          "A4" => %{"v" => "#REF!", "t" => "e"},
          "A5" => %{"v" => "Hello"},
          "A6" => %{"v" => false}
        })

      {:ok, out, _perm} = Structure.sort_rows(tab, {1, 1, 1, 6}, [key(0, "asc")])
      assert col_vals(out, "A", 1, 6) == [5, "Hello", false, true, "#REF!", :blank]
    end

    test "descending reverses tiers 1..5 but blanks STAY last" do
      tab =
        tab_with(%{
          "A1" => %{"v" => true},
          "A3" => %{"v" => 5},
          "A4" => %{"v" => "#REF!", "t" => "e"},
          "A5" => %{"v" => "Hello"},
          "A6" => %{"v" => false}
        })

      {:ok, out, _perm} = Structure.sort_rows(tab, {1, 1, 1, 6}, [key(0, "desc")])
      assert col_vals(out, "A", 1, 6) == ["#REF!", true, false, "Hello", 5, :blank]
    end

    test "text compares case-insensitively" do
      tab =
        tab_with(%{
          "A1" => %{"v" => "banana"},
          "A2" => %{"v" => "Apple"},
          "A3" => %{"v" => "cherry"}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 1, 3}, [key(0, "asc")])
      assert col_vals(out, "A", 1, 3) == ["Apple", "banana", "cherry"]
    end

    test "all errors compare EQUAL (a t=e string and an error_values string tie)" do
      # Two distinct error strings, distinguishable payload in column B — equal
      # keys must keep original order (not a tautological refute).
      tab =
        tab_with(%{
          "A1" => %{"v" => "#DIV/0!", "t" => "e"},
          "B1" => %{"v" => "first"},
          "A2" => %{"v" => "#VALUE!"},
          "B2" => %{"v" => "second"}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 2, 2}, [key(0, "asc")])
      assert col_vals(out, "B", 1, 2) == ["first", "second"]
    end

    test "blanks are last in BOTH directions" do
      tab = tab_with(%{"A2" => %{"v" => 2}, "A4" => %{"v" => 1}})
      # rows 1 and 3 are blank
      {:ok, asc, _} = Structure.sort_rows(tab, {1, 1, 1, 4}, [key(0, "asc")])
      assert col_vals(asc, "A", 1, 4) == [1, 2, :blank, :blank]

      {:ok, desc, _} = Structure.sort_rows(tab, {1, 1, 1, 4}, [key(0, "desc")])
      assert col_vals(desc, "A", 1, 4) == [2, 1, :blank, :blank]
    end

    test "1 and 1.0 tie (numeric ==), stability keeps their order" do
      tab =
        tab_with(%{
          "A1" => %{"v" => 1},
          "B1" => %{"v" => "int"},
          "A2" => %{"v" => 1.0},
          "B2" => %{"v" => "float"}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 2, 2}, [key(0, "asc")])
      assert col_vals(out, "B", 1, 2) == ["int", "float"]
    end
  end

  # ── sort_rows: stability + multi-key ────────────────────────────────────────

  describe "sort_rows — stability and multi-key" do
    test "STABLE: equal keys retain original order (distinguishable payload)" do
      # Keys 2,1,1,2 — the two 1's and the two 2's must keep their relative
      # order (b before c, a before d), proving stability non-tautologically.
      tab =
        tab_with(%{
          "A1" => %{"v" => 2},
          "B1" => %{"v" => "a"},
          "A2" => %{"v" => 1},
          "B2" => %{"v" => "b"},
          "A3" => %{"v" => 1},
          "B3" => %{"v" => "c"},
          "A4" => %{"v" => 2},
          "B4" => %{"v" => "d"}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 2, 4}, [key(0, "asc")])
      assert col_vals(out, "A", 1, 4) == [1, 1, 2, 2]
      assert col_vals(out, "B", 1, 4) == ["b", "c", "a", "d"]
    end

    test "multi-key: col 0 asc, then col 1 asc — evaluated left to right" do
      tab =
        tab_with(%{
          "A1" => %{"v" => 1},
          "B1" => %{"v" => 20},
          "A2" => %{"v" => 1},
          "B2" => %{"v" => 10},
          "A3" => %{"v" => 2},
          "B3" => %{"v" => 5},
          "A4" => %{"v" => 2},
          "B4" => %{"v" => 15}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 2, 4}, [key(0, "asc"), key(1, "asc")])
      assert col_vals(out, "A", 1, 4) == [1, 1, 2, 2]
      assert col_vals(out, "B", 1, 4) == [10, 20, 5, 15]
    end

    test "empty keys list is a stable no-op (identity permutation)" do
      tab = tab_with(%{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}})
      {:ok, out, perm} = Structure.sort_rows(tab, {1, 1, 1, 3}, [])
      assert perm == [0, 1, 2]
      assert out["cells"] == tab["cells"]
    end

    test "an already-sorted range returns the identity permutation" do
      tab = tab_with(%{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}, "A3" => %{"v" => 3}})
      {:ok, _out, perm} = Structure.sort_rows(tab, {1, 1, 1, 3}, [key(0, "asc")])
      assert perm == [0, 1, 2]
    end
  end

  # ── sort_rows: verbatim moves (SF-D1) ───────────────────────────────────────

  describe "sort_rows — verbatim cell moves" do
    test "a moved formula cell travels BYTE-IDENTICAL (f never rewritten)" do
      moved = %{"f" => "A1*10", "v" => 999, "t" => "n", "fmt" => "0.00", "s" => %{"b" => true}}

      tab =
        tab_with(%{
          "A1" => %{"v" => 3},
          "B1" => moved,
          "A2" => %{"v" => 1},
          "B2" => %{"v" => "x"},
          "A3" => %{"v" => 2},
          "B3" => %{"v" => "y"}
        })

      # Row 1 (A=3) sorts to the LAST position (row 3); its B cell rides along.
      {:ok, out, perm} = Structure.sort_rows(tab, {1, 1, 2, 3}, [key(0, "asc")])
      assert perm == [2, 0, 1]
      assert out["cells"]["B3"] == moved
      assert out["cells"]["B3"]["f"] == "A1*10"
    end

    test "cells OUTSIDE the rect never move (different column or row)" do
      tab =
        tab_with(%{
          "A1" => %{"v" => 2},
          "A2" => %{"v" => 1},
          # C1 is outside the A:B rect columns; A5 is outside the rows.
          "C1" => %{"v" => "keep-col"},
          "A5" => %{"v" => "keep-row"}
        })

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 2, 2}, [key(0, "asc")])
      assert out["cells"]["C1"] == %{"v" => "keep-col"}
      assert out["cells"]["A5"] == %{"v" => "keep-row"}
      # The rect rows did swap.
      assert col_vals(out, "A", 1, 2) == [1, 2]
    end

    test "row_heights do NOT travel; merges and cond_formats stay put" do
      tab =
        %{
          "cells" => %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}},
          "row_heights" => %{"1" => 40, "2" => 60},
          "merges" => ["D1:E2"],
          "cond_formats" => [cf("r", "A1")]
        }

      {:ok, out, _} = Structure.sort_rows(tab, {1, 1, 1, 2}, [key(0, "asc")])
      assert out["row_heights"] == %{"1" => 40, "2" => 60}
      assert out["merges"] == ["D1:E2"]
      assert out["cond_formats"] == [cf("r", "A1")]
    end
  end

  # ── sort_rows: guards (SF-D5) ────────────────────────────────────────────────

  describe "sort_rows — refusals" do
    test "a merge intersecting the rect refuses with sort_merge_overlap" do
      tab = %{"cells" => %{"A1" => %{"v" => 1}}, "merges" => ["A1:B2"]}

      assert {:error, "sort_merge_overlap", _} =
               Structure.sort_rows(tab, {1, 1, 3, 3}, [key(0, "asc")])
    end

    test "a merge fully outside the rect does NOT refuse" do
      tab = %{"cells" => %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}}, "merges" => ["D4:E5"]}
      assert {:ok, _, _} = Structure.sort_rows(tab, {1, 1, 1, 2}, [key(0, "asc")])
    end

    test "a rect reaching the frozen head band refuses with sort_frozen_overlap" do
      tab = %{"cells" => %{"A1" => %{"v" => 1}}, "frozen_rows" => 1}

      assert {:error, "sort_frozen_overlap", _} =
               Structure.sort_rows(tab, {1, 1, 1, 3}, [key(0, "asc")])
    end

    test "a rect starting BELOW the frozen band is allowed" do
      tab = %{"cells" => %{"A2" => %{"v" => 2}, "A3" => %{"v" => 1}}, "frozen_rows" => 1}
      assert {:ok, _, _} = Structure.sort_rows(tab, {1, 2, 1, 3}, [key(0, "asc")])
    end

    test "a numeric-STRING frozen_rows (xlsx import) is honored" do
      tab = %{"cells" => %{"A1" => %{"v" => 1}}, "frozen_rows" => "2"}

      assert {:error, "sort_frozen_overlap", _} =
               Structure.sort_rows(tab, {1, 1, 1, 4}, [key(0, "asc")])
    end

    test "non-list keys refuse with invalid_sort_keys" do
      tab = tab_with(%{"A1" => %{"v" => 1}})
      assert {:error, "invalid_sort_keys", _} = Structure.sort_rows(tab, {1, 1, 1, 2}, "nope")
    end

    test "a col OUTSIDE the rect refuses with invalid_sort_keys" do
      tab = tab_with(%{"A1" => %{"v" => 1}})
      # rect is A:A (0-based col 0 only); col 5 is out of range.
      assert {:error, "invalid_sort_keys", _} =
               Structure.sort_rows(tab, {1, 1, 1, 2}, [key(5, "asc")])
    end

    test "a bad dir refuses with invalid_sort_keys" do
      tab = tab_with(%{"A1" => %{"v" => 1}})

      assert {:error, "invalid_sort_keys", _} =
               Structure.sort_rows(tab, {1, 1, 1, 2}, [key(0, "up")])
    end
  end

  # ── permute_rows + invert_perm (SF-D6) ──────────────────────────────────────

  describe "permute_rows / invert_perm" do
    test "invert_perm is a true inverse (identity, and double-invert)" do
      assert Structure.invert_perm([2, 0, 1]) == [1, 2, 0]
      assert Structure.invert_perm([0, 1, 2]) == [0, 1, 2]
      assert Structure.invert_perm([]) == []
      p = [3, 0, 2, 1]
      assert Structure.invert_perm(Structure.invert_perm(p)) == p
    end

    test "permute_rows re-applies a perm and hands back its inverse; round-trips to original" do
      tab = tab_with(%{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}, "A3" => %{"v" => "z"}})
      rect = {1, 1, 1, 3}

      {:ok, sorted, perm} = Structure.sort_rows(tab, rect, [key(0, "desc")])
      inverse = Structure.invert_perm(perm)

      {:ok, restored, forward} = Structure.permute_rows(sorted, rect, inverse)
      assert restored["cells"] == tab["cells"]
      # The inverse of the inverse is the forward sort perm.
      assert forward == perm
    end
  end

  # Build a tab from an addr => cell map.
  defp tab_with(cells), do: %{"cells" => cells}

  # A sort key over an absolute 0-based column.
  defp key(col, dir), do: %{"col" => col, "dir" => dir}

  # Column values top-to-bottom over r1..r2; a missing cell reads as :blank.
  defp col_vals(tab, col, r1, r2) do
    cells = tab["cells"]

    for r <- r1..r2 do
      case Map.get(cells, "#{col}#{r}") do
        nil -> :blank
        cell -> Map.get(cell, "v")
      end
    end
  end

  # A minimal well-formed CF rule with the given id + range.
  defp cf(id, range) do
    %{
      "id" => id,
      "range" => range,
      "when" => %{"op" => "gt", "value" => 1},
      "style" => %{"bg" => "#ff0000"}
    }
  end
end
