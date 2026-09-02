defmodule Barkpark.Plugins.Sheets.EngineTest do
  @moduledoc """
  Unit tests for `Barkpark.Plugins.Sheets.Engine` — the formula engine. Pure
  functions, no DB: every test drives `recompute/1` on an in-memory content
  map and asserts the written-back cell descriptors.
  """
  use ExUnit.Case, async: true

  doctest Barkpark.Plugins.Sheets.Engine

  alias Barkpark.Plugins.Sheets.Engine

  # Recompute a single-tab content map and return its cells.
  defp run(cells) do
    %{"tabs" => [%{"name" => "T", "cells" => cells}]}
    |> Engine.recompute()
    |> get_in(["tabs", Access.at(0), "cells"])
  end

  # Evaluate one formula (in Z99, away from fixture cells) and return its v.
  defp eval!(formula, cells \\ %{}) do
    cell!(formula, cells)["v"]
  end

  # Same, but the full written-back cell.
  defp cell!(formula, cells \\ %{}) do
    run(Map.put(cells, "Z99", %{"f" => formula}))["Z99"]
  end

  # ── totality & canonical form ───────────────────────────────────────────────

  describe "recompute/1 totality" do
    test "content without a tabs list passes through untouched" do
      assert Engine.recompute(%{"locale" => "nb-NO"}) == %{"locale" => "nb-NO"}
      assert Engine.recompute(%{"tabs" => "nope"}) == %{"tabs" => "nope"}
      assert Engine.recompute(nil) == nil
    end

    test "malformed tabs and empty cells pass through untouched" do
      content = %{"tabs" => ["junk", %{"name" => "T"}, %{"cells" => %{}}, %{"cells" => [1]}]}
      assert Engine.recompute(content) == content
    end

    test "formula-free cells come back exactly as stored" do
      cells = %{
        "A1" => %{"v" => "hi", "t" => "s"},
        "B2" => %{"v" => 42},
        "C3" => %{"v" => true, "fmt" => "x"}
      }

      assert run(cells) == cells
    end

    test "a non-binary f is not a formula — cell untouched" do
      cells = %{"A1" => %{"f" => 5, "v" => 9}}
      assert run(cells) == cells
    end

    test "cells with an invalid A1 key are skipped, not raised on" do
      cells = %{"nope" => %{"v" => 1}, "A1" => %{"f" => "1+1"}}
      out = run(cells)
      assert out["nope"] == %{"v" => 1}
      assert out["A1"]["v"] == 2
    end

    test "a number cell whose value overflows float64 degrades, not raises" do
      huge = String.duplicate("9", 400) <> ".5"
      cells = %{"A1" => %{"v" => huge, "t" => "number"}}
      out = run(cells)
      assert out["A1"]["v"] == huge
    end
  end

  describe "canonical formula form" do
    test "leading = is optional — both forms compute" do
      assert eval!("1+1") == 2
      assert eval!("=1+1") == 2
    end

    test "surrounding whitespace is tolerated and f is never rewritten" do
      cell = cell!("  = 1 +  1 ")
      assert cell["v"] == 2
      assert cell["f"] == "  = 1 +  1 "
    end
  end

  # ── literals ────────────────────────────────────────────────────────────────

  describe "literals" do
    test "integers and floats" do
      assert eval!("42") == 42
      assert eval!("1.5") == 1.5
      assert eval!(".5") == 0.5
    end

    test "strings, with doubled-quote escaping" do
      cell = cell!(~s("hi"))
      assert cell["v"] == "hi"
      assert cell["t"] == "s"
      assert eval!(~s("a""b")) == ~s(a"b)
    end

    test "booleans, case-insensitive" do
      assert cell!("TRUE") == %{"f" => "TRUE", "v" => true, "t" => "b"}
      assert eval!("false") == false
      assert eval!("True") == true
    end
  end

  # ── operators ───────────────────────────────────────────────────────────────

  describe "arithmetic operators" do
    test "addition / subtraction / multiplication / division" do
      assert eval!("2+3") == 5
      assert eval!("7-10") == -3
      assert eval!("6*7") == 42
      assert eval!("7/2") == 3.5
    end

    test "exponentiation" do
      assert eval!("2^10") == 1024
      assert eval!("2^-1") == 0.5
    end

    test "unary minus, including stacking" do
      assert eval!("-5") == -5
      assert eval!("--5") == 5
      assert eval!("3--2") == 5
      assert eval!("-(1+2)") == -3
    end
  end

  describe "string concat (&)" do
    test "concatenates strings and coerces scalars" do
      assert eval!(~s("a"&"b")) == "ab"
      assert eval!(~s(1&"x")) == "1x"
      assert eval!(~s(1.5&"x")) == "1.5x"
      assert eval!(~s(TRUE&"")) == "TRUE"
    end
  end

  # ── 15-significant-digit number↔text layer ─────────────────────────────────
  #
  # Excel's user-facing numeric world is the 15-sig-digit DECIMAL view of the
  # IEEE double — applied at display AND at every number→text coercion. Raw
  # binary noise ("0.30000000000000004") must never reach a user-facing string.

  describe "15-significant-digit number→text layer" do
    alias Barkpark.Plugins.Sheets.Core

    test "display: binary-noise floats clamp to the 15-digit decimal view" do
      assert Core.number_to_display(0.1 + 0.2) == "0.3"
      assert Core.number_to_display(1 / 3) == "0.333333333333333"
    end

    test "display guards: whole floats integral, exponent thresholds unchanged" do
      assert Core.number_to_display(5.0) == "5"
      assert Core.number_to_display(2_000_000.0) == "2000000"
      assert Core.number_to_display(123_456.789) == "123456.789"
      # The documented <1e-6 / >=1e15 exponent behavior stays (deliberately
      # wider than Excel's 1e11 scientific threshold).
      assert Core.number_to_display(1.0e-7) == "1.0e-7"
      assert Core.number_to_display(1.0e15) == "1.0e15"
    end

    test "text coercion (& / CONCATENATE / TEXTJOIN) uses the display view" do
      assert eval!(~s{(0.1+0.2)&""}) == "0.3"
      assert eval!(~s{"x"&(3/2)*2}) == "x3"
      assert eval!(~s{"n="&2000000.0}) == "n=2000000"
      assert eval!(~s{CONCATENATE(1/3,"")}) == "0.333333333333333"
      assert eval!(~s{TEXTJOIN(",",TRUE,1/3,0.1+0.2)}) == "0.333333333333333,0.3"
    end
  end

  describe "comparison operators" do
    test "each operator" do
      assert eval!("1=1") == true
      assert eval!("1<>2") == true
      assert eval!("1<2") == true
      assert eval!("2<=2") == true
      assert eval!("3>2") == true
      assert eval!("2>=3") == false
    end

    test "string comparison is case-insensitive" do
      assert eval!(~s("abc"="ABC")) == true
      assert eval!(~s("a"<"b")) == true
    end

    test "booleans order FALSE < TRUE" do
      assert eval!("TRUE>FALSE") == true
    end

    test "mismatched types: =/<> answer, ordering is #VALUE!" do
      assert eval!(~s(1="1")) == false
      assert eval!(~s(1<>"1")) == true
      assert eval!(~s(1<"a")) == "#VALUE!"
    end
  end

  # ── precedence ──────────────────────────────────────────────────────────────

  describe "precedence & parentheses" do
    test "multiplication over addition; parens override" do
      assert eval!("2+3*4") == 14
      assert eval!("(2+3)*4") == 20
    end

    test "exponentiation over multiplication" do
      assert eval!("2*3^2") == 18
    end

    test "unary minus binds tighter than ^ (Excel)" do
      assert eval!("-2^2") == 4
      assert eval!("2^-2") == 0.25
    end

    test "^ is left-associative (Excel)" do
      assert eval!("2^3^2") == 64
    end

    test "& binds below + and above comparison" do
      assert eval!(~s(1+2&"x")) == "3x"
      assert eval!(~s("a"&"b"="ab")) == true
    end

    test "comparison binds lowest" do
      assert eval!("1+2=3") == true
    end
  end

  # ── refs ────────────────────────────────────────────────────────────────────

  describe "cell refs" do
    test "a plain ref reads the cell's literal value" do
      assert eval!("A1*2", %{"A1" => %{"v" => 7}}) == 14
    end

    test "$-anchored refs are treated as plain refs" do
      cells = %{"A1" => %{"v" => 1}, "B1" => %{"v" => 2}, "A2" => %{"v" => 4}}
      assert eval!("$A$1+$B1+A$2", cells) == 7
    end

    test "lower-case refs are tolerated" do
      assert eval!("a1+1", %{"A1" => %{"v" => 1}}) == 2
    end

    test "formula chains recompute in dependency order" do
      out =
        run(%{
          "A1" => %{"v" => 1},
          "B1" => %{"f" => "A1+1"},
          "C1" => %{"f" => "B1+1"}
        })

      assert out["B1"]["v"] == 2
      assert out["C1"]["v"] == 3
    end

    test "a ref to a text or boolean cell is #VALUE! in arithmetic" do
      assert eval!("A1+1", %{"A1" => %{"v" => "abc"}}) == "#VALUE!"
      assert eval!("A1+1", %{"A1" => %{"v" => true}}) == "#VALUE!"
    end
  end

  # ── ranges ──────────────────────────────────────────────────────────────────

  describe "ranges" do
    @grid %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "B1" => %{"v" => 3},
      "B2" => %{"v" => 4}
    }

    test "rectangular range" do
      assert eval!("SUM(A1:B2)", @grid) == 10
    end

    test "single-cell range" do
      assert eval!("SUM(A1:A1)", @grid) == 1
    end

    test "reversed corners normalize" do
      assert eval!("SUM(B2:A1)", @grid) == 10
    end

    test "a range used as a scalar is #VALUE!" do
      assert eval!("A1:B2+1", @grid) == "#VALUE!"
    end

    test "strings, booleans and blanks inside a range are skipped" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => "text"},
        "A3" => %{"v" => true},
        "A5" => %{"v" => 2}
      }

      assert eval!("SUM(A1:A6)", cells) == 3
    end

    test "an error inside a range propagates through SUM" do
      cells = Map.put(@grid, "B2", %{"f" => "1/0"})
      assert eval!("SUM(A1:B2)", cells) == "#DIV/0!"
    end
  end

  # ── full-column / full-row (unbounded) ranges — A:A wave 2, design §3.1 ──────
  #
  # `A:A` / `3:3` resolve to the USED RANGE at eval time (CT-D2 — never a stored
  # rect). Before this slice `ref_like?` required a digit, so `A:A` failed the
  # parser → :invalid → #REF!; each test below was #REF! (or #VALUE!) before.
  describe "full-column ranges (A:A)" do
    @col %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3}
    }

    test "=SUM(A:A) sums the whole column's used cells" do
      # Was #REF! before A:A parsed at all.
      assert eval!("SUM(A:A)", @col) == 6
    end

    test "CT-D2: A:A tracks the used range — a cell added below extends the sum" do
      assert eval!("SUM(A:A)", @col) == 6
      # No stored rect: a fresh recompute re-scans occupied, so A100 is seen.
      extended = Map.put(@col, "A100", %{"v" => 4})
      assert eval!("SUM(A:A)", extended) == 10
    end

    test "=COUNT(B:B) counts only column B's numbers" do
      cells = %{
        "B1" => %{"v" => 10},
        "B2" => %{"v" => "text"},
        "B3" => %{"v" => 20},
        "A1" => %{"v" => 99}
      }

      assert eval!("COUNT(B:B)", cells) == 2
    end

    test "=AVERAGE(A:A) averages the used cells" do
      assert eval!("AVERAGE(A:A)", @col) == 2
    end

    test "$A:$A is identical to A:A" do
      assert eval!("SUM($A:$A)", @col) == 6
    end

    test "a multi-column range A:C spans every used cell in those columns" do
      cells = %{
        "A1" => %{"v" => 1},
        "B5" => %{"v" => 2},
        "C9" => %{"v" => 3},
        "D1" => %{"v" => 100}
      }

      assert eval!("SUM(A:C)", cells) == 6
    end

    test "a blank column sums to 0 (empty used set, not a million-cell walk)" do
      assert eval!("SUM(A:A)", %{"B1" => %{"v" => 5}}) == 0
    end

    test "=SUM(A:A) placed IN column A is a self-cycle → #CYCLE!" do
      cells = Map.put(@col, "A10", %{"f" => "SUM(A:A)"})
      assert run(cells)["A10"]["v"] == "#CYCLE!"
    end

    test "=SUM(A:A) placed OUTSIDE column A is not circular" do
      cells = Map.put(@col, "C1", %{"f" => "SUM(A:A)"})
      assert run(cells)["C1"]["v"] == 6
    end

    test "a bare =A:A outside an aggregate is #VALUE!" do
      assert eval!("A:A", @col) == "#VALUE!"
    end
  end

  describe "full-row ranges (3:3)" do
    @row %{
      "A3" => %{"v" => 1},
      "B3" => %{"v" => 2},
      "C3" => %{"v" => 3},
      "A1" => %{"v" => 99}
    }

    test "=SUM(3:3) sums the whole row's used cells" do
      assert eval!("SUM(3:3)", @row) == 6
    end

    test "a multi-row range 2:5 spans every used cell in those rows" do
      cells = %{
        "A2" => %{"v" => 10},
        "Z5" => %{"v" => 20},
        "A1" => %{"v" => 100},
        "A6" => %{"v" => 100}
      }

      assert eval!("SUM(2:5)", cells) == 30
    end

    test "a bare =3:3 outside an aggregate is #VALUE!" do
      assert eval!("3:3", @row) == "#VALUE!"
    end

    test "a fractional row range is out of grammar → #REF!" do
      assert eval!("SUM(3.5:3.5)") == "#REF!"
    end
  end

  # A2 (Structure) seam lock. The full-axis shapes THIS slice accepts and the
  # ones it rejects form the exact contract the Structure string-scanner (slice
  # A2) must recognize byte-identically. These pin the ACCEPTED set (reversed
  # corners normalize; a function-name word is a legal column; whitespace around
  # the colon is tolerated like a bounded range) and the REJECTED set ($-anchored
  # rows, ref:col / col:ref mixes → #REF!) so A2 can't silently drift the grammar.
  describe "full-axis grammar seam (A2 contract)" do
    test "reversed corners normalize (C:A == A:C, 5:2 == 2:5)" do
      cells = %{"A1" => %{"v" => 1}, "B1" => %{"v" => 2}, "C1" => %{"v" => 3}}
      assert eval!("SUM(C:A)", cells) == 6

      rows = %{"A2" => %{"v" => 10}, "A5" => %{"v" => 20}, "A1" => %{"v" => 99}}
      assert eval!("SUM(5:2)", rows) == 30
    end

    test "whitespace around the colon is tolerated (A : A)" do
      assert eval!("SUM(A : A)", @col) == 6
    end

    test "a function-name word resolves as its column (SUM:SUM is column 13403)" do
      # SUM lexes as a colword (letters ≤ XFD) when not followed by `(`; an empty
      # column 13403 sums to 0 — proof the fn-vs-column split is the `(` lookahead.
      assert eval!("SUM(SUM:SUM)") == 0
    end

    test "rejected shapes are #REF! (A2 must reject these identically)" do
      # $-anchored full-row ($3 doesn't lex as a num), and col:ref / ref:col
      # mixes — none is a full-axis range; all fail the grammar.
      assert eval!("SUM($3:$3)", @col) == "#REF!"
      assert eval!("SUM(A:A2)", @col) == "#REF!"
      assert eval!("SUM(A1:A)", @col) == "#REF!"
    end
  end

  # Regression lock (design §5 / instruction): a bounded-range doc must recompute
  # byte-identically — the 3-tuple {:range,p1,p2} clauses are untouched; only new
  # 4-tuple clauses were added. Any accidental interception by the A:A path
  # would change this output.
  describe "bounded-range regression lock" do
    test "A1:B3-style SUM/COUNT/AVERAGE recompute byte-identically on the fast path" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => 3},
        "B1" => %{"v" => 4},
        "B2" => %{"v" => 5},
        "B3" => %{"v" => 6},
        "C1" => %{"f" => "SUM(A1:B3)"},
        "C2" => %{"f" => "COUNT(A1:B3)"},
        "C3" => %{"f" => "AVERAGE(A1:B3)"}
      }

      expected = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => 3},
        "B1" => %{"v" => 4},
        "B2" => %{"v" => 5},
        "B3" => %{"v" => 6},
        "C1" => %{"f" => "SUM(A1:B3)", "v" => 21, "t" => "n"},
        "C2" => %{"f" => "COUNT(A1:B3)", "v" => 6, "t" => "n"},
        "C3" => %{"f" => "AVERAGE(A1:B3)", "v" => 3.5, "t" => "n"}
      }

      assert run(cells) == expected
      # And the doc provably takes the per-tab fast path, not the unified one.
      refute Engine.uses_cross_tab?(%{"tabs" => [%{"name" => "T", "cells" => cells}]})
    end
  end

  describe "SPARKLINE" do
    test "scales a numeric series onto the 8-level block-bar ramp" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 5}, "A3" => %{"v" => 9}}
      cell = cell!("=SPARKLINE(A1:A3)", cells)
      assert cell["v"] == "▁▅█"
      assert cell["t"] == "s"
    end

    test "reads a row range left-to-right in reading order" do
      cells = %{"A1" => %{"v" => 8}, "B1" => %{"v" => 1}, "C1" => %{"v" => 4}}
      # min 1, max 8, span 7: 8 -> █, 1 -> ▁, 4 -> round(3/7*7)=3 -> ▄
      assert eval!("SPARKLINE(A1:C1)", cells) == "█▁▄"
    end

    test "blanks and text inside the range are skipped" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => "label"},
        "A4" => %{"v" => 9}
      }

      # A3 blank, A2 text -> only [1, 9] contribute
      assert eval!("SPARKLINE(A1:A4)", cells) == "▁█"
    end

    test "an error anywhere in the range propagates" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"f" => "1/0"}, "A3" => %{"v" => 9}}
      cell = cell!("=SPARKLINE(A1:A3)", cells)
      assert cell["v"] == "#DIV/0!"
      assert cell["t"] == "e"
    end

    test "an all-equal series renders a flat mid-bar row" do
      cells = %{"A1" => %{"v" => 3}, "A2" => %{"v" => 3}, "A3" => %{"v" => 3}}
      assert eval!("SPARKLINE(A1:A3)", cells) == "▄▄▄"
    end

    test "an empty range is the empty string" do
      cell = cell!("=SPARKLINE(B1:B5)")
      assert cell["v"] == ""
      assert cell["t"] == "s"
    end

    test "a scalar arg is a 1-cell series -> a single mid bar" do
      assert eval!("SPARKLINE(42)") == "▄"
    end

    test "a single-ref arg is a 1-cell series" do
      assert eval!("SPARKLINE(A1)", %{"A1" => %{"v" => 7}}) == "▄"
    end

    test "a non-numeric scalar arg is #VALUE!" do
      assert eval!(~s|SPARKLINE("hi")|) == "#VALUE!"
    end

    # PART B — a dynamic array (SORT/UNIQUE/FILTER) is a valid series, in the
    # array's stored order (SORT/UNIQUE order survives — no coordinate re-sort).
    test "accepts a SORT array in sorted order (the canonical pattern)" do
      cells = %{"A1" => %{"v" => 9}, "A2" => %{"v" => 1}, "A3" => %{"v" => 5}}
      # SORT ascends to [1, 5, 9]; the ramp is the ascending 1..9 series.
      assert eval!("SPARKLINE(SORT(A1:A3))", cells) == "▁▅█"
    end

    test "accepts a UNIQUE array" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 1},
        "A3" => %{"v" => 9}
      }

      # UNIQUE -> [1, 9] in encounter order.
      assert eval!("SPARKLINE(UNIQUE(A1:A3))", cells) == "▁█"
    end

    test "an inner error in the array propagates" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"f" => "1/0"}, "A3" => %{"v" => 9}}
      assert eval!("SPARKLINE(SORT(A1:A3))", cells) == "#DIV/0!"
    end

    test "a self-referencing array is still #CYCLE!, not #VALUE!" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 9},
        "B1" => %{"f" => "SPARKLINE(SORT(A1:B1))"}
      }

      out = run(cells)
      assert out["B1"]["v"] == "#CYCLE!"
    end
  end

  # ── functions ───────────────────────────────────────────────────────────────

  describe "SUM" do
    test "scalars, ranges, and a mix" do
      assert eval!("SUM(1,2,3)") == 6
      assert eval!("SUM(A1:A2,10)", %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}}) == 13
    end

    test "no arguments sums to 0" do
      assert eval!("SUM()") == 0
    end

    test "a direct string argument is #VALUE!" do
      assert eval!(~s{SUM(1,"abc")}) == "#VALUE!"
    end

    test "blank direct refs are skipped" do
      assert eval!("SUM(A8,A9)", %{"A8" => %{"v" => 3}}) == 3
    end
  end

  describe "AVG / AVERAGE" do
    test "exact integer average stays an integer" do
      assert eval!("AVG(2,4)") == 3
    end

    test "inexact average is a float" do
      assert eval!("AVG(1,2)") == 1.5
    end

    test "AVERAGE is an alias" do
      assert eval!("AVERAGE(2,4)") == eval!("AVG(2,4)")
    end

    test "no numeric values is #DIV/0!" do
      assert eval!("AVG()") == "#DIV/0!"
      assert eval!("AVG(A1:A3)") == "#DIV/0!"
    end
  end

  describe "MIN / MAX" do
    test "pick over scalars and ranges" do
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => -2}}
      assert eval!("MIN(A1:A2,3)", cells) == -2
      assert eval!("MAX(A1:A2,3)", cells) == 5
    end

    test "empty set yields 0" do
      assert eval!("MIN(A1:A3)") == 0
      assert eval!("MAX(A1:A3)") == 0
    end
  end

  describe "COUNT / COUNTA" do
    @mixed %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => "x"},
      "A3" => %{"v" => true},
      "A4" => %{"v" => 2.5},
      "A6" => %{"v" => ""}
    }

    test "COUNT counts numbers only" do
      assert eval!("COUNT(A1:A6)", @mixed) == 2
    end

    test "COUNT skips non-numeric direct args without erroring" do
      assert eval!(~s{COUNT(1,"a",TRUE,2)}) == 2
    end

    test "COUNTA counts every non-empty value" do
      assert eval!("COUNTA(A1:A6)", @mixed) == 4
    end

    test "COUNTA counts error cells; COUNT skips them" do
      cells = Map.put(@mixed, "A5", %{"f" => "1/0"})
      assert eval!("COUNTA(A1:A6)", cells) == 5
      assert eval!("COUNT(A1:A6)", cells) == 2
    end
  end

  describe "COUNTIF" do
    test "numeric equality" do
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => 3}, "A3" => %{"v" => 5}}
      assert eval!("COUNTIF(A1:A3,5)", cells) == 2
    end

    test "numeric-looking text matches a numeric criterion" do
      cells = %{"A1" => %{"v" => "5"}, "A2" => %{"v" => 5}, "A3" => %{"v" => 6}}
      assert eval!("COUNTIF(A1:A3,5)", cells) == 2
    end

    test "comparator criteria >=5 <3 <>x" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 5},
        "A3" => %{"v" => 10},
        "A4" => %{"v" => "x"}
      }

      assert eval!(~s{COUNTIF(A1:A4,">=5")}, cells) == 2
      assert eval!(~s{COUNTIF(A1:A4,"<3")}, cells) == 1
      assert eval!(~s{COUNTIF(A1:A4,"<>x")}, cells) == 3
    end

    test "text ordering >m" do
      cells = %{"A1" => %{"v" => "apple"}, "A2" => %{"v" => "zebra"}, "A3" => %{"v" => "mango"}}
      assert eval!(~s{COUNTIF(A1:A3,">m")}, cells) == 2
    end

    test "text equality is case-insensitive" do
      cells = %{"A1" => %{"v" => "abc"}, "A2" => %{"v" => "ABC"}, "A3" => %{"v" => "abd"}}
      assert eval!(~s{COUNTIF(A1:A3,"ABC")}, cells) == 2
    end

    test "wildcards * and ?" do
      cells = %{
        "A1" => %{"v" => "apple"},
        "A2" => %{"v" => "avocado"},
        "A3" => %{"v" => "banana"}
      }

      assert eval!(~s{COUNTIF(A1:A3,"a*")}, cells) == 2

      two = %{"A1" => %{"v" => "ab"}, "A2" => %{"v" => "xb"}, "A3" => %{"v" => "abc"}}
      assert eval!(~s{COUNTIF(A1:A3,"?b")}, two) == 2
    end

    test "~* matches a literal star" do
      cells = %{"A1" => %{"v" => "*"}, "A2" => %{"v" => "a"}, "A3" => %{"v" => "*"}}
      assert eval!(~s{COUNTIF(A1:A3,"~*")}, cells) == 2
    end

    test "criteria via a ref and a computed concat" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 5},
        "A3" => %{"v" => 10},
        "B1" => %{"v" => 5}
      }

      assert eval!("COUNTIF(A1:A3,B1)", cells) == 1
      assert eval!(~s{COUNTIF(A1:A3,">="&B1)}, cells) == 2
    end

    test "sparse blank rules over a rectangle" do
      # A1:B3 = 6 cells; occupied A1=5, A2="", B1=3 → 3 unoccupied (A3,B2,B3).
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => ""}, "B1" => %{"v" => 3}}
      assert eval!(~s{COUNTIF(A1:B3,"")}, cells) == 4
      assert eval!(~s{COUNTIF(A1:B3,"<>")}, cells) == 2
      assert eval!(~s{COUNTIF(A1:B3,"<>5")}, cells) == 5
      assert eval!(~s{COUNTIF(A1:B3,">=0")}, cells) == 2
    end

    test "an error cell never matches" do
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"f" => "1/0"}}
      assert eval!(~s{COUNTIF(A1:A2,">=0")}, cells) == 1
    end

    test "wrong arity is #VALUE!" do
      assert eval!("COUNTIF(A1:A2,5,3)") == "#VALUE!"
    end

    test "a range criteria arg is #VALUE!" do
      cells = %{"A1" => %{"v" => 5}, "B1" => %{"v" => 1}, "B2" => %{"v" => 2}}
      assert eval!("COUNTIF(A1:A1,B1:B2)", cells) == "#VALUE!"
    end
  end

  describe "SUMIF" do
    test "two-arg form sums the criteria range itself" do
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => 3}, "A3" => %{"v" => 10}}
      assert eval!(~s{SUMIF(A1:A3,">=5")}, cells) == 15
    end

    test "three-arg form pairs by offset" do
      cells = %{
        "A1" => %{"v" => "x"},
        "A2" => %{"v" => "y"},
        "A3" => %{"v" => "x"},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => 20},
        "B3" => %{"v" => 30}
      }

      assert eval!(~s{SUMIF(A1:A3,"x",B1:B3)}, cells) == 40
    end

    test "text and bool in the sum range are ignored" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 1},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => "txt"}
      }

      assert eval!("SUMIF(A1:A2,1,B1:B2)", cells) == 10
    end

    test "an error in a MATCHED sum cell propagates; an unmatched one does not" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 0},
        "B1" => %{"f" => "1/0"},
        "B2" => %{"v" => 5}
      }

      assert eval!("SUMIF(A1:A2,1,B1:B2)", cells) == "#DIV/0!"
      assert eval!("SUMIF(A1:A2,0,B1:B2)", cells) == 5
    end

    test "no match sums to 0" do
      cells = %{"A1" => %{"v" => 1}, "B1" => %{"v" => 10}}
      assert eval!("SUMIF(A1:A1,99,B1:B1)", cells) == 0
    end

    test "a sum range of a different shape is #VALUE!" do
      assert eval!("SUMIF(A1:A2,1,B1:B3)") == "#VALUE!"
    end

    test "single-ref criteria and sum pair" do
      cells = %{"A1" => %{"v" => "x"}, "B1" => %{"v" => 7}}
      assert eval!(~s{SUMIF(A1,"x",B1)}, cells) == 7
    end

    test "a sum range containing a formula that references the SUMIF cell is #CYCLE!" do
      out =
        run(%{
          "A1" => %{"v" => 1},
          "B1" => %{"f" => "Z99+1"},
          "Z99" => %{"f" => "SUMIF(A1:A1,1,B1:B1)"}
        })

      assert out["Z99"]["v"] == "#CYCLE!"
    end
  end

  describe "AVERAGEIF" do
    test "integer-preserving average" do
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => 4}, "A3" => %{"v" => 1}}
      assert eval!(~s{AVERAGEIF(A1:A3,">=2")}, cells) == 3
    end

    test "inexact average is a float" do
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => 4}, "A3" => %{"v" => 1}}
      assert eval!(~s{AVERAGEIF(A1:A3,"<=2")}, cells) == 1.5
    end

    test "no match is #DIV/0!" do
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => 4}}
      assert eval!(~s{AVERAGEIF(A1:A2,">100")}, cells) == "#DIV/0!"
    end
  end

  describe "COUNTIFS" do
    test "two-pair AND count" do
      cells = %{
        "A1" => %{"v" => "north"},
        "A2" => %{"v" => "south"},
        "A3" => %{"v" => "north"},
        "A4" => %{"v" => "north"},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => 20},
        "B3" => %{"v" => 5},
        "B4" => %{"v" => 30}
      }

      # north AND >=10 → rows 1 (10) and 4 (30); row 3 (north,5) fails the amount.
      assert eval!(~s{COUNTIFS(A1:A4,"north",B1:B4,">=10")}, cells) == 2
    end

    test "a criteria range of a different shape is #VALUE!" do
      assert eval!(~s{COUNTIFS(A1:A3,"x",B1:B2,"y")}) == "#VALUE!"
    end

    test "an odd argument count is #VALUE!" do
      assert eval!(~s{COUNTIFS(A1:A3,"x",B1:B3)}) == "#VALUE!"
    end

    test "wildcard and numeric criteria mixed" do
      cells = %{
        "A1" => %{"v" => "apple"},
        "A2" => %{"v" => "apricot"},
        "A3" => %{"v" => "banana"},
        "A4" => %{"v" => "avocado"},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => 3},
        "B3" => %{"v" => 20},
        "B4" => %{"v" => 8}
      }

      # a* AND >=5 → apple(10) and avocado(8); apricot(3) fails, banana fails a*.
      assert eval!(~s{COUNTIFS(A1:A4,"a*",B1:B4,">=5")}, cells) == 2
    end

    test ~s{"" over DISJOINT occupancy unions the shifted offsets} do
      # range1 (A1:A3) occupies only A1; range2 (B1:B3) occupies B2, B3.
      # The offset row 2 exists ONLY because range2 has B2 — the offset-union case.
      cells = %{"A1" => %{"v" => ""}, "B2" => %{"v" => ""}, "B3" => %{"v" => "x"}}
      # row1: A1="" & B1 blank → both blank → count
      # row2: A2 blank & B2="" → count
      # row3: A3 blank & B3="x" → B fails → no  ⇒ 2
      assert eval!(~s{COUNTIFS(A1:A3,"",B1:B3,"")}, cells) == 2

      # Drop B3: now row3 is the all-blank remainder (neither range occupies it),
      # counted via all_blank_extra ⇒ 3.
      allblank = %{"A1" => %{"v" => ""}, "B2" => %{"v" => ""}}
      assert eval!(~s{COUNTIFS(A1:A3,"",B1:B3,"")}, allblank) == 3
    end

    test "a large sparse rect exercises the MapSet occupied path" do
      # A1:A1000 area (1000) ≫ occupied set (4) → occupied_positions filters the
      # MapSet rather than walking the rectangle.
      cells = %{
        "A1" => %{"v" => "x"},
        "A500" => %{"v" => "x"},
        "B1" => %{"v" => 5},
        "B500" => %{"v" => 50}
      }

      assert eval!(~s{COUNTIFS(A1:A1000,"x",B1:B1000,">=10")}, cells) == 1
    end
  end

  describe "SUMIFS" do
    test "the sum range is the FIRST argument (reverse of SUMIF)" do
      # Asymmetric: the sum column holds numbers, the criteria column holds text.
      # If sum/criteria order were swapped, "x" would match nothing → 0.
      cells = %{
        "A1" => %{"v" => "x"},
        "A2" => %{"v" => "y"},
        "A3" => %{"v" => "x"},
        "C1" => %{"v" => 100},
        "C2" => %{"v" => 200},
        "C3" => %{"v" => 300}
      }

      assert eval!(~s{SUMIFS(C1:C3,A1:A3,"x")}, cells) == 400
    end

    test "two-pair AND sum" do
      cells = %{
        "A1" => %{"v" => "north"},
        "A2" => %{"v" => "north"},
        "A3" => %{"v" => "south"},
        "B1" => %{"v" => 1},
        "B2" => %{"v" => 0},
        "B3" => %{"v" => 1},
        "C1" => %{"v" => 10},
        "C2" => %{"v" => 20},
        "C3" => %{"v" => 30}
      }

      # north AND B=1 → only row 1 → 10.
      assert eval!(~s{SUMIFS(C1:C3,A1:A3,"north",B1:B3,1)}, cells) == 10
    end

    test "an error in a MATCHED sum cell propagates; an unmatched one does not" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 0},
        "B1" => %{"f" => "1/0"},
        "B2" => %{"v" => 5}
      }

      assert eval!("SUMIFS(B1:B2,A1:A2,1)", cells) == "#DIV/0!"
      assert eval!("SUMIFS(B1:B2,A1:A2,0)", cells) == 5
    end

    test "a sum range of a different shape is #VALUE!" do
      assert eval!(~s{SUMIFS(B1:B3,A1:A2,1)}) == "#VALUE!"
    end

    test "a large sparse rect sums via the MapSet path" do
      cells = %{
        "A1" => %{"v" => "x"},
        "A500" => %{"v" => "x"},
        "B1" => %{"v" => 5},
        "B500" => %{"v" => 50}
      }

      assert eval!(~s{SUMIFS(B1:B1000,A1:A1000,"x")}, cells) == 55
    end
  end

  describe "AVERAGEIFS" do
    test "two-pair AND average" do
      cells = %{
        "A1" => %{"v" => "x"},
        "A2" => %{"v" => "y"},
        "A3" => %{"v" => "x"},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => 99},
        "B3" => %{"v" => 30}
      }

      assert eval!(~s{AVERAGEIFS(B1:B3,A1:A3,"x")}, cells) == 20
    end

    test "zero matches is #DIV/0!" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "B1" => %{"v" => 10},
        "B2" => %{"v" => 20}
      }

      assert eval!(~s{AVERAGEIFS(B1:B2,A1:A2,">100")}, cells) == "#DIV/0!"
    end
  end

  describe "IF" do
    test "three-arg form takes the matching branch" do
      assert eval!(~s{IF(1>2,"yes","no")}) == "no"
      assert eval!(~s{IF(2>1,"yes","no")}) == "yes"
    end

    test "two-arg form defaults the else branch to FALSE" do
      assert eval!("IF(FALSE,1)") == false
      assert eval!("IF(TRUE,1)") == 1
    end

    test "numeric condition coerces (0 falsy)" do
      assert eval!("IF(0,1,2)") == 2
      assert eval!("IF(3,1,2)") == 1
    end

    test "blank condition is falsy" do
      assert eval!("IF(A9,1,2)") == 2
    end

    test "string condition is #VALUE!" do
      assert eval!(~s{IF("x",1,2)}) == "#VALUE!"
    end

    test "only the chosen branch evaluates (lazy)" do
      assert eval!("IF(TRUE,1,1/0)") == 1
      assert eval!("IF(FALSE,1/0,2)") == 2
    end
  end

  describe "ROUND" do
    test "rounds half away from zero" do
      assert eval!("ROUND(2.5)") == 3
      assert eval!("ROUND(-2.5)") == -3
    end

    test "digit counts, positive and negative" do
      assert eval!("ROUND(1.234,2)") == 1.23
      assert eval!("ROUND(123,-1)") == 120
      assert eval!("ROUND(125,-1)") == 130
    end

    test "integers pass through exactly" do
      assert eval!("ROUND(5)") == 5
      assert eval!("ROUND(5,2)") == 5
    end

    test "zero digits yields an integer" do
      assert eval!("ROUND(2.5,0)") === 3
    end

    test "15-digit decimal correction: half-digits at the target precision round away" do
      assert eval!("ROUND(1.005,2)") == 1.01
      assert eval!("ROUND(1.015,2)") == 1.02
      assert eval!("ROUND(1.255,2)") == 1.26
      # Already-exact scaling stays exact (2.675*100 lands on 267.5 here).
      assert eval!("ROUND(2.675,2)") == 2.68
    end

    test "guard: 0-digit half-away semantics untouched by the correction" do
      assert eval!("ROUND(2.5,0)") == 3
      assert eval!("ROUND(-2.5,0)") == -3
    end
  end

  describe "AND / OR" do
    test "combine truthy scalar args" do
      assert eval!("AND(TRUE,TRUE,1)") == true
      assert eval!("AND(TRUE,FALSE)") == false
      assert eval!("OR(FALSE,0)") == false
      assert eval!("OR(FALSE,1)") == true
    end

    test "numeric and blank args coerce like IF" do
      assert eval!("AND(1,2,3)") == true
      assert eval!("AND(1,0)") == false
      assert eval!("OR(A9)") == false
    end

    test "flatten a range keeping only numbers/booleans (text skipped)" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => "skip", "t" => "s"}
      }

      assert eval!("AND(A1:A3)", cells) == true
      assert eval!("OR(A1:A3)", cells) == true

      zeros = %{"A1" => %{"v" => 0}, "A2" => %{"v" => 0}}
      assert eval!("OR(A1:A2)", zeros) == false
      assert eval!("AND(A1:A2)", zeros) == false
    end

    test "an error argument propagates" do
      assert eval!("AND(TRUE,1/0)") == "#DIV/0!"
      assert eval!("OR(A1,FALSE)", %{"A1" => %{"v" => "#VALUE!", "t" => "e"}}) == "#VALUE!"
    end

    test "a string scalar is #VALUE!; zero coercible values is #VALUE!" do
      assert eval!(~s{AND("x")}) == "#VALUE!"
      # a range of only text yields nothing coercible
      assert eval!("AND(A1:A2)", %{"A1" => %{"v" => "a"}, "A2" => %{"v" => "b"}}) == "#VALUE!"
    end

    test "no args falls through to #VALUE!" do
      assert eval!("AND()") == "#VALUE!"
      assert eval!("OR()") == "#VALUE!"
    end
  end

  describe "NOT" do
    test "negates a truthy value" do
      assert eval!("NOT(TRUE)") == false
      assert eval!("NOT(FALSE)") == true
      assert eval!("NOT(0)") == true
      assert eval!("NOT(5)") == false
    end

    test "a string is #VALUE!, an error propagates, wrong arity is #VALUE!" do
      assert eval!(~s{NOT("x")}) == "#VALUE!"
      assert eval!("NOT(1/0)") == "#DIV/0!"
      assert eval!("NOT(TRUE,FALSE)") == "#VALUE!"
    end
  end

  describe "IFERROR" do
    test "returns the value when not an error" do
      assert eval!("IFERROR(42,0)") == 42
      assert eval!(~s{IFERROR("ok","fb")}) == "ok"
    end

    test "catches an error and returns the fallback" do
      assert eval!("IFERROR(1/0,0)") == 0
      assert eval!(~s{IFERROR(1/0,"n/a")}) == "n/a"
      assert eval!("IFERROR(A1,-1)", %{"A1" => %{"v" => "#REF!", "t" => "e"}}) == -1
    end

    test "wrong arity is #VALUE!" do
      assert eval!("IFERROR(1)") == "#VALUE!"
      assert eval!("IFERROR(1,2,3)") == "#VALUE!"
    end
  end

  describe "ROUNDUP / ROUNDDOWN" do
    test "round away from / toward zero" do
      assert eval!("ROUNDUP(1.1,0)") == 2
      assert eval!("ROUNDUP(1.234,2)") == 1.24
      assert eval!("ROUNDDOWN(1.9,0)") == 1
      assert eval!("ROUNDDOWN(1.239,2)") == 1.23
    end

    test "default digit count is 0" do
      assert eval!("ROUNDUP(1.1)") == 2
      assert eval!("ROUNDDOWN(1.9)") == 1
    end

    test "negatives round away from / toward zero" do
      assert eval!("ROUNDUP(-1.1,0)") == -2
      assert eval!("ROUNDDOWN(-1.9,0)") == -1
    end

    test "negative digit counts" do
      assert eval!("ROUNDUP(121,-1)") == 130
      assert eval!("ROUNDDOWN(129,-1)") == 120
      assert eval!("ROUNDUP(-121,-1)") == -130
      assert eval!("ROUNDDOWN(-129,-1)") == -120
    end

    test "integers pass through, errors propagate, wrong arity is #VALUE!" do
      assert eval!("ROUNDUP(5,2)") == 5
      assert eval!("ROUNDDOWN(5,2)") == 5
      assert eval!("ROUNDUP(1/0,2)") == "#DIV/0!"
      assert eval!("ROUNDUP(1,2,3)") == "#VALUE!"
    end

    test "15-digit decimal correction: scaling noise never leaks a step up/down" do
      # 1.1*100 = 110.00000000000001 — a naive ceil steps to 1.11.
      assert eval!("ROUNDUP(1.1,2)") == 1.1
      # 2.26*100 = 225.99999999999997 — a naive trunc steps to 2.25.
      assert eval!("ROUNDDOWN(2.26,2)") == 2.26
      # 4.35*100 = 434.99999999999994.
      assert eval!("ROUNDDOWN(4.35,2)") == 4.35
    end
  end

  describe "INT" do
    test "floors toward negative infinity" do
      assert eval!("INT(1.9)") == 1
      assert eval!("INT(-1.5)") == -2
      assert eval!("INT(5)") == 5
    end

    test "error propagates, wrong arity is #VALUE!" do
      assert eval!("INT(1/0)") == "#DIV/0!"
      assert eval!("INT()") == "#VALUE!"
    end
  end

  describe "text — LEN / TRIM / UPPER / LOWER" do
    test "LEN counts characters" do
      assert eval!(~s{LEN("hello")}) == 5
      assert eval!("LEN(A1)", %{"A1" => %{"v" => 123}}) == 3
      assert eval!("LEN(A9)") == 0
    end

    test "TRIM strips ends and collapses internal runs" do
      assert eval!(~s{TRIM("  a   b  ")}) == "a b"
    end

    test "UPPER / LOWER" do
      assert eval!(~s{UPPER("aBc")}) == "ABC"
      assert eval!(~s{LOWER("aBc")}) == "abc"
    end

    test "error propagates, wrong arity is #VALUE!" do
      assert eval!("LEN(1/0)") == "#DIV/0!"
      assert eval!("UPPER()") == "#VALUE!"
    end
  end

  describe "text — LEFT / RIGHT / MID" do
    @word %{"A1" => %{"v" => "barkpark", "t" => "s"}}

    test "LEFT / RIGHT default n=1" do
      assert eval!("LEFT(A1)", @word) == "b"
      assert eval!("RIGHT(A1)", @word) == "k"
    end

    test "LEFT / RIGHT with an explicit count" do
      assert eval!("LEFT(A1,4)", @word) == "bark"
      assert eval!("RIGHT(A1,4)", @word) == "park"
    end

    test "n greater than length returns the whole string; n=0 is empty" do
      assert eval!("LEFT(A1,100)", @word) == "barkpark"
      assert eval!("RIGHT(A1,100)", @word) == "barkpark"
      assert eval!("LEFT(A1,0)", @word) == ""
      assert eval!("RIGHT(A1,0)", @word) == ""
    end

    test "a negative count is #VALUE!" do
      assert eval!("LEFT(A1,-1)", @word) == "#VALUE!"
      assert eval!("RIGHT(A1,-1)", @word) == "#VALUE!"
    end

    test "MID is 1-based" do
      assert eval!("MID(A1,5,4)", @word) == "park"
      assert eval!("MID(A1,1,4)", @word) == "bark"
    end

    test "MID out-of-range length clips; bad bounds are #VALUE!" do
      assert eval!("MID(A1,5,100)", @word) == "park"
      assert eval!("MID(A1,100,3)", @word) == ""
      assert eval!("MID(A1,0,3)", @word) == "#VALUE!"
      assert eval!("MID(A1,1,-1)", @word) == "#VALUE!"
    end

    test "a range argument is #VALUE!" do
      assert eval!("LEFT(A1:A2,1)", @word) == "#VALUE!"
    end
  end

  describe "text — CONCATENATE / TEXTJOIN" do
    @parts %{
      "A1" => %{"v" => "a"},
      "A2" => %{"v" => ""},
      "A3" => %{"v" => "c"}
    }

    test "CONCATENATE joins scalars with type coercion" do
      assert eval!(~s{CONCATENATE("x",1,TRUE)}) == "x1TRUE"
    end

    test "CONCATENATE rejects a range" do
      assert eval!("CONCATENATE(A1:A3)", @parts) == "#VALUE!"
    end

    test "TEXTJOIN flattens ranges; blank range cells are dropped by flattening" do
      # A2 is an empty-string cell — it reads as blank, and range flattening
      # (range_values) drops blanks before TEXTJOIN sees them, so ignore_empty
      # has nothing to filter over this range either way.
      assert eval!("TEXTJOIN(\"-\",TRUE,A1:A3)", @parts) == "a-c"
      assert eval!("TEXTJOIN(\"-\",FALSE,A1:A3)", @parts) == "a-c"
    end

    test "TEXTJOIN with scalar args honors ignore_empty both ways" do
      assert eval!(~s{TEXTJOIN(",",TRUE,"a","","b")}) == "a,b"
      assert eval!(~s{TEXTJOIN(",",FALSE,"a","","b")}) == "a,,b"
    end

    test "TEXTJOIN propagates an error and needs at least one value arg" do
      assert eval!(~s{TEXTJOIN(",",TRUE,1/0)}) == "#DIV/0!"
      assert eval!(~s{TEXTJOIN(",",TRUE)}) == "#VALUE!"
    end
  end

  describe "text — EXACT" do
    test "case-sensitive equality yields a boolean" do
      assert cell!(~s{EXACT("Bark","Bark")}) == %{
               "f" => ~s{EXACT("Bark","Bark")},
               "v" => true,
               "t" => "b"
             }

      assert eval!(~s{EXACT("Bark","bark")}) == false
      assert eval!(~s{EXACT("a","a ")}) == false
    end

    test "error propagates, wrong arity is #VALUE!" do
      assert eval!(~s{EXACT("a",1/0)}) == "#DIV/0!"
      assert eval!(~s{EXACT("a")}) == "#VALUE!"
    end
  end

  describe "text — FIND (case-sensitive, no wildcards)" do
    @hay %{"A1" => %{"v" => "aBaBa", "t" => "s"}}

    test "1-based first-match position" do
      assert eval!(~s{FIND("B","aBaBa")}) == 2
      assert eval!(~s{FIND("B",A1)}, @hay) == 2
    end

    test "start offsets the search" do
      assert eval!(~s{FIND("B","aBaBa",3)}) == 4
    end

    test "case-sensitive; a wildcard is a literal char" do
      assert eval!(~s{FIND("b","aBaBa")}) == "#VALUE!"
      assert eval!(~s{FIND("*","a*b")}) == 2
    end

    test "an empty needle finds the start; a miss or bad start is #VALUE!" do
      assert eval!(~s{FIND("","abc")}) == 1
      assert eval!(~s{FIND("z","abc")}) == "#VALUE!"
      assert eval!(~s{FIND("a","abc",5)}) == "#VALUE!"
      assert eval!(~s{FIND("a","abc",0)}) == "#VALUE!"
    end

    test "error propagates" do
      assert eval!(~s{FIND("a",1/0)}) == "#DIV/0!"
    end
  end

  describe "text — SEARCH (case-insensitive, wildcards, UNANCHORED)" do
    test "case-insensitive first-match position" do
      assert eval!(~s{SEARCH("b","aBaBa")}) == 2
      assert eval!(~s{SEARCH("B","aBaBa",3)}) == 4
    end

    test "wildcards match anywhere (unanchored)" do
      # `?c` matches the substring 'bc' inside 'abcd' at position 2 — an
      # unanchored regex, unlike the anchored MATCH/criteria path.
      assert eval!(~s{SEARCH("?c","abcd")}) == 2
      assert eval!(~s{SEARCH("b*d","zzabcd")}) == 4
      # A literal `*` via `~` escaping.
      assert eval!(~s{SEARCH("~*","a*b")}) == 2
    end

    test "a miss and out-of-range start are #VALUE!" do
      assert eval!(~s{SEARCH("z","abc")}) == "#VALUE!"
      assert eval!(~s{SEARCH("a","abc",5)}) == "#VALUE!"
      assert eval!(~s{SEARCH("a","abc",0)}) == "#VALUE!"
    end
  end

  describe "text — SUBSTITUTE" do
    test "replaces every occurrence by default" do
      assert eval!(~s{SUBSTITUTE("a-b-c","-","+")}) == "a+b+c"
    end

    test "the 4th arg replaces only the nth occurrence" do
      assert eval!(~s{SUBSTITUTE("a-b-c-d","-","+",2)}) == "a-b+c-d"
      assert eval!(~s{SUBSTITUTE("a-b-c-d","-","+",1)}) == "a+b-c-d"
      # n beyond the occurrence count leaves the text unchanged.
      assert eval!(~s{SUBSTITUTE("a-b","-","+",5)}) == "a-b"
    end

    test "n < 1 is #VALUE!; an empty old leaves text unchanged" do
      assert eval!(~s{SUBSTITUTE("a-b","-","+",0)}) == "#VALUE!"
      assert eval!(~s{SUBSTITUTE("abc","","x")}) == "abc"
      assert eval!(~s{SUBSTITUTE("abc","","x",1)}) == "abc"
    end

    test "error propagates" do
      assert eval!(~s{SUBSTITUTE("a","-",1/0)}) == "#DIV/0!"
    end
  end

  describe "text — REPLACE" do
    test "1-based splice of count chars" do
      assert eval!(~s{REPLACE("hello",2,3,"XY")}) == "hXYo"
      # count 0 inserts without deleting.
      assert eval!(~s{REPLACE("hello",1,0,"X")}) == "Xhello"
      # count past the end truncates.
      assert eval!(~s{REPLACE("hello",4,99,"Z")}) == "helZ"
    end

    test "start < 1 or count < 0 is #VALUE!" do
      assert eval!(~s{REPLACE("hello",0,1,"X")}) == "#VALUE!"
      assert eval!(~s{REPLACE("hello",1,-1,"X")}) == "#VALUE!"
    end
  end

  describe "text — REPT" do
    test "repeats n times" do
      assert eval!(~s{REPT("ab",3)}) == "ababab"
      assert eval!(~s{REPT("ab",0)}) == ""
    end

    test "n < 0 is #VALUE!" do
      assert eval!(~s{REPT("ab",-1)}) == "#VALUE!"
    end

    test "over the 32,767-char cap is #VALUE! (recompute stays total)" do
      assert eval!(~s{REPT("ab",1000000)}) == "#VALUE!"
    end
  end

  describe "text — PROPER" do
    test "capitalises each word" do
      assert eval!(~s{PROPER("hello world")}) == "Hello World"
      assert eval!(~s{PROPER("aBC dEF")}) == "Abc Def"
      assert eval!(~s{PROPER("2-cent")}) == "2-Cent"
    end
  end

  describe "text — VALUE" do
    test "parses numeric text" do
      assert eval!(~s{VALUE("42")}) == 42
      assert eval!(~s{VALUE(" 1.5 ")}) == 1.5
    end

    test "a trailing percent scales by 1/100" do
      assert eval!(~s{VALUE("50%")}) == 0.5
    end

    test "unparseable text is #VALUE!" do
      assert eval!(~s{VALUE("abc")}) == "#VALUE!"
      assert eval!(~s{VALUE("")}) == "#VALUE!"
    end

    test "a mantissa that overflows float64 is #VALUE!, not a raise" do
      huge = String.duplicate("9", 400) <> ".5"
      assert eval!(~s{VALUE("#{huge}")}) == "#VALUE!"
    end

    test "currency symbols, grouping commas, parens-negative, bare exponent" do
      assert eval!(~s{VALUE("1,234")}) == 1234
      assert eval!(~s{VALUE("1,234,567.5")}) == 1_234_567.5
      assert eval!(~s{VALUE("$5")}) == 5
      assert eval!(~s{VALUE("€7.5")}) == 7.5
      assert eval!(~s{VALUE("£2")}) == 2
      assert eval!(~s{VALUE("kr 99")}) == 99
      assert eval!(~s{VALUE("-$5")}) == -5
      assert eval!(~s{VALUE("(5)")}) == -5
      assert eval!(~s{VALUE("($1,234.5)")}) == -1234.5
      assert eval!(~s{VALUE("1e3")}) == 1000
    end

    test "guards: % scaling stays exact; malformed grouping stays #VALUE!" do
      assert eval!(~s{VALUE("50%")}) == 0.5
      assert eval!(~s{VALUE("200%")}) === 2
      assert eval!(~s{VALUE("1,2,3")}) == "#VALUE!"
      assert eval!(~s{VALUE("12,34")}) == "#VALUE!"
      assert eval!(~s{VALUE("$")}) == "#VALUE!"
      assert eval!(~s{VALUE("(5")}) == "#VALUE!"
    end
  end

  # ── info (IS* predicates) ───────────────────────────────────────────────────

  describe "info — IS* predicates" do
    @mix %{
      "A1" => %{"v" => ""},
      "A2" => %{"v" => 42},
      "A3" => %{"v" => "hi", "t" => "s"},
      "A4" => %{"v" => true}
    }

    test "ISBLANK / ISNUMBER / ISTEXT / ISLOGICAL classify" do
      assert eval!("ISBLANK(A1)", @mix) == true
      assert eval!("ISBLANK(A2)", @mix) == false
      assert eval!("ISNUMBER(A2)", @mix) == true
      assert eval!("ISNUMBER(A3)", @mix) == false
      assert eval!("ISTEXT(A3)", @mix) == true
      assert eval!("ISTEXT(A2)", @mix) == false
      assert eval!("ISLOGICAL(A4)", @mix) == true
      assert eval!("ISLOGICAL(A2)", @mix) == false
    end

    test "a bare blank ref is ISBLANK" do
      assert eval!("ISBLANK(Z1)") == true
    end

    test "ISERROR / ISERR / ISNA never propagate the argument's error" do
      assert eval!("ISERROR(1/0)") == true
      assert eval!("ISERROR(NA())") == true
      assert eval!("ISERROR(1)") == false
      assert eval!("ISERR(1/0)") == true
      # ISERR is false for #N/A specifically.
      assert eval!("ISERR(NA())") == false
      assert eval!("ISNA(NA())") == true
      assert eval!("ISNA(1/0)") == false
    end

    test "the result is a boolean cell, wrong arity is #VALUE!" do
      assert cell!("ISNUMBER(1)")["t"] == "b"
      assert eval!("ISNUMBER(1,2)") == "#VALUE!"
    end
  end

  # ── branching (CHOOSE / SWITCH / IFS) ───────────────────────────────────────

  describe "branching — CHOOSE" do
    test "picks the kth value" do
      assert eval!(~s{CHOOSE(2,"a","b","c")}) == "b"
    end

    test "evaluates ONLY the chosen branch (lazy)" do
      assert eval!("CHOOSE(1,5,1/0)") == 5
    end

    test "out-of-range k is #VALUE!, an error k propagates" do
      assert eval!("CHOOSE(0,1,2)") == "#VALUE!"
      assert eval!("CHOOSE(3,1,2)") == "#VALUE!"
      assert eval!("CHOOSE(1/0,1,2)") == "#DIV/0!"
    end
  end

  describe "branching — SWITCH" do
    test "matches a value and returns its result" do
      assert eval!(~s{SWITCH(2,1,"one",2,"two")}) == "two"
      assert eval!(~s{SWITCH("B","a",1,"b",2)}) == 2
    end

    test "a trailing odd arg is the default; no match + no default is #N/A" do
      assert eval!(~s{SWITCH(9,1,"one","fallback")}) == "fallback"
      assert eval!(~s{SWITCH(9,1,"one")}) == "#N/A"
    end

    test "evaluates ONLY the matched result (lazy), cross-type never matches" do
      assert eval!("SWITCH(1,1,5,2,1/0)") == 5
      assert eval!(~s{SWITCH(1,"1","text",5)}) == 5
    end

    test "an error in the switched expression propagates" do
      assert eval!("SWITCH(1/0,1,2)") == "#DIV/0!"
    end
  end

  describe "branching — IFS" do
    test "returns the first true condition's result" do
      assert eval!(~s{IFS(FALSE,"a",TRUE,"b")}) == "b"
      assert eval!("IFS(1>2,10,3>2,20)") == 20
    end

    test "conditions and results evaluate lazily" do
      # cond1 false → its result 1/0 is never evaluated; cond2 true → 5.
      assert eval!("IFS(FALSE,1/0,TRUE,5)") == 5
    end

    test "odd arity is #VALUE!; none true is #N/A" do
      assert eval!("IFS(TRUE,1,FALSE)") == "#VALUE!"
      assert eval!("IFS(FALSE,1,FALSE,2)") == "#N/A"
    end

    test "a non-coercible condition is #VALUE!, an error propagates" do
      assert eval!(~s{IFS("x",1)}) == "#VALUE!"
      assert eval!("IFS(1/0,1)") == "#DIV/0!"
    end
  end

  describe "dates — DATE / YEAR / MONTH / DAY" do
    test "DATE builds a date" do
      assert cell!("DATE(2024,2,29)") == %{
               "f" => "DATE(2024,2,29)",
               "v" => "2024-02-29",
               "t" => "date"
             }
    end

    test "an impossible date is #VALUE!" do
      assert eval!("DATE(2024,2,30)") == "#VALUE!"
      assert eval!("DATE(2023,2,29)") == "#VALUE!"
    end

    test "YEAR / MONTH / DAY read a date-typed cell" do
      dates = %{"A1" => %{"v" => "2026-06-12", "t" => "date"}}
      assert eval!("YEAR(A1)", dates) == 2026
      assert eval!("MONTH(A1)", dates) == 6
      assert eval!("DAY(A1)", dates) == 12
    end

    test "YEAR / MONTH / DAY read a datetime-typed cell" do
      dt = %{"A1" => %{"v" => "2026-06-12T10:00:00Z", "t" => "datetime"}}
      assert eval!("YEAR(A1)", dt) == 2026
      assert eval!("DAY(A1)", dt) == 12
    end

    test "YEAR of a non-date is #VALUE!, error propagates" do
      assert eval!("YEAR(5)") == "#VALUE!"
      assert eval!("YEAR(1/0)") == "#DIV/0!"
    end
  end

  describe "dates — TODAY / NOW (volatile)" do
    test "TODAY yields a date-typed cell" do
      cell = cell!("TODAY()")
      assert cell["t"] == "date"
      assert {:ok, _} = Date.from_iso8601(cell["v"])
    end

    test "NOW yields a datetime-typed cell" do
      cell = cell!("NOW()")
      assert cell["t"] == "datetime"
      assert {:ok, _, _} = DateTime.from_iso8601(cell["v"])
    end

    test "an argument falls through to #VALUE!" do
      assert eval!("TODAY(1)") == "#VALUE!"
      assert eval!("NOW(1)") == "#VALUE!"
    end
  end

  describe "numeric-extreme guards (recompute stays total)" do
    test "float * and + overflow yields #NUM! instead of raising" do
      big = %{"A1" => %{"v" => 1.0e308}}
      # 1.0e308 * 1.0e308 and 1.0e308 + 1.0e308 both exceed the double range —
      # a domain/range overflow is #NUM!, not #VALUE!.
      assert eval!("A1*A1", big) == "#NUM!"
      assert eval!("A1+A1", big) == "#NUM!"
      assert eval!("A1-A1", big) == 0.0

      # a sum that stays in range is untouched
      half = %{"A1" => %{"v" => 5.0e307}}
      assert eval!("A1+A1", half) == 1.0e308
    end

    test "an unbounded integer exponent is capped to #NUM!, no runaway bignum" do
      # The float :math.pow overflow rescue now yields #NUM! (a domain/range
      # miss), matching the (-8)^0.5 parity flip.
      assert eval!("2^100000000") == "#NUM!"
      # small exponents and the identity bases are untouched
      assert eval!("2^10") == 1024
      # 2^1023 fits float64; 2^1024 (~1.8e308) just overflows it -> #NUM!, like
      # Excel. The old exact-bignum expectation WAS the crash bug (a bignum that
      # then blows up float division, e.g. 99^200/7).
      assert eval!("2^1023") == Integer.pow(2, 1023)
      assert eval!("2^1024") == "#NUM!"
      assert eval!("1^100000000") == 1
      assert eval!("(-1)^100000000") == 1
    end

    test "ROUND with a huge digit count returns quickly (no giant bignum)" do
      # integer input short-circuits regardless of digit count
      assert eval!("ROUND(1,100000000)") == 1
      # a float still rounds; the internal scale exponent is clamped so it
      # cannot build a hundred-million-digit power of ten.
      assert_in_delta eval!("ROUND(1.5,100000000)"), 1.5, 1.0e-6
      assert eval!("ROUND(1.5,-100000000)") == 0
    end
  end

  # #871 closed power/divide/round/date/wildcard/MODE, but the float-op sites in
  # VAR/STDEV/PERCENTILE/MEDIAN/SPARKLINE stayed unwrapped: a single bignum item
  # (a 2^1023+2^1023 sum, or an imported raw "v") coerced past float64 raised an
  # ArithmeticError, crashing the whole recompute -> a 500 + Session crash for
  # EVERY collaborator. Each case here raises on the unfixed source and must now
  # degrade to #NUM! — and do so instantly (the guard is a rescue, not a retry).
  describe "bignum crash class (the #871 remainder)" do
    # 2^1023 fits float64 and is a valid stored value; its DOUBLING (the VAR/
    # MEDIAN internal sum) is the first magnitude that blows up `/`.
    @big Integer.pow(2, 1023)
    @over Integer.pow(2, 1030)

    test "VAR/VARP over a same-magnitude pair whose sum overflows is #NUM!, not a raise" do
      assert eval!("VAR(2^1023,2^1023)") == "#NUM!"
      assert eval!("VARP(2^1023,2^1023)") == "#NUM!"
    end

    test "STDEV/STDEVP over a bignum value is #NUM!, not a raise" do
      # 2^1023*4 = 2^1025 (exact integer), then mean = value/1 coerces to float.
      assert eval!("STDEVP(2^1023*4)") == "#NUM!"
      assert eval!("STDEV(2^1023*4,2^1023*4)") == "#NUM!"
    end

    test "PERCENTILE interpolating across a bignum neighbour is #NUM!, not a raise" do
      cells = %{"A1" => %{"v" => 0}, "A2" => %{"v" => @over}}
      assert eval!("PERCENTILE(A1:A2,0.3)", cells) == "#NUM!"
    end

    test "MEDIAN over an odd-sum bignum pair is #NUM!, not a raise" do
      cells = %{"A1" => %{"v" => @big}, "A2" => %{"v" => @big + 1}}
      assert eval!("MEDIAN(A1:A2)", cells) == "#NUM!"
    end

    test "SPARKLINE over a bignum-spanned range is #NUM!, not a raise" do
      cells = %{"A1" => %{"v" => 0}, "A2" => %{"v" => @over}}
      assert eval!("SPARKLINE(A1:A2)", cells) == "#NUM!"
    end

    # The import path: the SAME bignum arrives as a stored raw "v" (from an xlsx/
    # csv import), never through a formula. It must be caught identically.
    test "imported raw bignum cells hit every stat the same way (no raise)" do
      pair = %{"A1" => %{"v" => @big}, "A2" => %{"v" => @big}}
      assert eval!("VAR(A1:A2)", pair) == "#NUM!"
      assert eval!("STDEVP(A1:A2)", pair) == "#NUM!"

      one = %{"A1" => %{"v" => @over}}
      assert eval!("STDEVP(A1)", one) == "#NUM!"
      assert eval!("AVERAGE(A1)", one) == "#NUM!"
    end

    test "a formula RESULT past float64 is canonicalised to #NUM! at the boundary" do
      # 2^1023*4 = 2^1025 as an integer never raises building it, but displaying
      # it (or feeding it onward) would the moment a float coercion touched it.
      assert eval!("2^1023*4") == "#NUM!"
      # the in-range 2^1023 is still the exact bignum (no display regression).
      assert eval!("2^1023") == @big
    end

    test "the whole class resolves instantly (a rescue, never a hang)" do
      {micros, _} =
        :timer.tc(fn ->
          assert eval!("VAR(2^1023,2^1023)") == "#NUM!"
          assert eval!("STDEVP(2^1023*4)") == "#NUM!"
        end)

      assert micros < 1_000_000, "expected sub-second, took #{micros}µs"
    end
  end

  describe "ABS" do
    test "ints stay ints, floats stay floats" do
      assert eval!("ABS(-3)") === 3
      assert eval!("ABS(3)") === 3
      assert eval!("ABS(-2.5)") === 2.5
    end
  end

  describe "function dispatch" do
    test "names are case-insensitive" do
      assert eval!("sum(1,2)") == 3
      assert eval!("Sum(1,2)") == 3
      assert eval!("iF(true,1,2)") == 1
    end

    test "a known function with the wrong arity is #VALUE!" do
      assert eval!("ROUND(1,2,3)") == "#VALUE!"
      assert eval!("ABS()") == "#VALUE!"
      assert eval!("IF(1)") == "#VALUE!"
    end
  end

  # ── cycles ──────────────────────────────────────────────────────────────────

  describe "cycles" do
    test "direct self-reference" do
      out = run(%{"A1" => %{"f" => "A1+1", "v" => 7}})
      assert out["A1"]["v"] == "#CYCLE!"
      assert out["A1"]["t"] == "e"
    end

    test "mutual cycle marks both cells" do
      out = run(%{"A1" => %{"f" => "B1"}, "B1" => %{"f" => "A1"}})
      assert out["A1"]["v"] == "#CYCLE!"
      assert out["B1"]["v"] == "#CYCLE!"
    end

    test "long cycle marks every cell on it" do
      out =
        run(%{
          "A1" => %{"f" => "C1+1"},
          "B1" => %{"f" => "A1+1"},
          "C1" => %{"f" => "B1+1"}
        })

      for addr <- ["A1", "B1", "C1"], do: assert(out[addr]["v"] == "#CYCLE!")
    end

    test "a formula depending on a cycle gets #CYCLE! too (propagation)" do
      out =
        run(%{
          "A1" => %{"f" => "B1"},
          "B1" => %{"f" => "A1"},
          "D1" => %{"f" => "A1+1"}
        })

      assert out["D1"]["v"] == "#CYCLE!"
    end

    test "an independent formula is unaffected by a cycle elsewhere" do
      out = run(%{"A1" => %{"f" => "A1"}, "E1" => %{"f" => "1+1"}})
      assert out["E1"]["v"] == 2
    end

    test "a cycle through a range" do
      out = run(%{"A1" => %{"f" => "SUM(A1:B1)"}, "B1" => %{"v" => 1}})
      assert out["A1"]["v"] == "#CYCLE!"
    end
  end

  # ── error values ────────────────────────────────────────────────────────────

  describe "#REF! — out of grammar or beyond grid" do
    test "parse failures" do
      assert eval!("1+") == "#REF!"
      assert eval!(")(") == "#REF!"
      assert eval!("FOO") == "#REF!"
      assert eval!("") == "#REF!"
      assert eval!("=") == "#REF!"
    end

    test "cross-tab syntax is out of scope" do
      assert eval!("Tab2!A1") == "#REF!"
    end

    test "refs beyond the grid bounds" do
      # XFE = column 16_385 (one past XFD); row max is 1_048_576.
      assert eval!("XFE1") == "#REF!"
      assert eval!("A1048577") == "#REF!"
    end

    test "the outermost in-bounds cell is a valid (blank) ref" do
      assert eval!("XFD1048576") == 0
    end
  end

  describe "#VALUE! — type mismatch" do
    test "string in arithmetic, literal and via ref" do
      assert eval!(~s("abc"+1)) == "#VALUE!"
      assert eval!("A1*2", %{"A1" => %{"v" => "abc"}}) == "#VALUE!"
    end

    test "unary minus on a non-number" do
      assert eval!(~s(-"abc")) == "#VALUE!"
    end
  end

  describe "#DIV/0!" do
    test "division by integer and float zero" do
      assert eval!("1/0") == "#DIV/0!"
      assert eval!("1/0.0") == "#DIV/0!"
    end

    test "zero to a negative power" do
      assert eval!("0^-2") == "#DIV/0!"
    end
  end

  describe "#N/A" do
    test "NA() writes the #N/A error cell" do
      assert cell!("NA()") == %{"f" => "NA()", "v" => "#N/A", "t" => "e"}
    end

    test "#N/A propagates through arithmetic from a t:e cell" do
      assert eval!("A1+1", %{"A1" => %{"v" => "#N/A", "t" => "e"}}) == "#N/A"
    end

    test "#N/A propagates from a bare literal error cell (no t)" do
      assert eval!("A1+1", %{"A1" => %{"v" => "#N/A"}}) == "#N/A"
    end

    test "IFERROR catches #N/A" do
      assert eval!("IFERROR(NA(),0)") == 0
    end

    test "SUM propagates #N/A while COUNT skips it and COUNTA counts it" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"f" => "NA()"}, "A3" => %{"v" => 2}}
      assert eval!("SUM(A1:A3)", cells) == "#N/A"
      assert eval!("COUNT(A1:A3)", cells) == 2
      assert eval!("COUNTA(A1:A3)", cells) == 3
    end

    test "NA with an argument is #VALUE!" do
      assert eval!("NA(1)") == "#VALUE!"
    end
  end

  describe "#NUM! — numeric domain error" do
    test "a formula yielding #NUM! writes v/t = e" do
      assert cell!("(-8)^0.5") == %{"f" => "(-8)^0.5", "v" => "#NUM!", "t" => "e"}
    end

    test "#NUM! propagates through a dependent formula" do
      out = run(%{"A1" => %{"f" => "(-8)^0.5"}, "B1" => %{"f" => "A1+1"}})
      assert out["A1"]["v"] == "#NUM!"
      assert out["B1"]["v"] == "#NUM!"
    end

    test "IFERROR catches a #NUM! (SMALL with k=0)" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}}
      assert eval!(~s{IFERROR(SMALL(A1:A2,0),"x")}, cells) == "x"
    end

    test "a literal #NUM! cell propagates (t:e and bare)" do
      assert eval!("A1+1", %{"A1" => %{"v" => "#NUM!", "t" => "e"}}) == "#NUM!"
      assert eval!("A1+1", %{"A1" => %{"v" => "#NUM!"}}) == "#NUM!"
    end

    test "SUM propagates #NUM! while COUNT skips it" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"f" => "(-8)^0.5"}, "A3" => %{"v" => 2}}
      assert eval!("SUM(A1:A3)", cells) == "#NUM!"
      assert eval!("COUNT(A1:A3)", cells) == 2
    end
  end

  describe "MEDIAN" do
    @med %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}, "A4" => %{"v" => 4}}

    test "odd count returns the middle after sorting" do
      assert eval!("MEDIAN(A1:A3)", @med) == 2
      assert eval!("MEDIAN(3,1,2)") == 2
    end

    test "even count averages the two middles; a two-value median stays an exact int" do
      assert eval!("MEDIAN(1,3)") === 2
      assert eval!("MEDIAN(A1:A4)", @med) == 2.5
    end

    test "no numbers is #NUM!" do
      assert eval!("MEDIAN(B1:B2)") == "#NUM!"
    end
  end

  describe "SMALL / LARGE" do
    @arr %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}}

    test "kth smallest / largest after sorting" do
      assert eval!("SMALL(A1:A3,1)", @arr) == 1
      assert eval!("SMALL(A1:A3,2)", @arr) == 2
      assert eval!("LARGE(A1:A3,1)", @arr) == 3
      assert eval!("LARGE(A1:A3,2)", @arr) == 2
    end

    test "k below 1 or above n is #NUM!" do
      assert eval!("SMALL(A1:A3,0)", @arr) == "#NUM!"
      assert eval!("SMALL(A1:A3,4)", @arr) == "#NUM!"
      assert eval!("LARGE(A1:A3,4)", @arr) == "#NUM!"
    end
  end

  describe "PERCENTILE" do
    @five %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3},
      "A4" => %{"v" => 4},
      "A5" => %{"v" => 5}
    }

    test "0 / 0.5 / 1 hit min / median / max exactly" do
      assert eval!("PERCENTILE(A1:A5,0)", @five) == 1
      assert eval!("PERCENTILE(A1:A5,0.5)", @five) == 3
      assert eval!("PERCENTILE(A1:A5,1)", @five) == 5
    end

    test "an off-node fraction interpolates its neighbours" do
      four = Map.delete(@five, "A5")
      assert eval!("PERCENTILE(A1:A4,0.5)", four) == 2.5
    end

    test "empty input or a fraction outside 0..1 is #NUM!" do
      assert eval!("PERCENTILE(B1:B2,0.5)") == "#NUM!"
      assert eval!("PERCENTILE(A1:A5,1.5)", @five) == "#NUM!"
      assert eval!("PERCENTILE(A1:A5,-0.1)", @five) == "#NUM!"
    end
  end

  describe "QUARTILE" do
    @five %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3},
      "A4" => %{"v" => 4},
      "A5" => %{"v" => 5}
    }

    test "q 0..4 delegate to the matching percentile" do
      assert eval!("QUARTILE(A1:A5,0)", @five) == 1
      assert eval!("QUARTILE(A1:A5,1)", @five) == 2
      assert eval!("QUARTILE(A1:A5,2)", @five) == 3
      assert eval!("QUARTILE(A1:A5,4)", @five) == 5
    end

    test "q outside 0..4 is #NUM!" do
      assert eval!("QUARTILE(A1:A5,5)", @five) == "#NUM!"
      assert eval!("QUARTILE(A1:A5,-1)", @five) == "#NUM!"
    end
  end

  describe "MODE" do
    test "the most frequent value" do
      assert eval!("MODE(1,2,2,3)") == 2
    end

    test "no repeat is #N/A (not #NUM!)" do
      assert eval!("MODE(1,2,3)") == "#N/A"
    end

    test "a frequency tie resolves to the earliest first occurrence" do
      assert eval!("MODE(1,1,2,2)") == 1
    end
  end

  describe "RANK" do
    # {7,5,5,3}: 5 ranks 2 (skip), 3 ranks 4 — Excel's competition ranking.
    @rk %{"A1" => %{"v" => 7}, "A2" => %{"v" => 5}, "A3" => %{"v" => 5}, "A4" => %{"v" => 3}}

    test "descending is the default; ties share a rank and skip the next" do
      assert eval!("RANK(7,A1:A4)", @rk) == 1
      assert eval!("RANK(5,A1:A4)", @rk) == 2
      assert eval!("RANK(3,A1:A4)", @rk) == 4
    end

    test "order arg 1 ranks ascending" do
      assert eval!("RANK(3,A1:A4,1)", @rk) == 1
      assert eval!("RANK(5,A1:A4,1)", @rk) == 2
      assert eval!("RANK(7,A1:A4,1)", @rk) == 4
    end

    test "an absent value is #N/A; a text x is #VALUE!" do
      assert eval!("RANK(99,A1:A4)", @rk) == "#N/A"
      assert eval!(~s{RANK("a",A1:A4)}, @rk) == "#VALUE!"
    end
  end

  describe "VAR / STDEV / VARP / STDEVP" do
    @data %{
      "A1" => %{"v" => 2},
      "A2" => %{"v" => 4},
      "A3" => %{"v" => 4},
      "A4" => %{"v" => 4},
      "A5" => %{"v" => 5},
      "A6" => %{"v" => 5},
      "A7" => %{"v" => 7},
      "A8" => %{"v" => 9}
    }

    test "sample variance / stdev use n-1" do
      assert_in_delta eval!("VAR(A1:A8)", @data), 4.571428571, 1.0e-6
      assert_in_delta eval!("STDEV(A1:A8)", @data), 2.138089935, 1.0e-6
    end

    test "population variance / stdev use n" do
      assert eval!("VARP(A1:A8)", @data) == 4.0
      assert eval!("STDEVP(A1:A8)", @data) == 2.0
    end

    test "sample below two values is #DIV/0!; a single population value is 0" do
      assert eval!("VAR(5)") == "#DIV/0!"
      assert eval!("STDEV(5)") == "#DIV/0!"
      assert eval!("VARP(5)") == 0.0
      assert eval!("STDEVP(5)") == 0.0
    end

    test "population over no numbers is #DIV/0!" do
      assert eval!("VARP(B1:B2)") == "#DIV/0!"
    end
  end

  describe "Engine.function_names/0" do
    test "sorted, deduped of nothing, and carries the known names" do
      names = Engine.function_names()
      assert names == Enum.sort(names)
      assert Enum.uniq(names) == names
      assert "SUM" in names
      assert "VLOOKUP" in names
      assert "MEDIAN" in names
      # Aliases are NOT collapsed — both AVG and AVERAGE are present.
      assert "AVG" in names
      assert "AVERAGE" in names
    end
  end

  describe "Engine.function_specs/0" do
    test "the spec set is exactly function_names/0 — no drift either way" do
      names = MapSet.new(Engine.function_names())
      spec_names = MapSet.new(Engine.function_specs(), & &1.name)

      # The drift tripwire: every name has exactly one spec and vice versa.
      assert spec_names == names
      # One spec per name — no duplicate spec entries.
      assert length(Engine.function_specs()) == MapSet.size(names)
    end

    test "every doc is a nonempty one-liner (<= 90 chars)" do
      for %{name: name, doc: doc} <- Engine.function_specs() do
        assert is_binary(doc) and doc != "", "#{name} has an empty doc"
        assert String.length(doc) <= 90, "#{name} doc is too long (#{String.length(doc)})"
      end
    end

    test "every arg name is a nonempty string with boolean flags" do
      for %{name: name, args: args} <- Engine.function_specs(),
          arg <- args do
        assert is_binary(arg.name) and arg.name != "", "#{name} has a blank arg name"
        assert is_boolean(arg.optional)
        assert is_boolean(arg.variadic)
      end
    end

    test "SUM's shape: a required value1 plus a variadic-optional value2" do
      sum = Enum.find(Engine.function_specs(), &(&1.name == "SUM"))

      assert sum.args == [
               %{name: "value1", optional: false, variadic: false},
               %{name: "value2", optional: true, variadic: true}
             ]
    end
  end

  describe "adding a stat function flips a previously-stale import to live" do
    test "a stale MEDIAN import recomputes and drops the stale flag" do
      out = run(%{"A1" => %{"f" => "MEDIAN(1,3)", "v" => 99, "t" => "n", "stale" => true}})
      assert out["A1"] == %{"f" => "MEDIAN(1,3)", "v" => 2, "t" => "n"}
    end
  end

  describe "error propagation" do
    test "errors flow through refs and operators" do
      out =
        run(%{
          "B1" => %{"f" => "1/0"},
          "C1" => %{"f" => "B1+1"},
          "D1" => %{"f" => "-C1"}
        })

      assert out["C1"]["v"] == "#DIV/0!"
      assert out["D1"]["v"] == "#DIV/0!"
    end

    test "a literal error cell propagates" do
      assert eval!("A1+1", %{"A1" => %{"v" => "#REF!", "t" => "e"}}) == "#REF!"
    end

    test "computed errors carry t e" do
      assert cell!("1/0")["t"] == "e"
      assert cell!("1+")["t"] == "e"
    end
  end

  # ── stale semantics ─────────────────────────────────────────────────────────

  describe "stale — unknown function names" do
    test "unknown function leaves v/t untouched and sets stale" do
      out = run(%{"A1" => %{"f" => "NPV(0.1,5)", "v" => 42, "t" => "n"}})
      assert out["A1"] == %{"f" => "NPV(0.1,5)", "v" => 42, "t" => "n", "stale" => true}
    end

    test "unknown function nested inside a known one is still stale" do
      out = run(%{"A1" => %{"f" => "SUM(FOO(1),2)", "v" => 9}})
      assert out["A1"]["v"] == 9
      assert out["A1"]["stale"] == true
    end

    test "a function name that looks like a ref (LOG10) goes stale, not #REF!" do
      out = run(%{"A1" => %{"f" => "LOG10(100)", "v" => 2}})
      assert out["A1"]["v"] == 2
      assert out["A1"]["stale"] == true
    end

    test "a known-good recompute clears an existing stale flag" do
      out = run(%{"A1" => %{"f" => "1+1", "v" => 99, "stale" => true}})
      assert out["A1"] == %{"f" => "1+1", "v" => 2, "t" => "n"}
    end

    test "dependents read the stale cell's cached value" do
      out =
        run(%{
          "A1" => %{"f" => "NPV(0.1,5)", "v" => 42},
          "B1" => %{"f" => "A1*2"}
        })

      assert out["B1"]["v"] == 84
    end

    test "a stale cell with no cached value reads as blank downstream" do
      out =
        run(%{
          "A1" => %{"f" => "NPV(0.1,5)"},
          "B1" => %{"f" => "A1+1"}
        })

      assert out["B1"]["v"] == 1
      refute Map.has_key?(out["A1"], "v")
    end

    test "an invalid formula is decisive: #REF! lands and stale clears" do
      out = run(%{"A1" => %{"f" => "1+", "v" => 5, "stale" => true}})
      assert out["A1"] == %{"f" => "1+", "v" => "#REF!", "t" => "e"}
    end
  end

  # ── dates ───────────────────────────────────────────────────────────────────

  describe "date arithmetic" do
    @dates %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "A2" => %{"v" => "2026-06-19", "t" => "date"},
      "B1" => %{"v" => "2026-06-12T10:00:00Z", "t" => "datetime"},
      "B2" => %{"v" => "2026-06-13T22:00:00Z", "t" => "datetime"}
    }

    test "date + number advances by days (both operand orders)" do
      assert cell!("A1+7", @dates) == %{"f" => "A1+7", "v" => "2026-06-19", "t" => "date"}
      assert eval!("7+A1", @dates) == "2026-06-19"
    end

    test "date - number goes back by days" do
      assert eval!("A2-7", @dates) == "2026-06-12"
    end

    test "date - date is a number of days" do
      assert eval!("A2-A1", @dates) === 7
      assert eval!("A1-A2", @dates) === -7
    end

    test "datetime + number advances by days, keeping the time" do
      cell = cell!("B1+1", @dates)
      assert cell["v"] == "2026-06-13T10:00:00Z"
      assert cell["t"] == "datetime"
    end

    test "datetime - datetime is days, fractional when inexact" do
      assert eval!("B2-B1", @dates) == 1.5
      assert eval!("B1-B1", @dates) === 0
    end

    test "date + date and date * number are #VALUE!" do
      assert eval!("A1+A2", @dates) == "#VALUE!"
      assert eval!("A1*2", @dates) == "#VALUE!"
    end

    test "dates compare chronologically" do
      assert eval!("A1<A2", @dates) == true
      assert eval!("A1=A1", @dates) == true
      assert eval!("A2<=A1", @dates) == false
    end
  end

  # ── int/float preservation ──────────────────────────────────────────────────

  describe "int/float preservation" do
    test "ints stay ints when exact, else floats" do
      assert eval!("6/3") === 2
      assert eval!("7/2") === 3.5
      assert eval!("2+3") === 5
      assert eval!("2.0+3") === 5.0
      assert eval!("2^10") === 1024
    end

    test "SUM over ints stays an int; a float operand floats the result" do
      assert eval!("SUM(1,2,3)") === 6
      assert eval!("SUM(1,2,0.5)") === 3.5
    end
  end

  # ── blank coercion ──────────────────────────────────────────────────────────

  describe "blank/empty refs" do
    test "coerce to 0 in arithmetic" do
      assert eval!("A9+1") == 1
      assert eval!("-A9") == 0
    end

    test "a bare ref to a blank cell yields 0" do
      assert cell!("A9") == %{"f" => "A9", "v" => 0, "t" => "n"}
    end

    test "coerce to the empty string in concat" do
      assert eval!(~s(A9&"x")) == "x"
    end

    test "comparisons coerce against the other side" do
      assert eval!("A9=0") == true
      assert eval!(~s(A9="")) == true
      assert eval!("A9=FALSE") == true
    end

    test "an empty-string cell reads as blank" do
      assert eval!("A1+1", %{"A1" => %{"v" => ""}}) == 1
    end
  end

  # ── tabs ────────────────────────────────────────────────────────────────────

  describe "multi-tab recompute" do
    test "refs resolve within the cell's own tab only" do
      content = %{
        "tabs" => [
          %{"cells" => %{"A1" => %{"v" => 100}, "B1" => %{"f" => "A1*2"}}},
          %{"cells" => %{"A1" => %{"v" => 5}, "B1" => %{"f" => "A1*2"}}}
        ]
      }

      out = Engine.recompute(content)
      assert get_in(out, ["tabs", Access.at(0), "cells", "B1", "v"]) == 200
      assert get_in(out, ["tabs", Access.at(1), "cells", "B1", "v"]) == 10
    end
  end

  # ── output shape ────────────────────────────────────────────────────────────

  describe "written-back cell shape" do
    test "v and t update; f, fmt and other keys survive" do
      out = run(%{"A1" => %{"f" => "1+1", "v" => 0, "t" => "s", "fmt" => "0.00"}})
      assert out["A1"] == %{"f" => "1+1", "v" => 2, "t" => "n", "fmt" => "0.00"}
    end

    test "result types map to t" do
      assert cell!("1+1")["t"] == "n"
      assert cell!(~s("a"&"b"))["t"] == "s"
      assert cell!("1<2")["t"] == "b"
      assert cell!("1/0")["t"] == "e"
    end
  end

  # ── lookup ──────────────────────────────────────────────────────────────────

  describe "VLOOKUP" do
    # A1:B3 = fruit → price lookup table.
    defp fruit_table do
      %{
        "A1" => %{"v" => "apple"},
        "B1" => %{"v" => 10},
        "A2" => %{"v" => "banana"},
        "B2" => %{"v" => 20},
        "A3" => %{"v" => "cherry"},
        "B3" => %{"v" => 30}
      }
    end

    test "exact hit returns the paired column (text, case-insensitive)" do
      assert eval!(~s{VLOOKUP("BANANA",A1:B3,2,FALSE)}, fruit_table()) == 20
    end

    test "a miss is #N/A" do
      assert eval!(~s{VLOOKUP("kiwi",A1:B3,2,FALSE)}, fruit_table()) == "#N/A"
    end

    test "column index 0 is #VALUE!" do
      assert eval!(~s{VLOOKUP("apple",A1:B3,0,FALSE)}, fruit_table()) == "#VALUE!"
    end

    test "column index past the table width is #REF!" do
      assert eval!(~s{VLOOKUP("apple",A1:B3,3,FALSE)}, fruit_table()) == "#REF!"
    end

    test "a scalar 2nd arg is #VALUE!" do
      assert eval!(~s{VLOOKUP("apple",5,2,FALSE)}, fruit_table()) == "#VALUE!"
    end

    test "approximate (omitted 4th arg) on sorted numbers returns the lower neighbour" do
      cells = %{
        "A1" => %{"v" => 10},
        "B1" => %{"v" => "ten"},
        "A2" => %{"v" => 20},
        "B2" => %{"v" => "twenty"},
        "A3" => %{"v" => 30},
        "B3" => %{"v" => "thirty"}
      }

      # 25 falls between 20 and 30 → the 20 row.
      assert eval!("VLOOKUP(25,A1:B3,2)", cells) == "twenty"
      # exact boundary hit.
      assert eval!("VLOOKUP(20,A1:B3,2)", cells) == "twenty"
      # below the first key → #N/A.
      assert eval!("VLOOKUP(5,A1:B3,2)", cells) == "#N/A"
    end

    test "FALSE 4th arg forces exact and skips a near-miss" do
      cells = %{
        "A1" => %{"v" => 10},
        "B1" => %{"v" => "x"},
        "A2" => %{"v" => 30},
        "B2" => %{"v" => "y"}
      }

      assert eval!("VLOOKUP(25,A1:B2,2,FALSE)", cells) == "#N/A"
    end

    test "an error in the lookup value propagates" do
      assert eval!("VLOOKUP(1/0,A1:B3,2,FALSE)", fruit_table()) == "#DIV/0!"
    end

    test "a blank result cell mirrors a plain ref (0)" do
      # A2 present, B2 blank → returns 0 like a bare ref to a blank cell.
      cells = %{"A1" => %{"v" => "a"}, "B1" => %{"v" => 1}, "A2" => %{"v" => "b"}}

      assert cell!(~s{VLOOKUP("b",A1:B2,2,FALSE)}, cells) |> Map.take(["v", "t"]) ==
               %{"v" => 0, "t" => "n"}
    end
  end

  describe "MATCH" do
    test "type 0 exact match returns the 1-based position" do
      cells = %{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}, "A3" => %{"v" => "z"}}
      assert eval!(~s{MATCH("y",A1:A3,0)}, cells) == 2
    end

    test "type 0 wildcard hit" do
      cells = %{"A1" => %{"v" => "banana"}, "A2" => %{"v" => "apple"}, "A3" => %{"v" => "cherry"}}
      assert eval!(~s{MATCH("ap*",A1:A3,0)}, cells) == 2
    end

    test "type 1 sorted-ascending returns the between-values lower position" do
      cells = %{"A1" => %{"v" => 10}, "A2" => %{"v" => 20}, "A3" => %{"v" => 30}}
      assert eval!("MATCH(25,A1:A3,1)", cells) == 2
      # omitted type defaults to 1.
      assert eval!("MATCH(25,A1:A3)", cells) == 2
    end

    test "type -1 descending returns the smallest value >= lookup" do
      cells = %{"A1" => %{"v" => 30}, "A2" => %{"v" => 20}, "A3" => %{"v" => 10}}
      assert eval!("MATCH(15,A1:A3,-1)", cells) == 2
    end

    test "a 2D range is #N/A" do
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "B2" => %{"v" => 4}
      }

      assert eval!("MATCH(3,A1:B2,0)", cells) == "#N/A"
    end

    test "position counts blank gaps (values at A1 and A3)" do
      cells = %{"A1" => %{"v" => "p"}, "A3" => %{"v" => "q"}}
      assert eval!(~s{MATCH("q",A1:A3,0)}, cells) == 3
    end

    test "a horizontal (single-row) range works too" do
      cells = %{"A1" => %{"v" => 1}, "B1" => %{"v" => 2}, "C1" => %{"v" => 3}}
      assert eval!("MATCH(3,A1:C1,0)", cells) == 3
    end

    test "no match is #N/A" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}}
      assert eval!("MATCH(9,A1:A2,0)", cells) == "#N/A"
    end
  end

  describe "INDEX" do
    test "two-arg (row, col) hit on a 2D range" do
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "B2" => %{"v" => 4}
      }

      assert eval!("INDEX(A1:B2,2,2)", cells) == 4
    end

    test "out of bounds is #REF!" do
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "B2" => %{"v" => 4}
      }

      assert eval!("INDEX(A1:B2,3,1)", cells) == "#REF!"
      assert eval!("INDEX(A1:B2,1,3)", cells) == "#REF!"
    end

    test "a zero or negative index is #VALUE!" do
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "B2" => %{"v" => 4}
      }

      assert eval!("INDEX(A1:B2,0,1)", cells) == "#VALUE!"
      assert eval!("INDEX(A1:B2,1,-1)", cells) == "#VALUE!"
    end

    test "one-arg on a single column indexes rows" do
      cells = %{"A1" => %{"v" => 11}, "A2" => %{"v" => 22}, "A3" => %{"v" => 33}}
      assert eval!("INDEX(A1:A3,2)", cells) == 22
    end

    test "one-arg on a single row indexes columns" do
      cells = %{"A1" => %{"v" => 11}, "B1" => %{"v" => 22}, "C1" => %{"v" => 33}}
      assert eval!("INDEX(A1:C1,3)", cells) == 33
    end

    test "one-arg on a 2D range is #VALUE! (array form out of scope)" do
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "B2" => %{"v" => 4}
      }

      assert eval!("INDEX(A1:B2,1)", cells) == "#VALUE!"
    end
  end

  describe "VLOOKUP + MATCH composition" do
    test "MATCH picks the column VLOOKUP returns" do
      cells = %{
        "A1" => %{"v" => "id"},
        "B1" => %{"v" => "name"},
        "C1" => %{"v" => "price"},
        "A2" => %{"v" => "sku1"},
        "B2" => %{"v" => "widget"},
        "C2" => %{"v" => 99}
      }

      assert eval!(~s{VLOOKUP("sku1",A2:C2,MATCH("price",A1:C1,0),FALSE)}, cells) == 99
    end
  end

  describe "lookup recompute integration (topo deps on the range)" do
    test "editing a cell inside the lookup range updates the dependent" do
      base = %{
        "A1" => %{"v" => "apple"},
        "B1" => %{"v" => 10},
        "A2" => %{"v" => "banana"},
        "B2" => %{"v" => 20},
        "Z99" => %{"f" => ~s{VLOOKUP("banana",A1:B2,2,FALSE)}}
      }

      assert run(base)["Z99"]["v"] == 20

      edited = put_in(base, ["B2", "v"], 25)
      assert run(edited)["Z99"]["v"] == 25
    end
  end

  describe "dynamic arrays: UNIQUE" do
    setup do
      %{
        cells: %{
          "A1" => %{"v" => 2},
          "A2" => %{"v" => 2},
          "A3" => %{"v" => 5},
          "A4" => %{"v" => 5}
        }
      }
    end

    test "composes inside SUM (distinct values only)", %{cells: cells} do
      assert eval!("SUM(UNIQUE(A1:A4))", cells) == 7
    end

    test "composes inside COUNTA (count of distinct)", %{cells: cells} do
      assert eval!("COUNTA(UNIQUE(A1:A4))", cells) == 2
    end

    test "top-level implicit intersection takes the top-left", %{cells: cells} do
      assert eval!("UNIQUE(A1:A4)", cells) == 2
    end

    test "preserves first-occurrence order via TEXTJOIN" do
      cells = %{
        "A1" => %{"v" => "c"},
        "A2" => %{"v" => "a"},
        "A3" => %{"v" => "c"},
        "A4" => %{"v" => "b"}
      }

      assert eval!(~s{TEXTJOIN(",",1,UNIQUE(A1:A4))}, cells) == "c,a,b"
    end

    test "an error in the source propagates through the aggregate" do
      cells = %{"A1" => %{"v" => 4}, "A2" => %{"f" => "1/0"}, "A3" => %{"v" => 6}}
      assert eval!("SUM(UNIQUE(A1:A3))", cells) == "#DIV/0!"
    end
  end

  describe "dynamic arrays: SORT" do
    setup do
      %{cells: %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}}}
    end

    test "ascending by default", %{cells: cells} do
      assert eval!(~s{TEXTJOIN(",",1,SORT(A1:A3))}, cells) == "1,2,3"
    end

    test "descending with order -1", %{cells: cells} do
      assert eval!(~s{TEXTJOIN(",",1,SORT(A1:A3,-1))}, cells) == "3,2,1"
    end

    test "numbers sort before text" do
      cells = %{"A1" => %{"v" => "z"}, "A2" => %{"v" => 5}, "A3" => %{"v" => "a"}}
      assert eval!(~s{TEXTJOIN(",",1,SORT(A1:A3))}, cells) == "5,a,z"
    end
  end

  describe "dynamic arrays: FILTER" do
    test "keeps values whose aligned condition is truthy (boolean range)" do
      cells = %{
        "A1" => %{"v" => 10},
        "A2" => %{"v" => 20},
        "A3" => %{"v" => 30},
        "B1" => %{"v" => true},
        "B2" => %{"v" => false},
        "B3" => %{"v" => true}
      }

      assert eval!("SUM(FILTER(A1:A3,B1:B3))", cells) == 40
      assert eval!("COUNTA(FILTER(A1:A3,B1:B3))", cells) == 2
    end

    test "numeric condition: nonzero is truthy" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => 3},
        "B1" => %{"v" => 0},
        "B2" => %{"v" => 1},
        "B3" => %{"v" => 0}
      }

      assert eval!("SUM(FILTER(A1:A3,B1:B3))", cells) == 2
    end

    test "over a data range containing a blank keeps alignment" do
      # A2 is blank; the include column marks A1 and A3.
      cells = %{
        "A1" => %{"v" => 100},
        "A3" => %{"v" => 300},
        "B1" => %{"v" => true},
        "B2" => %{"v" => true},
        "B3" => %{"v" => false}
      }

      # Bounding box is rows 1..3; A2 reads blank → dropped by the aggregate.
      assert eval!("SUM(FILTER(A1:A3,B1:B3))", cells) == 100
    end

    test "shape mismatch is #VALUE!" do
      cells = %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => 3},
        "B1" => %{"v" => true},
        "B2" => %{"v" => true}
      }

      assert eval!("SUM(FILTER(A1:A3,B1:B2))", cells) == "#VALUE!"
    end
  end

  describe "dynamic arrays: SEQUENCE" do
    test "single arg generates 1..n" do
      assert eval!("SUM(SEQUENCE(4))") == 10
    end

    test "start and step" do
      # 2, 4, 6 → 12
      assert eval!("SUM(SEQUENCE(3,1,2,2))") == 12
    end

    test "rows*cols fills row-major" do
      assert eval!("SUM(SEQUENCE(2,3))") == 21
    end

    test "non-positive dimension is #VALUE!" do
      assert eval!("SEQUENCE(0)") == "#VALUE!"
    end

    test "top-level intersection yields the first element" do
      assert eval!("SEQUENCE(3,1,5,10)") == 5
    end
  end

  describe "dynamic arrays: COUNTUNIQUE" do
    test "counts distinct non-blank values" do
      cells = %{
        "A1" => %{"v" => 5},
        "A2" => %{"v" => 5},
        "A3" => %{"v" => 8},
        "A4" => %{"v" => 8}
      }

      assert eval!("COUNTUNIQUE(A1:A4)", cells) == 2
    end

    test "spans multiple arguments and a nested array" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}, "A3" => %{"v" => 2}}
      assert eval!("COUNTUNIQUE(UNIQUE(A1:A3),3)", cells) == 3
    end
  end

  describe "dynamic arrays: dependency graph is unchanged" do
    test "a cell downstream of SUM(UNIQUE(range)) recomputes when a source cell changes" do
      base = %{
        "A1" => %{"v" => 2},
        "A2" => %{"v" => 2},
        "A3" => %{"v" => 5},
        "B1" => %{"f" => "SUM(UNIQUE(A1:A3))"}
      }

      assert run(base)["B1"]["v"] == 7

      edited = put_in(base, ["A2", "v"], 9)
      # A2 is no longer a duplicate of A1 → the unique set grows → recompute.
      assert run(edited)["B1"]["v"] == 16
    end
  end

  # ── dynamic-array SPILL (wave 3) ────────────────────────────────────────────

  describe "array literals" do
    test "={1;2;3} is a column (; = row separator)" do
      out = run(%{"A1" => %{"f" => "={1;2;3}"}})
      assert [out["A1"]["v"], out["A2"]["v"], out["A3"]["v"]] == [1, 2, 3]
    end

    test "={1,2,3} is a row (, = column separator)" do
      out = run(%{"A1" => %{"f" => "={1,2,3}"}})
      assert [out["A1"]["v"], out["B1"]["v"], out["C1"]["v"]] == [1, 2, 3]
    end

    test "={1,2;3,4} is a grid" do
      out = run(%{"A1" => %{"f" => "={1,2;3,4}"}})
      assert [out["A1"]["v"], out["B1"]["v"], out["A2"]["v"], out["B2"]["v"]] == [1, 2, 3, 4]
    end

    test "a ragged literal is #VALUE!" do
      assert eval!("={1,2;3}") == "#VALUE!"
    end

    test "composes inside SUM as a column and a row" do
      assert eval!("=SUM({1;2;3;4})") == 10
      assert eval!("=SUM({1,2,3})") == 6
    end

    test "elements may be expressions (unary minus, refs)" do
      cells = %{"C1" => %{"v" => 11}, "C2" => %{"v" => 22}, "A1" => %{"f" => "={C1;C2;-3}"}}
      out = run(cells)
      assert [out["A1"]["v"], out["A2"]["v"], out["A3"]["v"]] == [11, 22, -3]
    end

    test "an empty literal ={} is #REF! (outside the grammar)" do
      assert eval!("={}") == "#REF!"
    end
  end

  describe "spill distribution" do
    test "=SORT(range) spills in sorted order" do
      cells = %{
        "C1" => %{"v" => 3},
        "C2" => %{"v" => 1},
        "C3" => %{"v" => 2},
        "A1" => %{"f" => "=SORT(C1:C3)"}
      }

      out = run(cells)
      assert [out["A1"]["v"], out["A2"]["v"], out["A3"]["v"]] == [1, 2, 3]
    end

    test "a 2x3 SEQUENCE spills into a rectangle with matching dims" do
      out = run(%{"A1" => %{"f" => "=SEQUENCE(2,3)"}})

      assert [out["A1"]["v"], out["B1"]["v"], out["C1"]["v"]] == [1, 2, 3]
      assert [out["A2"]["v"], out["B2"]["v"], out["C2"]["v"]] == [4, 5, 6]
      assert out["A1"]["spill_dims"] == [2, 3]
    end

    test "the anchor's own v is the array's top-left" do
      # This is why the pre-spill `UNIQUE(A1:A4) == 2` intersection tests still
      # hold: the anchor keeps top-left; the rest spills into neighbours.
      cells = %{"A1" => %{"v" => 7}, "A2" => %{"v" => 7}, "A3" => %{"v" => 9}}
      out = run(Map.put(cells, "B1", %{"f" => "=UNIQUE(A1:A3)"}))
      assert out["B1"]["v"] == 7
      assert out["B2"]["v"] == 9
    end

    test "MARKER CONTRACT — anchor: f + spill(self) + spill_dims; non-anchor: v + t + spill(anchor), no f, no style" do
      out = run(%{"A1" => %{"f" => "={7;8}", "s" => %{"b" => true}}})

      # Anchor keeps its formula and user style, gains the two spill markers.
      assert out["A1"] == %{
               "f" => "={7;8}",
               "s" => %{"b" => true},
               "v" => 7,
               "t" => "n",
               "spill" => "A1",
               "spill_dims" => [2, 1]
             }

      # Non-anchor spilled cell is pure engine output — exactly v + t + spill.
      assert out["A2"] == %{"v" => 8, "t" => "n", "spill" => "A1"}
      refute Map.has_key?(out["A2"], "f")
      refute Map.has_key?(out["A2"], "s")
    end
  end

  describe "spill collision (#SPILL!)" do
    test "a value obstructing the region blocks the WHOLE spill; nothing else is written" do
      out = run(%{"A1" => %{"f" => "={1;2;3}"}, "A2" => %{"v" => 99}})

      assert out["A1"] == %{"f" => "={1;2;3}", "v" => "#SPILL!", "t" => "e"}
      # nothing else written: the obstruction is untouched, no other cell created.
      assert out["A2"] == %{"v" => 99}
      refute Map.has_key?(out, "A3")
    end

    test "a formula in the region also blocks" do
      out = run(%{"A1" => %{"f" => "={1;2;3}"}, "A3" => %{"f" => "=5"}})
      assert out["A1"]["v"] == "#SPILL!"
      assert out["A3"]["v"] == 5
      refute Map.has_key?(out, "A2")
    end

    test "a spill that would fall off the grid edge is #SPILL!" do
      # A row of two anchored at the last column would need column XFE.
      out = run(%{"XFD1" => %{"f" => "={1,2}"}})
      assert out["XFD1"]["v"] == "#SPILL!"
    end

    test "#SPILL! is in the engine error vocabulary" do
      assert "#SPILL!" in Engine.error_values()
    end

    test "two anchors racing for one empty cell resolve row-major first-wins" do
      # B1 spills DOWN into B1:B2; A2 spills RIGHT into A2:C2. The regions cross
      # at the (empty) B2. Anchors distribute in a stable {row, col} order, so
      # B1 (row 1) claims B2 first and A2 (row 2) then blocks — deterministically,
      # independent of the cells map's iteration order (design §3.3 first-wins).
      out = run(%{"B1" => %{"f" => "={1;2}"}, "A2" => %{"f" => "={7,8,9}"}})

      assert [out["B1"]["v"], out["B2"]["v"]] == [1, 2]
      assert out["B2"]["spill"] == "B1"
      assert out["A2"]["v"] == "#SPILL!"
      refute Map.has_key?(out, "C2")
    end
  end

  describe "spill invalidation" do
    test "shrinking the array vacates cells outside the new region" do
      once = run(%{"A1" => %{"f" => "={1;2;3}"}})
      assert once["A3"]["v"] == 3

      twice = run(Map.put(once, "A1", %{"f" => "={1;2}"}))
      assert [twice["A1"]["v"], twice["A2"]["v"]] == [1, 2]
      refute Map.has_key?(twice, "A3")
    end

    test "re-spilling overwrites the anchor's OWN prior region (no self-collision)" do
      once = run(%{"A1" => %{"f" => "={1;2;3}"}})
      twice = run(Map.put(once, "A1", %{"f" => "={4;5;6}"}))
      assert [twice["A1"]["v"], twice["A2"]["v"], twice["A3"]["v"]] == [4, 5, 6]
    end

    test "deleting the anchor clears the whole spill region" do
      once = run(%{"A1" => %{"f" => "={1;2;3}"}})
      cleared = run(Map.delete(once, "A1"))
      assert cleared == %{}
    end

    test "editing the anchor to a scalar clears the region and drops the markers" do
      once = run(%{"A1" => %{"f" => "={1;2;3}"}})
      scalar = run(Map.put(once, "A1", %{"f" => "=42"}))
      assert scalar["A1"] == %{"f" => "=42", "v" => 42, "t" => "n"}
      refute Map.has_key?(scalar, "A2")
      refute Map.has_key?(scalar, "A3")
    end

    test "typing into a spilled cell blocks on the next recompute and vacates the region" do
      once = run(%{"A1" => %{"f" => "={1;2;3}"}})
      # The user types 99 into the spilled A2 (session strips the marker).
      typed = once |> Map.put("A2", %{"v" => 99})
      out = run(typed)
      assert out["A1"]["v"] == "#SPILL!"
      assert out["A2"] == %{"v" => 99}
      refute Map.has_key?(out, "A3")
    end
  end

  describe "spill readers (two-phase recompute)" do
    test "=A2 reads a spilled value" do
      out = run(%{"A1" => %{"f" => "={10;20;30}"}, "B1" => %{"f" => "=A2"}})
      assert out["B1"]["v"] == 20
    end

    test "a range over the anchor plus its spill reads each cell exactly once" do
      out = run(%{"A1" => %{"f" => "={1;2;3}"}, "B1" => %{"f" => "=SUM(A1:A3)"}})
      assert out["B1"]["v"] == 6
    end

    test "reading a blocked anchor propagates #SPILL!" do
      out = run(%{"A1" => %{"f" => "={1;2;3}"}, "A2" => %{"v" => 9}, "B1" => %{"f" => "=A1"}})
      assert out["B1"]["v"] == "#SPILL!"
    end

    test "a zero-array document is untouched by the spill machinery" do
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => 3}, "A3" => %{"f" => "=SUM(A1:A2)"}}
      assert run(cells)["A3"] == %{"f" => "=SUM(A1:A2)", "t" => "n", "v" => 5}
    end

    test "depth-2 chained spill converges — a spill whose SOURCE is itself spilled" do
      # E1 reads C1:C3, C1 reads A1:A3, A1 is a literal array. Spill visibility
      # propagates one level per recompute phase, so a single extra phase (the
      # pre-fixpoint engine) leaves E reading a stale, not-yet-spilled C. The
      # N-phase fixpoint (charter D3) must re-topo until the spill map is stable,
      # so E finally reads the materialised C region.
      #   A1:A3 = [2,3,1]  →  C1:C3 = SORT(asc) = [1,2,3]  →  E1:E3 = SORT(desc) = [3,2,1]
      out =
        run(%{
          "A1" => %{"f" => "={2;3;1}"},
          "C1" => %{"f" => "=SORT(A1:A3)"},
          "E1" => %{"f" => "=SORT(C1:C3, -1)"}
        })

      assert [out["A1"]["v"], out["A2"]["v"], out["A3"]["v"]] == [2, 3, 1]
      assert [out["C1"]["v"], out["C2"]["v"], out["C3"]["v"]] == [1, 2, 3]
      assert [out["E1"]["v"], out["E2"]["v"], out["E3"]["v"]] == [3, 2, 1]
    end

    test "depth-3 chained spill still converges within the phase cap" do
      # A → C → E → G, three spill hops. Each SORT preserves order for an already
      # ascending source, so the whole chain settles on [1,2,3]. Proves the
      # fixpoint drives more than the single depth-2 hop and terminates well
      # inside the hard cap.
      out =
        run(%{
          "A1" => %{"f" => "={1;2;3}"},
          "C1" => %{"f" => "=SORT(A1:A3)"},
          "E1" => %{"f" => "=SORT(C1:C3)"},
          "G1" => %{"f" => "=SORT(E1:E3)"}
        })

      assert [out["C1"]["v"], out["C2"]["v"], out["C3"]["v"]] == [1, 2, 3]
      assert [out["E1"]["v"], out["E2"]["v"], out["E3"]["v"]] == [1, 2, 3]
      assert [out["G1"]["v"], out["G2"]["v"], out["G3"]["v"]] == [1, 2, 3]
    end

    test "REGRESSION LOCK — a scalar/bounded doc recomputes byte-identically, no spill markers" do
      # The wave's critical regression lock (charter): a document with NO
      # top-level array result produces the exact same cells map the pre-spill
      # engine did — literals pass through untouched, formulas get v/t only, and
      # NO cell anywhere gains a "spill"/"spill_dims" key or takes the two-phase
      # path. Byte-identity is asserted as full-map equality, not a single cell.
      # `SUM(UNIQUE(...))` keeps an array present but strictly NESTED (it
      # scalarizes/aggregates, never reaches the top level), so the doc still has
      # zero spillable results and must stay on the single-pass path.
      cells = %{
        "A1" => %{"v" => 2},
        "A2" => %{"v" => 3},
        "A3" => %{"v" => 2},
        "B1" => %{"f" => "=SUM(A1:A3)"},
        "B2" => %{"f" => "=A1*2"},
        "B3" => %{"f" => "=SUM(UNIQUE(A1:A3))"}
      }

      out = run(cells)

      assert out == %{
               "A1" => %{"v" => 2},
               "A2" => %{"v" => 3},
               "A3" => %{"v" => 2},
               "B1" => %{"f" => "=SUM(A1:A3)", "v" => 7, "t" => "n"},
               "B2" => %{"f" => "=A1*2", "v" => 4, "t" => "n"},
               "B3" => %{"f" => "=SUM(UNIQUE(A1:A3))", "v" => 5, "t" => "n"}
             }

      refute Enum.any?(out, fn {_a, c} -> is_map(c) and Map.has_key?(c, "spill") end)
    end
  end

  describe "spill in a cross-tab document" do
    test "a spill inside a cross-tab document still distributes" do
      content = %{
        "tabs" => [
          %{
            "name" => "Sheet1",
            "cells" => %{
              "A1" => %{"f" => "={1;2;3}"},
              "B1" => %{"f" => "=Sheet2!A1"}
            }
          },
          %{"name" => "Sheet2", "cells" => %{"A1" => %{"v" => 100}}}
        ]
      }

      s1 =
        content
        |> Engine.recompute()
        |> get_in(["tabs", Access.at(0), "cells"])

      assert [s1["A1"]["v"], s1["A2"]["v"], s1["A3"]["v"]] == [1, 2, 3]
      assert s1["A2"]["spill"] == "A1"
      # the cross-tab read still resolves (unified path taken).
      assert s1["B1"]["v"] == 100
    end

    test "a cross-tab reader sees a spilled value in the other tab" do
      content = %{
        "tabs" => [
          %{"name" => "Sheet1", "cells" => %{"A1" => %{"f" => "={10;20;30}"}}},
          %{"name" => "Sheet2", "cells" => %{"A1" => %{"f" => "=Sheet1!A2"}}}
        ]
      }

      s2 =
        content
        |> Engine.recompute()
        |> get_in(["tabs", Access.at(1), "cells"])

      assert s2["A1"]["v"] == 20
    end

    test "cross-tab depth-2 chained spill converges through the unified path" do
      # The unified twin of the fast-path depth-2 test: the spill chain crosses
      # tabs, so it MUST ride recompute_unified. Sheet1!A1 spills, Sheet2!C1 sorts
      # Sheet1's spilled region, Sheet1!E1 sorts Sheet2's spilled region — two
      # spill hops across the tab boundary. The unified fixpoint must re-topo
      # until every tab's spill map is stable, or E reads a stale C.
      content = %{
        "tabs" => [
          %{
            "name" => "Sheet1",
            "cells" => %{
              "A1" => %{"f" => "={2;3;1}"},
              "E1" => %{"f" => "=SORT(Sheet2!C1:C3, -1)"}
            }
          },
          %{
            "name" => "Sheet2",
            "cells" => %{"C1" => %{"f" => "=SORT(Sheet1!A1:A3)"}}
          }
        ]
      }

      out = Engine.recompute(content)
      s1 = get_in(out, ["tabs", Access.at(0), "cells"])
      s2 = get_in(out, ["tabs", Access.at(1), "cells"])

      assert [s1["A1"]["v"], s1["A2"]["v"], s1["A3"]["v"]] == [2, 3, 1]
      assert [s2["C1"]["v"], s2["C2"]["v"], s2["C3"]["v"]] == [1, 2, 3]
      assert [s1["E1"]["v"], s1["E2"]["v"], s1["E3"]["v"]] == [3, 2, 1]
    end
  end

  describe "RAND / RANDBETWEEN (volatile-as-of-last-save)" do
    test "RAND returns a float in [0, 1)" do
      for _ <- 1..50 do
        v = eval!("=RAND()")
        assert is_float(v) and v >= 0.0 and v < 1.0
      end
    end

    test "RANDBETWEEN returns an inclusive integer within [lo, hi]" do
      for _ <- 1..50 do
        v = eval!("=RANDBETWEEN(5, 8)")
        assert is_integer(v) and v >= 5 and v <= 8
      end
    end

    test "RANDBETWEEN with a single-point range is that integer" do
      assert eval!("=RANDBETWEEN(7, 7)") == 7
    end

    test "RANDBETWEEN spans a negative range inclusively" do
      for _ <- 1..50 do
        v = eval!("=RANDBETWEEN(-2, 2)")
        assert is_integer(v) and v >= -2 and v <= 2
      end
    end

    test "RANDBETWEEN with lo > hi is #NUM!" do
      assert eval!("=RANDBETWEEN(9, 1)") == "#NUM!"
    end

    test "RANDBETWEEN truncates non-integer bounds toward zero before drawing" do
      for _ <- 1..50 do
        # trunc(1.9)=1, trunc(3.9)=3 -> inclusive [1, 3]
        v = eval!("=RANDBETWEEN(1.9, 3.9)")
        assert v in [1, 2, 3]
      end
    end

    test "RANDBETWEEN with a non-numeric bound is #VALUE!" do
      assert eval!("=RANDBETWEEN(\"x\", 5)") == "#VALUE!"
      assert eval!("=RANDBETWEEN(1, \"y\")") == "#VALUE!"
    end

    test "RANDBETWEEN propagates an error bound (e.g. #DIV/0!) through" do
      assert eval!("=RANDBETWEEN(1/0, 5)") == "#DIV/0!"
    end

    test "wrong arity is #VALUE! (fallthrough), for both RAND and RANDBETWEEN" do
      assert eval!("=RAND(1)") == "#VALUE!"
      assert eval!("=RANDBETWEEN(1)") == "#VALUE!"
      assert eval!("=RANDBETWEEN(1, 2, 3)") == "#VALUE!"
    end

    test "within a save, a spill-present doc persists RAND consistently with what dependents consumed" do
      # An unrelated SEQUENCE spill forces the two-phase recompute path
      # (`any_array_result?` true): the RAND anchor A1 is re-evaluated in EVERY
      # phase, so a stateful draw would drift between phases. The pure per-cell
      # derivation lands the identical value each phase, so the dependent B1
      # (=A1) and C1 (=A1*2) persist exactly the drawn value.
      cells = %{
        "A1" => %{"f" => "=RAND()"},
        "B1" => %{"f" => "=A1"},
        "C1" => %{"f" => "=A1 * 2"},
        "E1" => %{"f" => "=SEQUENCE(3)"}
      }

      out = run(cells)

      # the spill actually materialised — the two-phase path was taken.
      assert out["E1"]["spill_dims"] == [3, 1]
      assert out["E3"]["v"] == 3

      draw = out["A1"]["v"]
      assert is_float(draw) and draw >= 0.0 and draw < 1.0
      assert out["B1"]["v"] == draw
      assert out["C1"]["v"] == draw * 2
    end

    test "RAND is volatile across saves — two recomputes draw different values" do
      cells = %{"A1" => %{"f" => "=RAND()"}}
      refute run(cells)["A1"]["v"] == run(cells)["A1"]["v"]
    end

    test "distinct cells draw independently within one save (pure per {seed, tab, col, row})" do
      out =
        run(%{
          "A1" => %{"f" => "=RAND()"},
          "A2" => %{"f" => "=RAND()"},
          "B1" => %{"f" => "=RAND()"}
        })

      vals = [out["A1"]["v"], out["A2"]["v"], out["B1"]["v"]]
      assert length(Enum.uniq(vals)) == 3
    end

    test "the draw never mutates process-global :rand state (functional seed_s/uniform_s only)" do
      # Naive `:rand.uniform/0` would read+advance the process dictionary seed;
      # the pure per-cell `:rand.uniform_s(:rand.seed_s(...))` never touches it.
      :rand.seed(:exsss, {1, 2, 3})
      before = :rand.export_seed()
      _ = run(%{"A1" => %{"f" => "=RAND()"}, "B1" => %{"f" => "=RANDBETWEEN(1, 100)"}})
      assert :rand.export_seed() == before
    end

    test "RAND recomputes under the cross-tab unified path and a cross-tab reader sees the persisted draw" do
      content = %{
        "tabs" => [
          %{
            "name" => "Sheet1",
            "cells" => %{"A1" => %{"f" => "=RAND()"}, "B1" => %{"f" => "=Sheet2!A1"}}
          },
          %{"name" => "Sheet2", "cells" => %{"A1" => %{"f" => "=RANDBETWEEN(1, 6)"}}}
        ]
      }

      out = Engine.recompute(content)
      s1 = get_in(out, ["tabs", Access.at(0), "cells"])
      s2 = get_in(out, ["tabs", Access.at(1), "cells"])

      assert is_float(s1["A1"]["v"]) and s1["A1"]["v"] >= 0.0 and s1["A1"]["v"] < 1.0
      assert s2["A1"]["v"] in 1..6
      # the cross-tab reader consumed exactly what S2!A1 persisted.
      assert s1["B1"]["v"] == s2["A1"]["v"]
    end
  end

  describe "robustness: overflow/hang guards + unicode (wave-12 confirmed crashes)" do
    test "power overflow resolves to #NUM! instead of crashing recompute (the =99^200/7 Session crash)" do
      assert eval!("99^200/7") == "#NUM!"
      assert eval!("ROUND(9^400, -1)") == "#NUM!"
      assert eval!("AVERAGE(9^400, 2)") == "#NUM!"
      assert eval!("STDEV(9^400, 1)") == "#NUM!"
      assert eval!("ROUND(9.9*10^307, 10)") == "#NUM!"
    end

    test "a formula that used to wedge the scheduler resolves fast to #NUM!" do
      # If the guard regressed this would hang for >8s; ExUnit's per-test
      # timeout would fire. The assertion completing IS the proof.
      assert eval!("9^1024^1024") == "#NUM!"
    end

    test "a huge date offset resolves to #NUM! instead of hanging Date.add for minutes" do
      assert eval!("DATE(2020,1,1) + 10^15") == "#NUM!"
      assert eval!("DATE(2020,1,1) - 10^15") == "#NUM!"
    end

    test "in-range integer powers and dates still compute" do
      assert eval!("2^10") == 1024
      assert eval!("10^15") == 1_000_000_000_000_000
      assert eval!("YEAR(DATE(2020,1,1) + 366)") == 2021
    end

    test "wildcard matching is unicode-correct (SEARCH/criteria on non-ASCII)" do
      assert eval!(~s|SEARCH("?x","øx")|) == 1
      assert eval!(~s|SEARCH("?本","日本")|) == 1
    end

    test "MODE treats an integer and its float twin as the same value" do
      assert eval!("MODE(1, 0.5+0.5, 2)") == 1
      assert eval!("MODE(2, 4/2)") == 2
    end
  end

  # ── coverage batch 1: math / date-time / logic-info / reference ─────────────

  describe "MOD" do
    test "result takes the divisor's sign (Excel semantics)" do
      assert eval!("MOD(7,3)") === 1
      assert eval!("MOD(-7,3)") === 2
      assert eval!("MOD(7,-3)") === -2
      assert eval!("MOD(-7,-3)") === -1
    end

    test "float operands, divisor-sign rule included" do
      assert eval!("MOD(7.5,2)") == 1.5
      assert eval!("MOD(-7.5,2)") == 0.5
    end

    test "MOD by zero is #DIV/0!" do
      assert eval!("MOD(5,0)") == "#DIV/0!"
      assert eval!("MOD(5,0.0)") == "#DIV/0!"
    end

    test "text is #VALUE!, an error propagates, wrong arity is #VALUE!" do
      assert eval!(~s|MOD("a",2)|) == "#VALUE!"
      assert eval!("MOD(1/0,2)") == "#DIV/0!"
      assert eval!("MOD(5)") == "#VALUE!"
    end

    test "bignum: integer pair stays exact; a float divisor degrades to #NUM!" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("MOD(A1,7)", big) === rem(Integer.pow(10, 400), 7)
      assert eval!("MOD(A1,2.5)", big) == "#NUM!"
    end
  end

  describe "POWER" do
    test "routes through the ^ power logic" do
      assert eval!("POWER(2,10)") === 1024
      assert eval!("POWER(2,-1)") == 0.5
      assert eval!("POWER(9,0.5)") == 3.0
    end

    test "domain errors mirror ^" do
      assert eval!("POWER(0,-1)") == "#DIV/0!"
      assert eval!("POWER(-8,0.5)") == "#NUM!"
    end

    test "overflow control: 2^1023 computes, 10^400 is #NUM! (no raise)" do
      assert eval!("POWER(2,1023)") === Integer.pow(2, 1023)
      assert eval!("POWER(10,400)") == "#NUM!"
    end

    test "errors and text propagate" do
      assert eval!("POWER(1/0,2)") == "#DIV/0!"
      assert eval!(~s|POWER("a",2)|) == "#VALUE!"
    end
  end

  describe "SQRT" do
    test "square roots, blank coerces to 0" do
      assert eval!("SQRT(9)") == 3.0
      assert eval!("SQRT(2.25)") == 1.5
      assert eval!("SQRT(A9)") == 0.0
    end

    test "negative is #NUM!" do
      assert eval!("SQRT(-1)") == "#NUM!"
    end

    test "a bignum arg degrades to #NUM! instead of raising" do
      assert eval!("SQRT(A1)", %{"A1" => %{"v" => Integer.pow(10, 400)}}) == "#NUM!"
    end
  end

  describe "PRODUCT" do
    test "multiplies scalars and range numbers; text in a range is skipped" do
      assert eval!("PRODUCT(2,3,4)") === 24
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => "x"}, "A3" => %{"v" => 5}}
      assert eval!("PRODUCT(A1:A3)", cells) === 10
    end

    test "no numeric input is 0 (Excel)" do
      assert eval!("PRODUCT(B7:B8)") == 0
    end

    test "a direct text scalar is #VALUE!; an error propagates" do
      assert eval!(~s|PRODUCT("a")|) == "#VALUE!"
      assert eval!("PRODUCT(1/0,2)") == "#DIV/0!"
    end

    test "bignum products degrade to #NUM!, not a crash" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      # Pure-int product canonicalises at the output boundary…
      assert eval!("PRODUCT(A1,2)", big) == "#NUM!"
      # …and a float sibling overflows mid-fold under safe_arith.
      assert eval!("PRODUCT(A1,2.0)", big) == "#NUM!"
    end
  end

  describe "SIGN" do
    test "classifies into -1/0/1" do
      assert eval!("SIGN(-5)") === -1
      assert eval!("SIGN(0)") === 0
      assert eval!("SIGN(3.2)") === 1
      assert eval!("SIGN(A9)") === 0
    end

    test "text is #VALUE!" do
      assert eval!(~s|SIGN("a")|) == "#VALUE!"
    end
  end

  describe "CEILING / FLOOR" do
    test "round to a multiple of the significance (default 1)" do
      assert eval!("CEILING(2.5)") == 3
      assert eval!("FLOOR(2.5)") == 2
      assert eval!("CEILING(7,2)") === 8
      assert eval!("FLOOR(7,2)") === 6
      assert eval!("CEILING(0.3,0.1)") != nil
    end

    test "negative x follows Excel's sign rules" do
      assert eval!("CEILING(-2.5,2)") == -2
      assert eval!("CEILING(-2.5,-2)") == -4
      assert eval!("FLOOR(-2.5,2)") == -4
      assert eval!("FLOOR(-2.5,-2)") == -2
    end

    test "positive x with negative significance is #NUM!" do
      assert eval!("CEILING(2.5,-2)") == "#NUM!"
      assert eval!("FLOOR(2.5,-2)") == "#NUM!"
    end

    test "the zero-significance asymmetry: CEILING is 0, FLOOR is #DIV/0!" do
      assert eval!("CEILING(5,0)") == 0
      assert eval!("FLOOR(5,0)") == "#DIV/0!"
    end

    test "bignum float mixes degrade to #NUM!" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("CEILING(A1,2.5)", big) == "#NUM!"
      assert eval!("FLOOR(A1,2.5)", big) == "#NUM!"
    end
  end

  describe "TRUNC" do
    test "truncates toward zero, honouring the digit count" do
      assert eval!("TRUNC(8.9)") === 8
      assert eval!("TRUNC(-8.9)") === -8
      assert eval!("TRUNC(3.14159,2)") == 3.14
      assert eval!("TRUNC(555,-2)") === 500
    end

    test "text is #VALUE!" do
      assert eval!(~s|TRUNC("a")|) == "#VALUE!"
    end
  end

  describe "LN / LOG / EXP" do
    test "LN is the natural log; the domain floor is #NUM!" do
      assert eval!("LN(1)") == 0.0
      assert_in_delta eval!("LN(EXP(2))"), 2.0, 1.0e-12
      assert eval!("LN(0)") == "#NUM!"
      assert eval!("LN(-5)") == "#NUM!"
    end

    test "LOG defaults to base 10 and takes an explicit base" do
      assert eval!("LOG(100)") == 2.0
      assert_in_delta eval!("LOG(8,2)"), 3.0, 1.0e-12
    end

    test "LOG domain errors: x<=0 or base<=0 is #NUM!, base 1 is #DIV/0!" do
      assert eval!("LOG(0)") == "#NUM!"
      assert eval!("LOG(-10)") == "#NUM!"
      assert eval!("LOG(8,0)") == "#NUM!"
      assert eval!("LOG(8,-2)") == "#NUM!"
      assert eval!("LOG(8,1)") == "#DIV/0!"
    end

    test "EXP computes and its overflow degrades to #NUM!, not a raise" do
      assert eval!("EXP(0)") == 1.0
      assert_in_delta eval!("EXP(1)"), 2.718281828459045, 1.0e-12
      assert eval!("EXP(1000)") == "#NUM!"
      assert eval!("EXP(A1)", %{"A1" => %{"v" => Integer.pow(10, 400)}}) == "#NUM!"
    end
  end

  describe "HOUR / MINUTE / SECOND" do
    @dt %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "B1" => %{"v" => "2026-06-12T10:30:45Z", "t" => "datetime"}
    }

    test "read the time component of a datetime" do
      assert eval!("HOUR(B1)", @dt) == 10
      assert eval!("MINUTE(B1)", @dt) == 30
      assert eval!("SECOND(B1)", @dt) == 45
    end

    test "a pure date reads midnight" do
      assert eval!("HOUR(A1)", @dt) == 0
      assert eval!("MINUTE(A1)", @dt) == 0
      assert eval!("SECOND(A1)", @dt) == 0
    end

    test "NOW() feeds them; non-dates are #VALUE!; errors propagate" do
      assert eval!("HOUR(NOW())") in 0..23
      # Batch 2 (TIME): a NUMBER now reads as an Excel time serial — the
      # integer part is whole days, so HOUR(5) is 0, no longer #VALUE!.
      assert eval!("HOUR(5)") == 0
      assert eval!(~s|MINUTE("x")|) == "#VALUE!"
      assert eval!("SECOND(1/0)") == "#DIV/0!"
    end
  end

  describe "WEEKDAY" do
    @wd %{
      # 2026-06-12 is a Friday; 2026-06-14 a Sunday.
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "A2" => %{"v" => "2026-06-14", "t" => "date"}
    }

    test "type 1 (default): Sun=1..Sat=7" do
      assert eval!("WEEKDAY(A1)", @wd) == 6
      assert eval!("WEEKDAY(A2)", @wd) == 1
      assert eval!("WEEKDAY(A1,1)", @wd) == 6
    end

    test "type 2: Mon=1..Sun=7; type 3: Mon=0..Sun=6" do
      assert eval!("WEEKDAY(A1,2)", @wd) == 5
      assert eval!("WEEKDAY(A2,2)", @wd) == 7
      assert eval!("WEEKDAY(A1,3)", @wd) == 4
      assert eval!("WEEKDAY(A2,3)", @wd) == 6
    end

    test "an unsupported type is #NUM!; a non-date is #VALUE!" do
      assert eval!("WEEKDAY(A1,5)", @wd) == "#NUM!"
      assert eval!("WEEKDAY(5)") == "#VALUE!"
    end

    test "a datetime works too" do
      cells = %{"B1" => %{"v" => "2026-06-12T10:00:00Z", "t" => "datetime"}}
      assert eval!("WEEKDAY(B1)", cells) == 6
    end
  end

  describe "EDATE / EOMONTH" do
    @ed %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "A2" => %{"v" => "2026-01-31", "t" => "date"},
      "B1" => %{"v" => "2026-06-12T10:00:00Z", "t" => "datetime"}
    }

    test "EDATE shifts by months, clamping into shorter months" do
      assert cell!("EDATE(A1,1)", @ed) |> Map.take(["v", "t"]) ==
               %{"v" => "2026-07-12", "t" => "date"}

      assert eval!("EDATE(A1,-6)", @ed) == "2025-12-12"
      assert eval!("EDATE(A2,1)", @ed) == "2026-02-28"
      assert eval!("EDATE(A2,13)", @ed) == "2027-02-28"
    end

    test "EOMONTH lands on the target month's last day" do
      assert eval!("EOMONTH(A1,0)", @ed) == "2026-06-30"
      assert eval!("EOMONTH(A1,1)", @ed) == "2026-07-31"
      assert eval!("EOMONTH(A2,1)", @ed) == "2026-02-28"
      assert eval!("EOMONTH(A1,-4)", @ed) == "2026-02-28"
    end

    test "a datetime input yields a plain date" do
      assert cell!("EDATE(B1,1)", @ed) |> Map.take(["v", "t"]) ==
               %{"v" => "2026-07-12", "t" => "date"}
    end

    test "shifting outside year 0001..9999 is #NUM!, a bignum offset included" do
      assert eval!("EDATE(A1,120000)", @ed) == "#NUM!"
      assert eval!("EOMONTH(A1,-30000)", @ed) == "#NUM!"
      big = Map.put(@ed, "C1", %{"v" => Integer.pow(10, 400)})
      assert eval!("EDATE(A1,C1)", big) == "#NUM!"
    end

    test "non-dates are #VALUE!; errors propagate" do
      assert eval!("EDATE(5,1)") == "#VALUE!"
      assert eval!("EOMONTH(A1,1/0)", @ed) == "#DIV/0!"
    end
  end

  describe "XOR" do
    test "TRUE when an odd number of values are truthy" do
      assert eval!("XOR(TRUE,FALSE)") == true
      assert eval!("XOR(TRUE,TRUE)") == false
      assert eval!("XOR(1,1,1)") == true
      assert eval!("XOR(0,0)") == false
    end

    test "ranges flatten with the AND/OR coercion rules" do
      cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 0}, "A3" => %{"v" => "txt"}}
      assert eval!("XOR(A1:A3)", cells) == true
    end

    test "no coercible values is #VALUE!; errors propagate" do
      assert eval!(~s|XOR("a")|) == "#VALUE!"
      assert eval!("XOR(1/0,TRUE)") == "#DIV/0!"
    end
  end

  describe "IFNA" do
    test "catches only #N/A" do
      assert eval!(~s|IFNA(NA(),"fallback")|) == "fallback"
      assert eval!(~s|IFNA(MATCH(9,A1:A2,0),"miss")|, %{"A1" => %{"v" => 1}}) == "miss"
    end

    test "other errors propagate and plain values pass through" do
      assert eval!(~s|IFNA(1/0,"x")|) == "#DIV/0!"
      assert eval!(~s|IFNA(5,"x")|) == 5
    end
  end

  describe "COUNTBLANK" do
    test "counts never-written and empty-string cells" do
      cells = %{"A1" => %{"v" => 1}, "A3" => %{"v" => ""}}
      assert eval!("COUNTBLANK(A1:A5)", cells) == 4
    end

    test "errors and falsy values are NOT blank" do
      cells = %{"A1" => %{"f" => "1/0"}, "A2" => %{"v" => 0}, "A3" => %{"v" => false}}
      assert eval!("COUNTBLANK(A1:A3)", cells) == 0
    end

    test "a non-range argument is #VALUE!" do
      assert eval!("COUNTBLANK(5)") == "#VALUE!"
    end
  end

  describe "ISEVEN / ISODD" do
    test "truncate toward zero first (Excel)" do
      assert eval!("ISEVEN(2)") == true
      assert eval!("ISEVEN(3)") == false
      assert eval!("ISEVEN(2.5)") == true
      assert eval!("ISODD(3)") == true
      assert eval!("ISODD(-3)") == true
      assert eval!("ISODD(2)") == false
      assert eval!("ISEVEN(A9)") == true
    end

    test "text is #VALUE! and errors propagate (unlike the IS* classifiers)" do
      assert eval!(~s|ISEVEN("x")|) == "#VALUE!"
      assert eval!("ISODD(1/0)") == "#DIV/0!"
    end

    test "a bignum integer still classifies exactly" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("ISEVEN(A1)", big) == true
      assert eval!("ISODD(A1)", big) == false
    end
  end

  describe "ROW / COLUMN / ROWS / COLUMNS" do
    test "ROWS/COLUMNS read a range's dimensions" do
      assert eval!("ROWS(A1:A5)") == 5
      assert eval!("ROWS(B2)") == 1
      assert eval!("COLUMNS(A1:C2)") == 3
      assert eval!("COLUMNS(B2:B9)") == 1
    end

    test "ROW/COLUMN with a ref answer its coordinates; a range answers top-left" do
      assert eval!("ROW(B7)") == 7
      assert eval!("COLUMN(B7)") == 2
      assert eval!("ROW(A3:A9)") == 3
      assert eval!("COLUMN(C1:E1)") == 3
    end

    test "no-arg forms answer for the formula's own cell (Z99)" do
      assert eval!("ROW()") == 99
      assert eval!("COLUMN()") == 26
    end

    test "a non-ref argument is #VALUE!" do
      assert eval!("ROWS(5)") == "#VALUE!"
      assert eval!(~s|COLUMN("B7")|) == "#VALUE!"
    end

    test "compose: dimensions feed arithmetic" do
      assert eval!("ROWS(A1:A5)*COLUMNS(A1:C5)") == 15
    end
  end

  describe "coverage batch 1 is in function_names/0" do
    test "every new name is surfaced, sorted, unique" do
      names = Engine.function_names()

      for n <- ~w(MOD POWER SQRT PRODUCT SIGN CEILING FLOOR TRUNC LN LOG EXP
                  HOUR MINUTE SECOND WEEKDAY EDATE EOMONTH
                  XOR IFNA COUNTBLANK ISEVEN ISODD ROW COLUMN ROWS COLUMNS) do
        assert n in names, "#{n} missing from function_names/0"
      end

      assert names == Enum.sort(names)
      assert Enum.uniq(names) == names
    end
  end

  # ── coverage batch 2 ────────────────────────────────────────────────────────

  describe "TEXT" do
    @text_dates %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "B1" => %{"v" => "2026-06-12T10:30:45Z", "t" => "datetime"}
    }

    test "number patterns map onto the fmt vocabulary" do
      # THE positive control of the batch.
      assert eval!(~s|TEXT(1234.5,"0.00")|) == "1234.50"
      assert eval!(~s|TEXT(0.25,"0%")|) == "25.00%"
      assert eval!(~s|TEXT(1234.5,"$#,##0.00")|) == "$1,234.50"
      assert eval!(~s|TEXT(1234567,"#,##0")|) == "1,234,567"
      assert eval!(~s|TEXT(-1234.5,"$#,##0.00")|) == "-$1,234.50"
    end

    test "the result is a plain string cell" do
      cell = cell!(~s|TEXT(1234.5,"0.00")|)
      assert cell["v"] == "1234.50"
      assert cell["t"] == "s"
    end

    test "date patterns render the class's canonical ISO form" do
      assert eval!(~s|TEXT(A1,"yyyy-mm-dd")|, @text_dates) == "2026-06-12"
      # A non-ISO layout still classifies as `date` — canonical ISO out.
      assert eval!(~s|TEXT(A1,"dd/mm/yyyy")|, @text_dates) == "2026-06-12"
      assert eval!(~s|TEXT(B1,"yyyy-mm-dd h:mm:ss")|, @text_dates) == "2026-06-12 10:30:45"
      assert eval!(~s|TEXT(DATE(2026,1,5),"yyyy-mm-dd")|) == "2026-01-05"
    end

    test "an unmapped pattern falls back to a general rendering, never crashes" do
      assert eval!(~s|TEXT(5,"@")|) == "5"
      assert eval!(~s|TEXT(5,"General")|) == "5"
      # A non-number under a number pattern renders verbatim/general.
      assert eval!(~s|TEXT("abc","0.00")|) == "abc"
      assert eval!(~s|TEXT(TRUE,"0.00")|) == "TRUE"
    end

    test "blank coerces to 0 under a number pattern" do
      assert eval!(~s|TEXT(Z98,"0.00")|) == "0.00"
    end

    test "errors propagate; wrong arity is #VALUE!" do
      assert eval!(~s|TEXT(1/0,"0.00")|) == "#DIV/0!"
      assert eval!(~s|TEXT(5)|) == "#VALUE!"
    end

    test "bignum/overflow safety: giant int formats, float overflow is #NUM!" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      out = eval!(~s|TEXT(A1,"0.00")|, big)
      assert is_binary(out)
      assert String.ends_with?(out, ".00")
      assert String.length(out) > 400

      huge_float = %{"A1" => %{"v" => 1.0e308}}
      assert eval!(~s|TEXT(A1,"0%")|, huge_float) == "#NUM!"
    end
  end

  describe "CHAR / CODE" do
    test "CHAR maps 1..255 to the codepoint" do
      assert eval!("CHAR(65)") == "A"
      assert eval!("CHAR(97)") == "a"
      assert eval!("CHAR(230)") == "æ"
    end

    test "CHAR outside 1..255 is #VALUE!" do
      assert eval!("CHAR(0)") == "#VALUE!"
      assert eval!("CHAR(256)") == "#VALUE!"
      assert eval!("CHAR(-5)") == "#VALUE!"
    end

    test "CHAR: a bignum arg is #VALUE!, not a crash; errors propagate" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("CHAR(A1)", big) == "#VALUE!"
      assert eval!("CHAR(1/0)") == "#DIV/0!"
    end

    test "CODE reads the first character's codepoint" do
      assert eval!(~s|CODE("A")|) == 65
      assert eval!(~s|CODE("abc")|) == 97
      assert eval!(~s|CODE("æble")|) == 230
      # Numbers coerce through the text rule.
      assert eval!("CODE(5)") == 53
    end

    test "CODE of an empty string is #VALUE!; roundtrip with CHAR" do
      assert eval!(~s|CODE("")|) == "#VALUE!"
      assert eval!("CODE(CHAR(200))") == 200
    end
  end

  describe "DOLLAR / FIXED" do
    test "DOLLAR renders currency, two decimals by default, sign outside $" do
      assert eval!("DOLLAR(1234.567)") == "$1,234.57"
      assert eval!("DOLLAR(-1234.567)") == "-$1,234.57"
      assert eval!("DOLLAR(1234.567,1)") == "$1,234.6"
      assert eval!("DOLLAR(1234.567,-2)") == "$1,200"
    end

    test "FIXED renders a grouped fixed-decimal string" do
      assert eval!("FIXED(1234.567)") == "1,234.57"
      assert eval!("FIXED(1234.567,1)") == "1,234.6"
      assert eval!("FIXED(1234.567,-2)") == "1,200"
      assert eval!("FIXED(0.5,0)") == "1"
    end

    test "FIXED third arg TRUE drops the commas" do
      assert eval!("FIXED(1234.567,1,TRUE)") == "1234.6"
      assert eval!("FIXED(1234.567,1,FALSE)") == "1,234.6"
    end

    test "text is #VALUE!; errors propagate" do
      assert eval!(~s|DOLLAR("a")|) == "#VALUE!"
      assert eval!(~s|FIXED("a")|) == "#VALUE!"
      assert eval!("DOLLAR(1/0)") == "#DIV/0!"
      assert eval!("FIXED(1/0)") == "#DIV/0!"
    end

    test "bignum int formats to a giant string; float overflow is #NUM!" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert is_binary(eval!("DOLLAR(A1)", big))
      huge_float = %{"A1" => %{"v" => 1.0e308}}
      assert eval!("FIXED(A1,2)", huge_float) == "#NUM!"
    end
  end

  describe "HLOOKUP" do
    @hl %{
      "A1" => %{"v" => "apple"},
      "B1" => %{"v" => "banana"},
      "C1" => %{"v" => "cherry"},
      "A2" => %{"v" => 1},
      "B2" => %{"v" => 2},
      "C2" => %{"v" => 3}
    }

    @hl_num %{
      "A1" => %{"v" => 10},
      "B1" => %{"v" => 20},
      "C1" => %{"v" => 30},
      "A2" => %{"v" => "a"},
      "B2" => %{"v" => "b"},
      "C2" => %{"v" => "c"}
    }

    test "exact match scans the FIRST row and answers from row_index" do
      assert eval!(~s|HLOOKUP("banana",A1:C2,2,FALSE)|, @hl) == 2
      assert eval!(~s|HLOOKUP("cherry",A1:C2,1,FALSE)|, @hl) == "cherry"
    end

    test "text matching is case-insensitive" do
      assert eval!(~s|HLOOKUP("BANANA",A1:C2,2,FALSE)|, @hl) == 2
    end

    test "exact miss is #N/A" do
      assert eval!(~s|HLOOKUP("zzz",A1:C2,2,FALSE)|, @hl) == "#N/A"
    end

    test "approximate (default) keeps the last value <= key" do
      assert eval!("HLOOKUP(25,A1:C2,2)", @hl_num) == "b"
      assert eval!("HLOOKUP(30,A1:C2,2)", @hl_num) == "c"
      assert eval!("HLOOKUP(5,A1:C2,2)", @hl_num) == "#N/A"
    end

    test "row_index out of the range is #REF!; below 1 is #VALUE!" do
      assert eval!(~s|HLOOKUP("apple",A1:C2,3,FALSE)|, @hl) == "#REF!"
      assert eval!(~s|HLOOKUP("apple",A1:C2,0,FALSE)|, @hl) == "#VALUE!"
    end

    test "errors in the key propagate; a non-range table is #VALUE!" do
      assert eval!("HLOOKUP(1/0,A1:C2,2)", @hl) == "#DIV/0!"
      assert eval!(~s|HLOOKUP("x",5,2)|) == "#VALUE!"
    end
  end

  describe "MAXIFS / MINIFS" do
    @mx %{
      "A1" => %{"v" => "a"},
      "A2" => %{"v" => "b"},
      "A3" => %{"v" => "a"},
      "A4" => %{"v" => "b"},
      "B1" => %{"v" => 10},
      "B2" => %{"v" => 20},
      "B3" => %{"v" => 30},
      "B4" => %{"v" => 40}
    }

    test "single criterion" do
      assert eval!(~s|MAXIFS(B1:B4,A1:A4,"a")|, @mx) == 30
      assert eval!(~s|MINIFS(B1:B4,A1:A4,"a")|, @mx) == 10
    end

    test "multiple criteria AND-combine" do
      assert eval!(~s|MAXIFS(B1:B4,A1:A4,"b",B1:B4,"<30")|, @mx) == 20
      assert eval!(~s|MINIFS(B1:B4,A1:A4,"b",B1:B4,">20")|, @mx) == 40
    end

    test "no match is 0 (Excel)" do
      assert eval!(~s|MAXIFS(B1:B4,A1:A4,"z")|, @mx) == 0
      assert eval!(~s|MINIFS(B1:B4,A1:A4,"z")|, @mx) == 0
    end

    test "shape mismatch and missing criteria are #VALUE!" do
      assert eval!(~s|MAXIFS(B1:B3,A1:A4,"a")|, @mx) == "#VALUE!"
      assert eval!("MAXIFS(B1:B4,A1:A4)", @mx) == "#VALUE!"
    end

    test "an error in a matched target cell propagates" do
      cells = Map.put(@mx, "B3", %{"f" => "1/0"})
      assert eval!(~s|MAXIFS(B1:B4,A1:A4,"a")|, cells) == "#DIV/0!"
    end
  end

  # ── dates in the criteria mini-language + *IFS aggregation ──────────────────
  #
  # Dates ARE numbers in Excel's criteria world. A date-typed cell must match
  # ">"&DATE(…) (the concat idiom renders ISO) and hand-typed ">2024-06-01";
  # SUMIF/MAXIFS/… over date target ranges must aggregate, never silent-zero.

  describe "criteria dates — the mini-language + *IFS over temporals" do
    @dates %{
      "A1" => %{"v" => "2024-05-01", "t" => "date"},
      "A2" => %{"v" => "2024-06-15", "t" => "date"},
      "A3" => %{"v" => "2024-07-01", "t" => "date"}
    }

    @flagged %{
      "A1" => %{"v" => "x"},
      "A2" => %{"v" => "y"},
      "A3" => %{"v" => "x"},
      "B1" => %{"v" => "2024-05-01", "t" => "date"},
      "B2" => %{"v" => "2024-06-15", "t" => "date"},
      "B3" => %{"v" => "2024-07-01", "t" => "date"}
    }

    # The engine's day-serial epoch (Excel's day 0).
    @serial_epoch ~D[1899-12-30]

    test ~s|COUNTIF with the ">"&DATE(…) concat idiom counts date cells| do
      assert eval!(~s|COUNTIF(A1:A3,">"&DATE(2024,6,1))|, @dates) == 2
    end

    test "COUNTIF with hand-typed ISO comparator criteria" do
      assert eval!(~s|COUNTIF(A1:A3,">2024-06-01")|, @dates) == 2
      assert eval!(~s|COUNTIF(A1:A3,"<=2024-06-15")|, @dates) == 2
      assert eval!(~s|COUNTIF(A1:A3,"2024-06-15")|, @dates) == 1
      assert eval!(~s|COUNTIF(A1:A3,"<>2024-06-15")|, @dates) == 2
    end

    test "COUNTIFS: a two-sided date window" do
      assert eval!(
               ~s|COUNTIFS(A1:A3,">=2024-06-01",A1:A3,"<2024-07-01")|,
               @dates
             ) == 1
    end

    test "datetime cells compare against a date criterion (serial alignment)" do
      cells = %{"A1" => %{"v" => "2024-06-01T12:00:00", "t" => "datetime"}}
      assert eval!(~s|COUNTIF(A1:A1,">2024-06-01")|, cells) == 1
      assert eval!(~s|COUNTIF(A1:A1,"<2024-06-01")|, cells) == 0
    end

    test "MAXIFS/MINIFS over a date target range return the extreme date" do
      max_cell = cell!(~s|MAXIFS(B1:B3,A1:A3,"x")|, @flagged)
      assert max_cell["v"] == "2024-07-01"
      assert max_cell["t"] == "date"
      assert eval!(~s|MINIFS(B1:B3,A1:A3,"x")|, @flagged) == "2024-05-01"
    end

    test "MAXIFS over a mixed number+date target compares via the day serial" do
      cells = Map.put(@flagged, "B3", %{"v" => 10})
      # x-flagged targets: ~D[2024-05-01] (serial 45413) and 10 → the date wins.
      assert eval!(~s|MAXIFS(B1:B3,A1:A3,"x")|, cells) == "2024-05-01"
      assert eval!(~s|MINIFS(B1:B3,A1:A3,"x")|, cells) == 10
    end

    test "SUMIF/AVERAGEIF over a date sum-range sum day serials, not 0" do
      expected =
        Date.diff(~D[2024-05-01], @serial_epoch) + Date.diff(~D[2024-07-01], @serial_epoch)

      assert eval!(~s|SUMIF(A1:A3,"x",B1:B3)|, @flagged) == expected
      assert eval!(~s|AVERAGEIF(A1:A3,"x",B1:B3)|, @flagged) == expected / 2
    end

    test "SUMIFS over a date sum-range sums day serials" do
      expected =
        Date.diff(~D[2024-05-01], @serial_epoch) + Date.diff(~D[2024-07-01], @serial_epoch)

      assert eval!(~s|SUMIFS(B1:B3,A1:A3,"x")|, @flagged) == expected
    end

    test "guards: numeric strictness, text wildcards and blank rules unchanged" do
      nums = %{"A1" => %{"v" => 3}, "A2" => %{"v" => 7}, "A3" => %{"v" => "seven"}}
      assert eval!(~s|COUNTIF(A1:A3,">5")|, nums) == 1

      texts = %{"A1" => %{"v" => "2024-06-01"}, "A2" => %{"v" => "apple"}}
      assert eval!(~s|COUNTIF(A1:A2,"2024*")|, texts) == 1
      assert eval!(~s|COUNTIF(A1:A2,"apple*")|, texts) == 1

      # A criteria string that is neither number nor ISO date keeps text
      # semantics against date cells: no match.
      assert eval!(~s|COUNTIF(A1:A3,"apple*")|, @dates) == 0

      # Blank-matching paths unchanged (A1:B3 rect, 3 occupied, 3 unoccupied).
      sparse = %{"A1" => %{"v" => 5}, "A2" => %{"v" => ""}, "B1" => %{"v" => 3}}
      assert eval!(~s|COUNTIF(A1:B3,"")|, sparse) == 4
      assert eval!(~s|COUNTIF(A1:B3,"<>")|, sparse) == 2
    end
  end

  describe "SUMSQ" do
    test "sum of squares; range text is skipped" do
      assert eval!("SUMSQ(3,4)") == 25
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => "x"}, "A3" => %{"v" => 3}}
      assert eval!("SUMSQ(A1:A3)", cells) == 13
    end

    test "empty input is 0; direct text is #VALUE!; errors propagate" do
      assert eval!("SUMSQ(B7:B8)") == 0
      assert eval!(~s|SUMSQ("a")|) == "#VALUE!"
      assert eval!("SUMSQ(1/0)") == "#DIV/0!"
    end

    test "bignum squares degrade to #NUM!, never a raise" do
      # Pure-int square canonicalises at the output boundary…
      assert eval!("SUMSQ(A1)", %{"A1" => %{"v" => Integer.pow(10, 400)}}) == "#NUM!"
      # …and a float square overflows mid-fold under safe_arith.
      assert eval!("SUMSQ(A1)", %{"A1" => %{"v" => 1.0e200}}) == "#NUM!"
    end
  end

  describe "GCD / LCM" do
    test "integer gcd/lcm across scalars and ranges" do
      assert eval!("GCD(12,18)") == 6
      assert eval!("GCD(5)") == 5
      assert eval!("GCD(0,0)") == 0
      assert eval!("LCM(4,6)") == 12
      assert eval!("LCM(0,5)") == 0
      cells = %{"A1" => %{"v" => 8}, "A2" => %{"v" => 12}, "A3" => %{"v" => 20}}
      assert eval!("GCD(A1:A3)", cells) == 4
      assert eval!("LCM(A1:A3)", cells) == 120
    end

    test "non-integers truncate (Excel)" do
      assert eval!("GCD(12.9,18)") == 6
    end

    test "a negative argument is #NUM!" do
      assert eval!("GCD(-4,6)") == "#NUM!"
      assert eval!("LCM(4,-6)") == "#NUM!"
    end

    test "text is #VALUE!; errors propagate" do
      assert eval!(~s|GCD("a",2)|) == "#VALUE!"
      assert eval!("LCM(1/0,2)") == "#DIV/0!"
    end

    test "bignum-safe: exact gcd on a bignum, lcm overflow is #NUM!" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("GCD(A1,7)", big) == 1
      assert eval!("LCM(A1,3)", big) == "#NUM!"
    end
  end

  describe "DATEDIF" do
    @dd %{
      "A1" => %{"v" => "2026-01-15", "t" => "date"},
      "A2" => %{"v" => "2026-03-14", "t" => "date"},
      "B1" => %{"v" => "2024-06-10", "t" => "date"},
      "B2" => %{"v" => "2026-06-10", "t" => "date"}
    }

    test "the six units" do
      assert eval!(~s|DATEDIF(A1,A2,"D")|, @dd) == 58
      assert eval!(~s|DATEDIF(A1,A2,"M")|, @dd) == 1
      assert eval!(~s|DATEDIF(A1,A2,"Y")|, @dd) == 0
      assert eval!(~s|DATEDIF(A1,A2,"YM")|, @dd) == 1
      assert eval!(~s|DATEDIF(A1,A2,"MD")|, @dd) == 27
      assert eval!(~s|DATEDIF(A1,A2,"YD")|, @dd) == 58
    end

    test "whole years" do
      assert eval!(~s|DATEDIF(B1,B2,"Y")|, @dd) == 2
      assert eval!(~s|DATEDIF(B1,B2,"M")|, @dd) == 24
      assert eval!(~s|DATEDIF(B1,B2,"D")|, @dd) == 730
    end

    test "month-end clamp: Jan 31 to Feb 28 is 0 full months" do
      cells = %{
        "A1" => %{"v" => "2026-01-31", "t" => "date"},
        "A2" => %{"v" => "2026-02-28", "t" => "date"}
      }

      assert eval!(~s|DATEDIF(A1,A2,"M")|, cells) == 0
      assert eval!(~s|DATEDIF(A1,A2,"MD")|, cells) == 28
    end

    test "the unit is case-insensitive" do
      assert eval!(~s|DATEDIF(A1,A2,"d")|, @dd) == 58
      assert eval!(~s|DATEDIF(A1,A2,"ym")|, @dd) == 1
    end

    test "an invalid unit is #NUM!; start after end is #NUM!" do
      assert eval!(~s|DATEDIF(A1,A2,"X")|, @dd) == "#NUM!"
      assert eval!(~s|DATEDIF(A2,A1,"D")|, @dd) == "#NUM!"
    end

    test "non-dates are #VALUE!; errors propagate" do
      assert eval!(~s|DATEDIF(5,A2,"D")|, @dd) == "#VALUE!"
      assert eval!(~s|DATEDIF(A1,1/0,"D")|, @dd) == "#DIV/0!"
    end
  end

  describe "WEEKNUM" do
    @wn %{
      # 2026-01-01 is a Thursday; 2026-01-04 a Sunday; 2026-01-05 a Monday.
      "A1" => %{"v" => "2026-01-01", "t" => "date"},
      "A2" => %{"v" => "2026-01-04", "t" => "date"},
      "A3" => %{"v" => "2026-01-05", "t" => "date"},
      # 2027-01-01 is a Friday — ISO week 53 of 2026.
      "B1" => %{"v" => "2027-01-01", "t" => "date"}
    }

    test "type 1 (default): weeks start Sunday, week 1 contains Jan 1" do
      assert eval!("WEEKNUM(A1)", @wn) == 1
      assert eval!("WEEKNUM(A2)", @wn) == 2
      assert eval!("WEEKNUM(A3,1)", @wn) == 2
    end

    test "type 2: weeks start Monday" do
      assert eval!("WEEKNUM(A1,2)", @wn) == 1
      assert eval!("WEEKNUM(A2,2)", @wn) == 1
      assert eval!("WEEKNUM(A3,2)", @wn) == 2
    end

    test "type 21 is the ISO week number" do
      assert eval!("WEEKNUM(A1,21)", @wn) == 1
      assert eval!("WEEKNUM(B1,21)", @wn) == 53
    end

    test "an unsupported type is #NUM!; a non-date is #VALUE!" do
      assert eval!("WEEKNUM(A1,5)", @wn) == "#NUM!"
      assert eval!("WEEKNUM(7)") == "#VALUE!"
    end
  end

  describe "TIME + time-serial HOUR/MINUTE/SECOND" do
    test "TIME builds the Excel fractional-day serial" do
      assert eval!("TIME(12,0,0)") == 0.5
      assert eval!("TIME(10,30,0)") == 0.4375
      assert eval!("TIME(0,0,0)") == 0
      # Hours roll over past 24.
      assert eval!("TIME(27,0,0)") == 0.125
      assert eval!("TIME(24,0,0)") == 0
    end

    test "HOUR/MINUTE/SECOND read the serial back" do
      assert eval!("HOUR(TIME(10,30,45))") == 10
      assert eval!("MINUTE(TIME(10,30,45))") == 30
      assert eval!("SECOND(TIME(10,30,45))") == 45
      assert eval!("HOUR(0.75)") == 18
    end

    test "a negative total or serial is #NUM!" do
      assert eval!("TIME(-1,0,0)") == "#NUM!"
      assert eval!("HOUR(-0.5)") == "#NUM!"
    end

    test "bignum: the fractional part of a huge int is 0, no crash" do
      big = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("HOUR(A1)", big) == 0
    end

    test "text is #VALUE!; errors propagate" do
      assert eval!(~s|TIME("a",0,0)|) == "#VALUE!"
      assert eval!("TIME(1/0,0,0)") == "#DIV/0!"
    end
  end

  describe "DAYS" do
    @dy %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "A2" => %{"v" => "2026-06-15", "t" => "date"}
    }

    test "end minus start, in days, sign included" do
      assert eval!("DAYS(A2,A1)", @dy) == 3
      assert eval!("DAYS(A1,A2)", @dy) == -3
      assert eval!("DAYS(A1,A1)", @dy) == 0
    end

    test "non-dates are #VALUE!; errors propagate" do
      assert eval!("DAYS(5,A1)", @dy) == "#VALUE!"
      assert eval!("DAYS(A2,1/0)", @dy) == "#DIV/0!"
    end
  end

  describe "NETWORKDAYS" do
    @nw %{
      # 2026-06-08 Mon … 2026-06-12 Fri … 2026-06-13 Sat, 06-14 Sun, 06-15 Mon.
      "A1" => %{"v" => "2026-06-08", "t" => "date"},
      "A2" => %{"v" => "2026-06-12", "t" => "date"},
      "A3" => %{"v" => "2026-06-14", "t" => "date"},
      "A4" => %{"v" => "2026-06-15", "t" => "date"},
      "A5" => %{"v" => "2026-06-13", "t" => "date"}
    }

    test "counts weekdays over the closed interval" do
      assert eval!("NETWORKDAYS(A1,A2)", @nw) == 5
      assert eval!("NETWORKDAYS(A1,A3)", @nw) == 5
      assert eval!("NETWORKDAYS(A2,A4)", @nw) == 2
      assert eval!("NETWORKDAYS(A2,A2)", @nw) == 1
      # A weekend-only interval counts nothing.
      assert eval!("NETWORKDAYS(A5,A5)", @nw) == 0
    end

    test "start after end counts negatively" do
      assert eval!("NETWORKDAYS(A2,A1)", @nw) == -5
    end

    test "a full year, closed-form (2026 has 261 weekdays)" do
      assert eval!("NETWORKDAYS(DATE(2026,1,1),DATE(2026,12,31))") == 261
    end

    test "holidays subtract once, weekday-only, deduped" do
      cells =
        Map.merge(@nw, %{
          "H1" => %{"v" => "2026-06-10", "t" => "date"},
          "H2" => %{"v" => "2026-06-10", "t" => "date"},
          "H3" => %{"v" => "2026-06-13", "t" => "date"}
        })

      assert eval!("NETWORKDAYS(A1,A2,H1:H3)", cells) == 4
    end

    test "a non-range holidays arg is #VALUE!; an error holiday propagates" do
      assert eval!("NETWORKDAYS(A1,A2,5)", @nw) == "#VALUE!"
      cells = Map.put(@nw, "H1", %{"f" => "1/0"})
      assert eval!("NETWORKDAYS(A1,A2,H1)", cells) == "#DIV/0!"
    end

    test "non-dates are #VALUE!" do
      assert eval!("NETWORKDAYS(5,A2)", @nw) == "#VALUE!"
    end
  end

  describe "WORKDAY" do
    @wk %{
      "A1" => %{"v" => "2026-06-12", "t" => "date"},
      "A2" => %{"v" => "2026-06-08", "t" => "date"},
      "A3" => %{"v" => "2026-06-15", "t" => "date"}
    }

    test "steps over weekends" do
      assert cell!("WORKDAY(A1,1)", @wk) |> Map.take(["v", "t"]) ==
               %{"v" => "2026-06-15", "t" => "date"}

      assert eval!("WORKDAY(A2,5)", @wk) == "2026-06-15"
      assert eval!("WORKDAY(A1,0)", @wk) == "2026-06-12"
    end

    test "negative days walk backwards" do
      assert eval!("WORKDAY(A3,-1)", @wk) == "2026-06-12"
    end

    test "holidays are skipped" do
      cells = Map.put(@wk, "H1", %{"v" => "2026-06-15", "t" => "date"})
      assert eval!("WORKDAY(A1,1,H1)", cells) == "2026-06-16"
    end

    test "a huge or bignum day count is #NUM!, not a hang" do
      assert eval!("WORKDAY(A1,200000)", @wk) == "#NUM!"
      cells = Map.put(@wk, "C1", %{"v" => Integer.pow(10, 400)})
      assert eval!("WORKDAY(A1,C1)", cells) == "#NUM!"
    end

    test "non-dates are #VALUE!; errors propagate" do
      assert eval!("WORKDAY(5,1)") == "#VALUE!"
      assert eval!("WORKDAY(A1,1/0)", @wk) == "#DIV/0!"
    end
  end

  describe "coverage batch 2 is in function_names/0" do
    test "every new name is surfaced; the list stays sorted and unique" do
      names = Engine.function_names()

      for n <- ~w(TEXT CHAR CODE DOLLAR FIXED HLOOKUP MAXIFS MINIFS
                  SUMSQ GCD LCM DATEDIF WEEKNUM TIME DAYS WORKDAY NETWORKDAYS) do
        assert n in names, "#{n} missing from function_names/0"
      end

      assert names == Enum.sort(names)
      assert Enum.uniq(names) == names
    end

    test "a stale TEXT import flips to live" do
      out =
        run(%{"A1" => %{"f" => ~s|TEXT(1234.5,"0.00")|, "v" => 99, "t" => "n", "stale" => true}})

      assert out["A1"] == %{"f" => ~s|TEXT(1234.5,"0.00")|, "v" => "1234.50", "t" => "s"}
    end
  end

  # ── coverage batch 3 (reference/array tier) ─────────────────────────────────

  describe "XLOOKUP" do
    @xl %{
      "A1" => %{"v" => "apple"},
      "A2" => %{"v" => "banana"},
      "A3" => %{"v" => "cherry"},
      "B1" => %{"v" => 10},
      "B2" => %{"v" => 20},
      "B3" => %{"v" => 30},
      # deliberately UNSORTED numbers for the -1/1 nearest-neighbour modes
      "N1" => %{"v" => 40},
      "N2" => %{"v" => 10},
      "N3" => %{"v" => 25},
      "P1" => %{"v" => "forty"},
      "P2" => %{"v" => "ten"},
      "P3" => %{"v" => "twentyfive"}
    }

    test "exact match (default mode), text case-insensitive" do
      assert eval!(~s|XLOOKUP("banana",A1:A3,B1:B3)|, @xl) == 20
      assert eval!(~s|XLOOKUP("BANANA",A1:A3,B1:B3)|, @xl) == 20
      assert eval!("XLOOKUP(25,N1:N3,P1:P3)", @xl) == "twentyfive"
    end

    test "the answer is a scalar — arithmetic consumes it directly" do
      assert eval!(~s|XLOOKUP("banana",A1:A3,B1:B3)*2|, @xl) == 40
    end

    test "a miss is #N/A; if_not_found answers instead, lazily" do
      assert eval!(~s|XLOOKUP("kiwi",A1:A3,B1:B3)|, @xl) == "#N/A"
      assert eval!(~s|XLOOKUP("kiwi",A1:A3,B1:B3,"none")|, @xl) == "none"
      # lazy: the fallback AST only evaluates on a miss
      assert eval!(~s|XLOOKUP("banana",A1:A3,B1:B3,1/0)|, @xl) == 20
      assert eval!(~s|XLOOKUP("kiwi",A1:A3,B1:B3,1/0)|, @xl) == "#DIV/0!"
    end

    test "modes -1/1 pick nearest neighbours on UNSORTED data" do
      assert eval!(~s|XLOOKUP(30,N1:N3,P1:P3,"x",-1)|, @xl) == "twentyfive"
      assert eval!(~s|XLOOKUP(30,N1:N3,P1:P3,"x",1)|, @xl) == "forty"
      # an exact hit wins in both directional modes
      assert eval!(~s|XLOOKUP(25,N1:N3,P1:P3,"x",-1)|, @xl) == "twentyfive"
      assert eval!(~s|XLOOKUP(10,N1:N3,P1:P3,"x",1)|, @xl) == "ten"
      # no smaller / no larger neighbour → the fallback
      assert eval!(~s|XLOOKUP(5,N1:N3,P1:P3,"x",-1)|, @xl) == "x"
      assert eval!(~s|XLOOKUP(50,N1:N3,P1:P3,"x",1)|, @xl) == "x"
    end

    test "mode 2 wildcards; mode 0 takes * literally" do
      assert eval!(~s|XLOOKUP("b*",A1:A3,B1:B3,"x",2)|, @xl) == 20
      assert eval!(~s|XLOOKUP("cherr?",A1:A3,B1:B3,"x",2)|, @xl) == 30
      assert eval!(~s|XLOOKUP("b*",A1:A3,B1:B3,"x",0)|, @xl) == "x"
    end

    test "row vectors work; mixed orientations map by position" do
      cells = %{
        "A1" => %{"v" => "a"},
        "B1" => %{"v" => "b"},
        "C1" => %{"v" => "c"},
        "A2" => %{"v" => 1},
        "B2" => %{"v" => 2},
        "C2" => %{"v" => 3},
        "E1" => %{"v" => 7},
        "E2" => %{"v" => 8},
        "E3" => %{"v" => 9}
      }

      assert eval!(~s|XLOOKUP("b",A1:C1,A2:C2)|, cells) == 2
      # row lookup vector, column return vector — same length, offset-mapped
      assert eval!(~s|XLOOKUP("b",A1:C1,E1:E3)|, cells) == 8
    end

    test "blank lookup cells are skipped; a blank return cell reads 0" do
      cells = %{"A1" => %{"v" => "k"}, "A3" => %{"v" => "k2"}}
      assert eval!(~s|XLOOKUP("k2",A1:A3,B1:B3)|, cells) == 0
      assert eval!(~s|XLOOKUP("k",A1:A3,B1:B3)|, cells) == 0
    end

    test "shape errors are #VALUE!" do
      # 2D lookup range
      assert eval!(~s|XLOOKUP("apple",A1:B2,B1:B3)|, @xl) == "#VALUE!"
      # 2D return range
      assert eval!(~s|XLOOKUP("apple",A1:A3,A1:B2)|, @xl) == "#VALUE!"
      # length mismatch
      assert eval!(~s|XLOOKUP("apple",A1:A3,B1:B2)|, @xl) == "#VALUE!"
      # non-range args
      assert eval!(~s|XLOOKUP("apple",5,B1:B3)|, @xl) == "#VALUE!"
      assert eval!(~s|XLOOKUP("apple",A1:A3,5)|, @xl) == "#VALUE!"
    end

    test "a bad match mode is #VALUE!; wrong arity is #VALUE!" do
      assert eval!(~s|XLOOKUP("apple",A1:A3,B1:B3,"x",3)|, @xl) == "#VALUE!"
      assert eval!(~s|XLOOKUP("apple",A1:A3,B1:B3,"x","m")|, @xl) == "#VALUE!"
      assert eval!(~s|XLOOKUP("apple",A1:A3)|, @xl) == "#VALUE!"
    end

    test "errors propagate: the key, the mode, an error in the return cell" do
      assert eval!("XLOOKUP(1/0,A1:A3,B1:B3)", @xl) == "#DIV/0!"
      assert eval!(~s|XLOOKUP("apple",A1:A3,B1:B3,"x",1/0)|, @xl) == "#DIV/0!"
      cells = Map.put(@xl, "B1", %{"f" => "1/0"})
      assert eval!(~s|XLOOKUP("apple",A1:A3,B1:B3)|, cells) == "#DIV/0!"
    end

    test "bignum: a huge returned int canonicalises to #NUM!, no crash" do
      cells = %{"A1" => %{"v" => "k"}, "B1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!(~s|XLOOKUP("k",A1:A1,B1:B1)|, cells) == "#NUM!"
    end
  end

  describe "SUMPRODUCT" do
    @sp %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3},
      "B1" => %{"v" => 4},
      "B2" => %{"v" => 5},
      "B3" => %{"v" => 6},
      "C1" => %{"v" => 1},
      "C2" => %{"v" => 0},
      "C3" => %{"v" => 2}
    }

    test "multiplies aligned cells and sums" do
      assert eval!("SUMPRODUCT(A1:A3,B1:B3)", @sp) == 32
      assert eval!("SUMPRODUCT(A1:A3,B1:B3,C1:C3)", @sp) == 40
    end

    test "a single range sums its numbers" do
      assert eval!("SUMPRODUCT(A1:A3)", @sp) == 6
    end

    test "2D ranges of identical shape align cell-by-cell" do
      # (1,4;2,5) · (2,1;0,3) → 2 + 4 + 0 + 15 = 21
      cells = %{
        "A1" => %{"v" => 1},
        "B1" => %{"v" => 4},
        "A2" => %{"v" => 2},
        "B2" => %{"v" => 5},
        "D1" => %{"v" => 2},
        "E1" => %{"v" => 1},
        "D2" => %{"v" => 0},
        "E2" => %{"v" => 3}
      }

      assert eval!("SUMPRODUCT(A1:B2,D1:E2)", cells) == 21
    end

    test "text, booleans and blanks count as 0" do
      cells = %{
        "A1" => %{"v" => "x"},
        "A2" => %{"v" => true},
        "A3" => %{"v" => 3},
        "B1" => %{"v" => 4},
        "B2" => %{"v" => 5},
        "B3" => %{"v" => 6}
      }

      assert eval!("SUMPRODUCT(A1:A3,B1:B3)", cells) == 18
      # the blank tail rows of a taller pair contribute nothing
      assert eval!("SUMPRODUCT(A1:A9,B1:B9)", cells) == 18
      # all-blank ranges sum to 0
      assert eval!("SUMPRODUCT(A1:A3,B1:B3)") == 0
    end

    test "mismatched dimensions are #VALUE!" do
      assert eval!("SUMPRODUCT(A1:A3,B1:B2)", @sp) == "#VALUE!"
      assert eval!("SUMPRODUCT(A1:B2,A1:A3)", @sp) == "#VALUE!"
    end

    test "a non-range argument is #VALUE!" do
      assert eval!("SUMPRODUCT(A1:A3,2)", @sp) == "#VALUE!"
      assert eval!("SUMPRODUCT(5)") == "#VALUE!"
    end

    test "an error anywhere propagates, even aligned with a blank or zero" do
      cells = Map.put(@sp, "A2", %{"f" => "1/0"})
      assert eval!("SUMPRODUCT(A1:A3,B1:B3)", cells) == "#DIV/0!"
      # the error cell's counterpart range is EMPTY there — still surfaces
      cells2 = %{"A1" => %{"f" => "1/0"}, "A2" => %{"v" => 1}, "B2" => %{"v" => 2}}
      assert eval!("SUMPRODUCT(A1:A2,B1:B2)", cells2) == "#DIV/0!"
    end

    test "bignum: float-coercion overflow and huge exact products are #NUM!, no crash" do
      cells = %{"A1" => %{"v" => Integer.pow(10, 400)}, "B1" => %{"v" => 1.5}}
      assert eval!("SUMPRODUCT(A1:A1,B1:B1)", cells) == "#NUM!"
      cells2 = %{"A1" => %{"v" => Integer.pow(10, 400)}, "B1" => %{"v" => 2}}
      assert eval!("SUMPRODUCT(A1:A1,B1:B1)", cells2) == "#NUM!"
    end
  end

  describe "ADDRESS" do
    test "defaults to absolute A1 style" do
      assert eval!("ADDRESS(1,1)") == "$A$1"
      assert eval!("ADDRESS(2,3)") == "$C$2"
      assert eval!("ADDRESS(1,27)") == "$AA$1"
      assert cell!("ADDRESS(1,1)") |> Map.take(["v", "t"]) == %{"v" => "$A$1", "t" => "s"}
    end

    test "abs variants 1..4" do
      assert eval!("ADDRESS(2,3,1)") == "$C$2"
      assert eval!("ADDRESS(2,3,2)") == "C$2"
      assert eval!("ADDRESS(2,3,3)") == "$C2"
      assert eval!("ADDRESS(2,3,4)") == "C2"
    end

    test "R1C1 style when a1 is falsy" do
      assert eval!("ADDRESS(2,3,1,FALSE)") == "R2C3"
      assert eval!("ADDRESS(2,3,2,FALSE)") == "R2C[3]"
      assert eval!("ADDRESS(2,3,3,FALSE)") == "R[2]C3"
      assert eval!("ADDRESS(2,3,4,FALSE)") == "R[2]C[3]"
      assert eval!("ADDRESS(2,3,4,TRUE)") == "C2"
      assert eval!("ADDRESS(2,3,4,0)") == "R[2]C[3]"
    end

    test "fractional inputs truncate; the grid corners are addressable" do
      assert eval!("ADDRESS(2.9,3.9)") == "$C$2"
      assert eval!("ADDRESS(1048576,16384)") == "$XFD$1048576"
    end

    test "out-of-domain inputs are #VALUE!" do
      assert eval!("ADDRESS(0,1)") == "#VALUE!"
      assert eval!("ADDRESS(1,0)") == "#VALUE!"
      assert eval!("ADDRESS(1048577,1)") == "#VALUE!"
      assert eval!("ADDRESS(1,16385)") == "#VALUE!"
      assert eval!("ADDRESS(1,1,0)") == "#VALUE!"
      assert eval!("ADDRESS(1,1,5)") == "#VALUE!"
      assert eval!(~s|ADDRESS("r",1)|) == "#VALUE!"
      assert eval!(~s|ADDRESS(1,1,1,"x")|) == "#VALUE!"
    end

    test "bignum coordinates are #VALUE!, not a crash" do
      cells = %{"A1" => %{"v" => Integer.pow(10, 400)}}
      assert eval!("ADDRESS(A1,1)", cells) == "#VALUE!"
      assert eval!("ADDRESS(1,A1)", cells) == "#VALUE!"
    end

    test "errors propagate" do
      assert eval!("ADDRESS(1/0,1)") == "#DIV/0!"
      assert eval!("ADDRESS(1,1,1/0)") == "#DIV/0!"
    end
  end

  describe "coverage batch 3 is in function_names/0" do
    test "every new name is surfaced; the list stays sorted and unique" do
      names = Engine.function_names()

      for n <- ~w(XLOOKUP SUMPRODUCT ADDRESS) do
        assert n in names, "#{n} missing from function_names/0"
      end

      # The authoritative length assertion lives in the batch-4 block below.
      assert names == Enum.sort(names)
      assert Enum.uniq(names) == names
    end

    test "a stale XLOOKUP import flips to live" do
      out =
        run(%{
          "A1" => %{"v" => "k"},
          "B1" => %{"v" => 5},
          "C1" => %{"f" => ~s|XLOOKUP("k",A1:A1,B1:B1)|, "v" => 99, "t" => "n", "stale" => true}
        })

      assert out["C1"] == %{"f" => ~s|XLOOKUP("k",A1:A1,B1:B1)|, "v" => 5, "t" => "n"}
    end
  end

  # ── coverage batch 4 (remaining common scalar tier) ─────────────────────────

  describe "AVERAGEA / MAXA / MINA" do
    @a_mix %{
      "A1" => %{"v" => 10},
      "A2" => %{"v" => "text"},
      "A3" => %{"v" => true}
    }

    test "the A-variants coerce instead of skipping: text is 0, TRUE 1, FALSE 0" do
      # (10 + 0 + 1) / 3 — plain AVERAGE over the same range sees only the 10.
      assert_in_delta eval!("AVERAGEA(A1:A3)", @a_mix), 11 / 3, 1.0e-12
      assert eval!("AVERAGE(A1:A3)", @a_mix) == 10
    end

    test "MAXA/MINA see the coerced values where MAX/MIN skip them" do
      cells = %{"A1" => %{"v" => -5}, "A2" => %{"v" => true}, "A3" => %{"v" => "txt"}}
      assert eval!("MAXA(A1:A3)", cells) == 1
      assert eval!("MINA(A1:A3)", cells) == -5
      assert eval!("MAX(A1:A3)", cells) == -5
      # MINA's floor here is the text's 0, not the numeric -5's absence.
      assert eval!("MINA(A2:A3)", cells) == 0
    end

    test "direct scalar arguments coerce the same way" do
      assert eval!("MAXA(-5,TRUE)") == 1
      assert eval!(~s|MINA(5,"x")|) == 0
      assert_in_delta eval!("AVERAGEA(1,TRUE,FALSE)", %{}), 2 / 3, 1.0e-12
    end

    test "a date coerces to its Excel serial (days since 1899-12-30)" do
      cells = %{"A1" => %{"v" => "2024-01-01", "t" => "date"}}
      assert eval!("MAXA(A1:A1)", cells) == 45_292
    end

    test "an error cell propagates; an empty AVERAGEA is #DIV/0!" do
      cells = %{"A1" => %{"f" => "1/0"}}
      assert eval!("AVERAGEA(A1:A2)", cells) == "#DIV/0!"
      assert eval!("AVERAGEA(B1:B2)") == "#DIV/0!"
      # MAXA/MINA over nothing mirror MAX/MIN's 0.
      assert eval!("MAXA(B1:B2)") == 0
    end
  end

  describe "GEOMEAN / HARMEAN" do
    test "GEOMEAN is product^(1/n)" do
      assert eval!("GEOMEAN(2,8)") == 4.0
      assert eval!("GEOMEAN(4)") == 4.0
      assert_in_delta eval!("GEOMEAN(1,3,9)", %{}), 3.0, 1.0e-12
    end

    test "HARMEAN is n / sum(1/x)" do
      assert_in_delta eval!("HARMEAN(2,6)", %{}), 3.0, 1.0e-12
      assert eval!("HARMEAN(4,4)") == 4.0
    end

    test "a non-positive value is #NUM! for both" do
      assert eval!("GEOMEAN(2,-8)") == "#NUM!"
      assert eval!("GEOMEAN(0,8)") == "#NUM!"
      assert eval!("HARMEAN(2,0)") == "#NUM!"
      assert eval!("HARMEAN(-1)") == "#NUM!"
    end

    test "empty input is #NUM!; range text skips like other strict aggregates" do
      assert eval!("GEOMEAN(B1:B2)") == "#NUM!"
      cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => "skip"}, "A3" => %{"v" => 8}}
      assert eval!("GEOMEAN(A1:A3)", cells) == 4.0
    end

    test "an error argument propagates" do
      assert eval!("GEOMEAN(1/0,2)") == "#DIV/0!"
      assert eval!("HARMEAN(2,1/0)") == "#DIV/0!"
    end
  end

  describe "MROUND" do
    test "rounds to the nearest multiple, half away from zero" do
      assert eval!("MROUND(10,3)") == 9
      assert eval!("MROUND(11,3)") == 12
      assert eval!("MROUND(15,10)") == 20
      assert eval!("MROUND(2.5,1)") == 3
    end

    test "both-negative mirrors the positive case" do
      assert eval!("MROUND(-10,-3)") == -9
      assert eval!("MROUND(-2.5,-1)") == -3
    end

    test "a sign mismatch is #NUM!; a zero multiple is 0" do
      assert eval!("MROUND(10,-3)") == "#NUM!"
      assert eval!("MROUND(-10,3)") == "#NUM!"
      assert eval!("MROUND(10,0)") == 0
      # n = 0 matches any multiple's sign.
      assert eval!("MROUND(0,-3)") == 0
    end

    test "integer pairs stay exact ints; errors propagate" do
      cell = cell!("MROUND(10,3)")
      assert cell["v"] == 9
      assert cell["t"] == "n"
      assert eval!("MROUND(1/0,3)") == "#DIV/0!"
    end
  end

  describe "QUOTIENT" do
    test "integer division truncates toward zero" do
      assert eval!("QUOTIENT(10,3)") == 3
      assert eval!("QUOTIENT(-10,3)") == -3
      assert eval!("QUOTIENT(7.5,2)") == 3
      assert eval!("QUOTIENT(-7.5,2)") == -3
    end

    test "division by zero is #DIV/0!; errors propagate" do
      assert eval!("QUOTIENT(10,0)") == "#DIV/0!"
      assert eval!("QUOTIENT(1/0,2)") == "#DIV/0!"
    end
  end

  describe "JOIN" do
    test "joins a range (blanks dropped) and scalar args with the delimiter" do
      cells = %{"A1" => %{"v" => "a"}, "A2" => %{"v" => "b"}, "A4" => %{"v" => "c"}}
      assert eval!(~s|JOIN("-",A1:A4)|, cells) == "a-b-c"
      assert eval!(~s|JOIN(", ",1,2)|) == "1, 2"
    end

    test "an error propagates" do
      assert eval!(~s|JOIN("-",1/0,2)|) == "#DIV/0!"
    end
  end

  describe "NUMBERVALUE" do
    test "default separators: . decimal, , group" do
      assert eval!(~s|NUMBERVALUE("2.5")|) == 2.5
      assert eval!(~s|NUMBERVALUE("1,234.5")|) == 1234.5
      assert eval!(~s|NUMBERVALUE("-3")|) == -3
    end

    test "custom separators (first character wins)" do
      assert eval!(~s|NUMBERVALUE("3,5",",",".")|) == 3.5
      assert eval!(~s|NUMBERVALUE("1.234,5",",",".")|) == 1234.5
    end

    test "whitespace is ignored; empty text is 0; trailing % divides by 100" do
      assert eval!(~s|NUMBERVALUE(" 1 234.5 ")|) == 1234.5
      assert eval!(~s|NUMBERVALUE("")|) == 0
      assert eval!(~s|NUMBERVALUE("9%")|) == 0.09
      assert eval!(~s|NUMBERVALUE("250%%")|) == 0.025
    end

    test "unparseable text, equal separators, or a group sep after the decimal are #VALUE!" do
      assert eval!(~s|NUMBERVALUE("abc")|) == "#VALUE!"
      assert eval!(~s|NUMBERVALUE("1",".",".")|) == "#VALUE!"
      assert eval!(~s|NUMBERVALUE("3.1,4")|) == "#VALUE!"
      assert eval!(~s|NUMBERVALUE("1.2.3")|) == "#VALUE!"
    end

    test "an error argument propagates" do
      assert eval!("NUMBERVALUE(1/0)") == "#DIV/0!"
    end
  end

  describe "CLEAN / T / N / TYPE" do
    test "CLEAN strips non-printable control characters (codepoints < 32)" do
      cells = %{"A1" => %{"v" => "a\nb\tc" <> <<7>>}}
      assert eval!("CLEAN(A1)", cells) == "abc"
      # non-text coerces through the & rule first
      assert eval!("CLEAN(5)") == "5"
    end

    test "T passes text through and blanks everything else" do
      assert eval!(~s|T("hi")|) == "hi"
      assert eval!("T(5)") == ""
      assert eval!("T(TRUE)") == ""
      assert eval!("T(1/0)") == "#DIV/0!"
    end

    test "N coerces: number stays, TRUE 1, FALSE 0, date serial, text 0" do
      assert eval!("N(5)") == 5
      assert eval!("N(TRUE)") == 1
      assert eval!("N(FALSE)") == 0
      assert eval!(~s|N("5")|) == 0
      cells = %{"A1" => %{"v" => "2024-01-01", "t" => "date"}}
      assert eval!("N(A1)", cells) == 45_292
      assert eval!("N(1/0)") == "#DIV/0!"
    end

    test "TYPE: 1 number, 2 text, 4 boolean, 16 error, 64 array" do
      assert eval!("TYPE(1)") == 1
      assert eval!(~s|TYPE("x")|) == 2
      assert eval!("TYPE(TRUE)") == 4
      assert eval!("TYPE(1/0)") == 16
      # blank ref and a date both read numeric
      assert eval!("TYPE(B7)") == 1
      cells = %{"A1" => %{"v" => "2024-01-01", "t" => "date"}, "A2" => %{"v" => 1}}
      assert eval!("TYPE(A1)", cells) == 1
      assert eval!("TYPE(UNIQUE(A1:A2))", cells) == 64
    end
  end

  describe "ISFORMULA" do
    test "true for a formula cell, false for values and blanks" do
      cells = %{"A1" => %{"f" => "1+1"}, "B1" => %{"v" => 2}}
      assert eval!("ISFORMULA(A1)", cells) == true
      assert eval!("ISFORMULA(B1)", cells) == false
      assert eval!("ISFORMULA(C9)", cells) == false
    end

    test "a range reads its top-left; a non-reference is #VALUE!" do
      cells = %{"A1" => %{"f" => "1+1"}}
      assert eval!("ISFORMULA(A1:B2)", cells) == true
      assert eval!("ISFORMULA(5)") == "#VALUE!"
    end
  end

  describe "DATEVALUE / TIMEVALUE" do
    test "DATEVALUE parses ISO date text into the engine's date vocabulary" do
      cell = cell!(~s|DATEVALUE("2024-03-15")|)
      assert cell["v"] == "2024-03-15"
      assert cell["t"] == "date"
      # composes with the calendar functions
      assert eval!(~s|YEAR(DATEVALUE("2024-03-15"))|) == 2024
      # datetime text keeps only the date part
      assert eval!(~s|DATEVALUE("2026-06-12T10:30:45Z")|) == "2026-06-12"
    end

    test "DATEVALUE of unparseable text or a non-text is #VALUE!" do
      assert eval!(~s|DATEVALUE("nope")|) == "#VALUE!"
      assert eval!("DATEVALUE(5)") == "#VALUE!"
      assert eval!("DATEVALUE(1/0)") == "#DIV/0!"
    end

    test "TIMEVALUE parses time text into the fractional-day serial" do
      assert eval!(~s|TIMEVALUE("12:00")|) == 0.5
      assert eval!(~s|TIMEVALUE("06:00:00")|) == 0.25
      # single-digit hour and past-midnight rollover, mirroring TIME/3
      assert eval!(~s|TIMEVALUE("6:00")|) == 0.25
      assert eval!(~s|TIMEVALUE("24:00")|) == 0
      # the serial reads back through HOUR
      assert eval!(~s|HOUR(TIMEVALUE("13:45"))|) == 13
      # datetime text keeps only the time part
      assert eval!(~s|TIMEVALUE("2026-06-12T18:00:00Z")|) == 0.75
    end

    test "TIMEVALUE of unparseable text or a non-text is #VALUE!" do
      assert eval!(~s|TIMEVALUE("nope")|) == "#VALUE!"
      assert eval!("TIMEVALUE(5)") == "#VALUE!"
      assert eval!("TIMEVALUE(1/0)") == "#DIV/0!"
    end
  end

  describe "YEARFRAC" do
    test "basis 0 (default) — US 30/360" do
      assert eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1))") == 0.5
      assert eval!("YEARFRAC(DATE(2024,1,1),DATE(2025,1,1))") == 1
      # the 31st clamps to 30 on both ends
      assert_in_delta eval!("YEARFRAC(DATE(2024,1,31),DATE(2024,3,31))", %{}), 1 / 6, 1.0e-12
    end

    test "basis 1 — actual/actual (average year length over spanned years)" do
      assert_in_delta eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),1)", %{}),
                      182 / 366,
                      1.0e-12

      assert_in_delta eval!("YEARFRAC(DATE(2023,1,1),DATE(2025,1,1),1)", %{}),
                      731 * 3 / 1096,
                      1.0e-12
    end

    test "bases 2/3/4 — actual/360, actual/365, European 30/360" do
      assert_in_delta eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),2)", %{}),
                      182 / 360,
                      1.0e-12

      assert_in_delta eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),3)", %{}),
                      182 / 365,
                      1.0e-12

      # European: both 31sts clamp unconditionally
      assert_in_delta eval!("YEARFRAC(DATE(2024,1,31),DATE(2024,3,31),4)", %{}),
                      1 / 6,
                      1.0e-12
    end

    test "reversed dates swap (result stays positive); bad basis is #NUM!" do
      assert eval!("YEARFRAC(DATE(2024,7,1),DATE(2024,1,1))") == 0.5
      assert eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),7)") == "#NUM!"
      assert eval!("YEARFRAC(DATE(2024,1,1),DATE(2024,7,1),-1)") == "#NUM!"
    end

    test "a non-date argument is #VALUE!; errors propagate" do
      assert eval!("YEARFRAC(1,DATE(2024,1,1))") == "#VALUE!"
      assert eval!("YEARFRAC(DATE(2024,1,1),1/0)") == "#DIV/0!"
    end
  end

  describe "batch-4 bignum positive controls (no raise, ever)" do
    # A stored value past float64 (import path) must degrade to #NUM! on every
    # new arithmetic path, never crash the recompute.
    @big4 Integer.pow(2, 1100)

    test "GEOMEAN/HARMEAN over a stored bignum are #NUM!" do
      cells = %{"A1" => %{"v" => @big4}}
      assert eval!("GEOMEAN(A1)", cells) == "#NUM!"
      assert eval!("HARMEAN(A1)", cells) == "#NUM!"
    end

    test "MROUND/QUOTIENT with a bignum degrade on both int and float paths" do
      cells = %{"A1" => %{"v" => @big4}}
      # exact integer paths produce a bignum that canonicalises at output
      assert eval!("MROUND(A1,2)", cells) == "#NUM!"
      assert eval!("QUOTIENT(A1,2)", cells) == "#NUM!"
      # float paths overflow the coercion and get rescued
      assert eval!("MROUND(A1,2.5)", cells) == "#NUM!"
      assert eval!("QUOTIENT(A1,2.5)", cells) == "#NUM!"
    end

    test "N/AVERAGEA passing a bignum through canonicalise at the boundary" do
      cells = %{"A1" => %{"v" => @big4}}
      assert eval!("N(A1)", cells) == "#NUM!"
      assert eval!("AVERAGEA(A1:A1)", cells) == "#NUM!"
    end
  end

  describe "coverage batch 4 is in function_names/0" do
    test "every new name is surfaced; the count, sort and uniqueness hold" do
      names = Engine.function_names()

      for n <- ~w(AVERAGEA MAXA MINA GEOMEAN HARMEAN MROUND QUOTIENT JOIN
                  NUMBERVALUE CLEAN T N ISFORMULA TYPE DATEVALUE TIMEVALUE YEARFRAC) do
        assert n in names, "#{n} missing from function_names/0"
      end

      # 123 after batch 3 + 17 batch-4 names + RAND/RANDBETWEEN = 142, then
      # + TRANSPOSE CONCAT SUBTOTAL HSTACK VSTACK (the everyday batch) = 147.
      # THE authoritative count.
      assert "RAND" in names and "RANDBETWEEN" in names
      assert length(names) == 147
      assert names == Enum.sort(names)
      assert Enum.uniq(names) == names
    end

    test "a stale MROUND import flips to live" do
      out = run(%{"A1" => %{"f" => "MROUND(10,3)", "v" => 99, "t" => "n", "stale" => true}})
      assert out["A1"] == %{"f" => "MROUND(10,3)", "v" => 9, "t" => "n"}
    end
  end

  # ── cross-tab references (wave 1: {tab,col,row} coordinate + `!` grammar) ────

  # Recompute a multi-tab content map. `tabs` is a list of {name, cells} pairs.
  defp run_tabs(tabs) do
    %{"tabs" => Enum.map(tabs, fn {name, cells} -> %{"name" => name, "cells" => cells} end)}
    |> Engine.recompute()
  end

  # The recomputed cells of a named tab.
  defp tab_cells(content, name) do
    content["tabs"] |> Enum.find(&(&1["name"] == name)) |> Map.get("cells")
  end

  defp vt(cell), do: Map.take(cell, ["v", "t"])

  describe "cross-tab references" do
    test "=Sheet2!A1 reads another tab's cell" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => 42, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"] == %{"f" => "Sheet2!A1", "v" => 42, "t" => "n"}
    end

    test "=SUM(Sheet2!A1:A3) sums another tab's range" do
      out =
        run_tabs([
          {"Sheet1", %{"Z1" => %{"f" => "SUM(Sheet2!A1:A3)"}}},
          {"Sheet2",
           %{
             "A1" => %{"v" => 1, "t" => "n"},
             "A2" => %{"v" => 2, "t" => "n"},
             "A3" => %{"v" => 3, "t" => "n"}
           }}
        ])

      assert tab_cells(out, "Sheet1")["Z1"]["v"] == 6
    end

    test "a two-tab reference cycle yields #CYCLE! on both cells" do
      out =
        run_tabs([
          {"Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}},
          {"Sheet2", %{"A1" => %{"f" => "Sheet1!A1"}}}
        ])

      assert vt(tab_cells(out, "Sheet1")["A1"]) == %{"v" => "#CYCLE!", "t" => "e"}
      assert vt(tab_cells(out, "Sheet2")["A1"]) == %{"v" => "#CYCLE!", "t" => "e"}
    end

    test "an unknown tab name yields #REF!" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Nope!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => 42, "t" => "n"}}}
        ])

      assert vt(tab_cells(out, "Sheet1")["B1"]) == %{"v" => "#REF!", "t" => "e"}
    end

    test "an unknown tab is #REF! even in an otherwise cross-tab document" do
      out =
        run_tabs([
          {"Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}, "B1" => %{"f" => "Nope!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => 7, "t" => "n"}}}
        ])

      s1 = tab_cells(out, "Sheet1")
      assert s1["A1"]["v"] == 7
      assert vt(s1["B1"]) == %{"v" => "#REF!", "t" => "e"}
    end

    test "a self-tab name resolves same-tab (routes through the unified path)" do
      content = %{
        "tabs" => [
          %{
            "name" => "Sheet1",
            "cells" => %{"A1" => %{"v" => 10, "t" => "n"}, "B1" => %{"f" => "Sheet1!A1"}}
          }
        ]
      }

      # A resolvable qualifier — even a self-reference — takes the unified path.
      assert Engine.uses_cross_tab?(content)
      out = Engine.recompute(content)
      assert get_in(out, ["tabs", Access.at(0), "cells", "B1", "v"]) == 10
    end

    test "=Sheet1!A1 in A1 (a self-name loop) is #CYCLE!" do
      content = %{"tabs" => [%{"name" => "Sheet1", "cells" => %{"A1" => %{"f" => "Sheet1!A1"}}}]}
      out = Engine.recompute(content)
      assert get_in(out, ["tabs", Access.at(0), "cells", "A1", "v"]) == "#CYCLE!"
    end

    test "editing the referenced cell recomputes the dependent cell" do
      doc = fn v ->
        [
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => v, "t" => "n"}}}
        ]
      end

      assert tab_cells(run_tabs(doc.(5)), "Sheet1")["B1"]["v"] == 5
      assert tab_cells(run_tabs(doc.(9)), "Sheet1")["B1"]["v"] == 9
    end

    test "a cross-tab ref composes inside arithmetic" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!A1 * 2 + 1"}}},
          {"Sheet2", %{"A1" => %{"v" => 4, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 9
    end

    test "a quoted tab name with a space resolves" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "'My Sheet'!A1"}}},
          {"My Sheet", %{"A1" => %{"v" => 99, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 99
    end

    test "'' escapes a literal apostrophe in a quoted tab name" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "'O''Brien'!A1"}}},
          {"O'Brien", %{"A1" => %{"v" => 3, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 3
    end

    test "tab names resolve case-insensitively (Excel)" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "SHEET2!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => 8, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 8
    end

    test "a range spanning two different tabs is #REF!" do
      out =
        run_tabs([
          {"Sheet1", %{"Z1" => %{"f" => "SUM(Sheet2!A1:Sheet3!B2)"}}},
          {"Sheet2", %{"A1" => %{"v" => 1, "t" => "n"}}},
          {"Sheet3", %{"B2" => %{"v" => 2, "t" => "n"}}}
        ])

      assert vt(tab_cells(out, "Sheet1")["Z1"]) == %{"v" => "#REF!", "t" => "e"}
    end

    test "a cross-tab reference across three tabs orders correctly (unified topo)" do
      # Sheet3.A1 = 100; Sheet2.A1 = Sheet3!A1 + 1; Sheet1.A1 = Sheet2!A1 * 2.
      out =
        run_tabs([
          {"Sheet1", %{"A1" => %{"f" => "Sheet2!A1 * 2"}}},
          {"Sheet2", %{"A1" => %{"f" => "Sheet3!A1 + 1"}}},
          {"Sheet3", %{"A1" => %{"v" => 100, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet2")["A1"]["v"] == 101
      assert tab_cells(out, "Sheet1")["A1"]["v"] == 202
    end

    test "=SUM(Sheet2!A:A) aggregates another tab's whole column (A:A × cross-tab)" do
      # Rides wave 1's {tab,col,row} range: the full-column bounds tag survives
      # tab resolution and the used-range scan runs against Sheet2.
      out =
        run_tabs([
          {"Sheet1", %{"Z1" => %{"f" => "SUM(Sheet2!A:A)"}}},
          {"Sheet2",
           %{
             "A1" => %{"v" => 1, "t" => "n"},
             "A2" => %{"v" => 2, "t" => "n"},
             "A50" => %{"v" => 3, "t" => "n"},
             "B1" => %{"v" => 100, "t" => "n"}
           }}
        ])

      assert tab_cells(out, "Sheet1")["Z1"]["v"] == 6
    end

    test "=COUNT(Sheet2!2:2) aggregates another tab's whole row (3:3 × cross-tab)" do
      out =
        run_tabs([
          {"Sheet1", %{"Z1" => %{"f" => "COUNT(Sheet2!2:2)"}}},
          {"Sheet2",
           %{
             "A2" => %{"v" => 1, "t" => "n"},
             "C2" => %{"v" => 2, "t" => "n"},
             "A1" => %{"v" => 100, "t" => "n"}
           }}
        ])

      assert tab_cells(out, "Sheet1")["Z1"]["v"] == 2
    end

    test "a bare A:A in a cross-tab document reads the formula's OWN tab" do
      # The doc trips the unified path (Sheet2!A1 elsewhere), so the bare A:A
      # flows through walk_qualified's 4-tuple own-tab clause.
      out =
        run_tabs([
          {"Sheet1",
           %{
             "A1" => %{"v" => 5, "t" => "n"},
             "A2" => %{"v" => 7, "t" => "n"},
             "Z1" => %{"f" => "SUM(A:A)"},
             "Z2" => %{"f" => "Sheet2!A1"}
           }},
          {"Sheet2", %{"A1" => %{"v" => 1, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["Z1"]["v"] == 12
    end

    test "as_range consumers fail closed (never crash) on a cross-tab range" do
      # VLOOKUP's table argument reaching another tab is not wired in wave 1 —
      # it must yield a clean error, not raise inside recompute.
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "VLOOKUP(1, Sheet2!A1:B3, 2)"}}},
          {"Sheet2",
           %{
             "A1" => %{"v" => 1, "t" => "n"},
             "B1" => %{"v" => 9, "t" => "n"}
           }}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["t"] == "e"
    end

    # ── hardening locks (behaviour X2/X3 must preserve) ──────────────────────

    test "a same-tab range and a cross-tab ref coexist in one formula" do
      # Exercises the ctx.tab rebasing: SUM(A1:A2) must read the FORMULA's own
      # tab (localize_range is a no-op, ctx.tab stays), while Sheet2!A1 reaches
      # the named tab — both inside one eval on the unified path.
      out =
        run_tabs([
          {"Sheet1",
           %{
             "A1" => %{"v" => 1, "t" => "n"},
             "A2" => %{"v" => 2, "t" => "n"},
             "B1" => %{"f" => "SUM(A1:A2)+Sheet2!A1"}
           }},
          {"Sheet2", %{"A1" => %{"v" => 10, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 13
    end

    test "an error in the referenced cell propagates across the tab boundary" do
      # The dependent must evaluate AFTER the erroring precedent (unified topo
      # order) and pass the error code through unchanged.
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!A1"}}},
          {"Sheet2", %{"A1" => %{"f" => "1/0"}}}
        ])

      assert vt(tab_cells(out, "Sheet1")["B1"]) == %{"v" => "#DIV/0!", "t" => "e"}
    end

    test "a cross-tab ref preserves the source cell's type (text)" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!A1"}}},
          {"Sheet2", %{"A1" => %{"v" => "hello", "t" => "s"}}}
        ])

      assert vt(tab_cells(out, "Sheet1")["B1"]) == %{"v" => "hello", "t" => "s"}
    end

    test "a cross-tab ref to a blank cell reads as an empty (zero in arithmetic)" do
      out =
        run_tabs([
          {"Sheet1", %{"B1" => %{"f" => "Sheet2!Z9+5"}}},
          {"Sheet2", %{"A1" => %{"v" => 1, "t" => "n"}}}
        ])

      assert tab_cells(out, "Sheet1")["B1"]["v"] == 5
    end
  end

  describe "cross-tab routing discriminator (CT-D4)" do
    test "REGRESSION LOCK: a zero-cross-tab multi-tab document takes the per-tab fast path, byte-identical" do
      s1 = %{
        "A1" => %{"v" => 1, "t" => "n"},
        "A2" => %{"v" => 2, "t" => "n"},
        "A3" => %{"f" => "SUM(A1:A2)"},
        "A4" => %{"f" => "A3*10"}
      }

      s2 = %{
        "B1" => %{"v" => 5, "t" => "n"},
        "B2" => %{"f" => "B1+1"},
        "B3" => %{"f" => "B9"}
      }

      content = %{
        "tabs" => [%{"name" => "Sheet1", "cells" => s1}, %{"name" => "Sheet2", "cells" => s2}]
      }

      # (a) branch discriminator: the unified path is NOT taken.
      refute Engine.uses_cross_tab?(content)

      out = Engine.recompute(content)

      # (b) byte-identical to the LEGACY per-tab semantics: the whole-document
      # output for each tab equals that tab recomputed in isolation (which IS
      # the fast path `Enum.map(tabs, &recompute_tab/1)`).
      for tab <- content["tabs"] do
        isolated = %{"tabs" => [tab]} |> Engine.recompute() |> get_in(["tabs", Access.at(0)])
        whole = out["tabs"] |> Enum.find(&(&1["name"] == tab["name"]))
        assert whole == isolated
      end

      assert tab_cells(out, "Sheet1")["A3"]["v"] == 3
      assert tab_cells(out, "Sheet1")["A4"]["v"] == 30
      assert tab_cells(out, "Sheet2")["B2"]["v"] == 6
    end

    test "an unresolvable !-formula alone does NOT trip the unified path" do
      content = %{
        "tabs" => [
          %{"name" => "Sheet1", "cells" => %{"B1" => %{"f" => "Nope!A1"}}},
          %{"name" => "Sheet2", "cells" => %{"A1" => %{"v" => 1, "t" => "n"}}}
        ]
      }

      # `Nope` resolves nowhere → fast path → the formula degrades to #REF!.
      refute Engine.uses_cross_tab?(content)
      out = Engine.recompute(content)
      assert get_in(out, ["tabs", Access.at(0), "cells", "B1", "v"]) == "#REF!"
    end

    test "a resolvable cross-tab reference DOES trip the unified path" do
      content = %{
        "tabs" => [
          %{"name" => "Sheet1", "cells" => %{"B1" => %{"f" => "Sheet2!A1"}}},
          %{"name" => "Sheet2", "cells" => %{"A1" => %{"v" => 1, "t" => "n"}}}
        ]
      }

      assert Engine.uses_cross_tab?(content)
    end

    test "a non-tabs content passes uses_cross_tab? without raising" do
      refute Engine.uses_cross_tab?(%{"locale" => "nb-NO"})
      refute Engine.uses_cross_tab?(nil)
    end
  end

  # ── everyday-function batch (TRANSPOSE / CONCAT / SUBTOTAL / HSTACK / VSTACK)
  #
  # RED-before on the pre-change engine: none of these five names was in
  # @functions, so `parse_formula` classified every formula below as :stale —
  # the cell came back `%{"f" => "…", "stale" => true}` with NO "v" at all
  # (NOT #REF! and NOT :invalid: an unknown function is the xlsx-import
  # compatibility path, which keeps the cached value and flags it). Every
  # `eval!/1` assertion here therefore read `nil` before this batch landed.
  # SEQUENCE(rows, cols) is the odd one out — it already shipped with the full
  # 1..4 arity, so its tests below are REGRESSION LOCKS, not RED-first.

  # A1 B1     1 2      transposed    1 3
  # A2 B2  =  3 4                    2 4
  defp quad do
    %{"A1" => %{"v" => 1}, "B1" => %{"v" => 2}, "A2" => %{"v" => 3}, "B2" => %{"v" => 4}}
  end

  defp trio, do: %{"A1" => %{"v" => 2}, "A2" => %{"v" => 4}, "A3" => %{"v" => 6}}

  describe "TRANSPOSE" do
    test "the name reaches function_names/0 (it was absent, so every formula was :stale)" do
      assert "TRANSPOSE" in Engine.function_names()
      refute cell!("TRANSPOSE(A1:B2)", quad())["stale"]
    end

    test "in a scalar position it intersects to the transposed top-left" do
      # Top-left of the TRANSPOSED grid is still A1's value here (1), but the
      # SECOND element proves the flip: SUM is order-insensitive, so use INDEX-
      # free evidence — the spilled region below carries the real proof.
      assert eval!("SUM(TRANSPOSE(A1:B2))", quad()) == 10
      assert eval!("TEXTJOIN(\",\", 0, TRANSPOSE(A1:B2))", quad()) == "1,3,2,4"
    end

    test "a top-level TRANSPOSE spills the flipped rectangle" do
      cells = run(Map.put(quad(), "A4", %{"f" => "TRANSPOSE(A1:B2)"}))

      assert cells["A4"]["v"] == 1
      assert cells["A4"]["spill_dims"] == [2, 2]
      assert cells["B4"]["v"] == 3
      assert cells["A5"]["v"] == 2
      assert cells["B5"]["v"] == 4
      # engine-owned cells: value + spill marker, never an `f`
      refute Map.has_key?(cells["B4"], "f")
      assert cells["B4"]["spill"] == "A4"
    end

    test "a non-square source flips its dimensions" do
      cells =
        run(%{
          "A1" => %{"v" => 1},
          "B1" => %{"v" => 2},
          "C1" => %{"v" => 3},
          "A3" => %{"f" => "TRANSPOSE(A1:C1)"}
        })

      assert cells["A3"]["spill_dims"] == [3, 1]
      assert Enum.map(~w(A3 A4 A5), &cells[&1]["v"]) == [1, 2, 3]
    end

    test "an obstructed spill blocks WHOLE with #SPILL!" do
      cells =
        quad()
        |> Map.put("A4", %{"f" => "TRANSPOSE(A1:B2)"})
        |> Map.put("B5", %{"v" => "in the way"})
        |> run()

      assert cells["A4"]["v"] == "#SPILL!"
      assert cells["A4"]["t"] == "e"
      refute Map.has_key?(cells["A4"], "spill_dims")
      # nothing else was written — the obstruction keeps its own value
      assert cells["B5"]["v"] == "in the way"
      refute Map.has_key?(cells, "B4")
    end

    test "an element error rides through IN PLACE, it does not collapse the array" do
      cells =
        quad()
        |> Map.put("B1", %{"f" => "1/0"})
        |> Map.put("A4", %{"f" => "TRANSPOSE(A1:B2)"})
        |> run()

      # transposed: [[1, 3], [#DIV/0!, 4]] — the error lands at A5, the rest survive
      assert cells["A4"]["v"] == 1
      assert cells["B4"]["v"] == 3
      assert cells["A5"]["v"] == "#DIV/0!"
      assert cells["A5"]["t"] == "e"
      assert cells["B5"]["v"] == 4
    end

    test "an empty source is #VALUE!" do
      assert eval!("TRANSPOSE(M50:N51)", quad()) == "#VALUE!"
    end

    test "wrong arity is #VALUE!" do
      assert eval!("TRANSPOSE(A1:B2, 2)", quad()) == "#VALUE!"
      assert eval!("TRANSPOSE()", quad()) == "#VALUE!"
    end
  end

  describe "CONCAT" do
    test "the name reaches function_names/0" do
      assert "CONCAT" in Engine.function_names()
      refute cell!("CONCAT(\"a\")")["stale"]
    end

    test "scalars concatenate exactly like CONCATENATE" do
      assert eval!("CONCAT(\"a\", 1, TRUE)") == "a1TRUE"
      assert eval!("CONCAT(\"a\", 1, TRUE)") == eval!("CONCATENATE(\"a\", 1, TRUE)")
    end

    test "a RANGE argument flattens row-major — the one thing CONCATENATE refuses" do
      assert eval!("CONCAT(A1:B2)", quad()) == "1234"
      # the legacy twin still rejects a range, which is why CONCAT exists
      assert eval!("CONCATENATE(A1:B2)", quad()) == "#VALUE!"
    end

    test "a blank inside the range contributes \"\" rather than being skipped" do
      cells = %{"A1" => %{"v" => "x"}, "B1" => %{"v" => "y"}, "A2" => %{"v" => "z"}}
      # grid is [[x, y], [z, blank]] — the blank renders as nothing, not a gap
      assert eval!("CONCAT(A1:B2)", cells) == "xyz"
    end

    test "an intermediate array argument flattens too" do
      assert eval!("CONCAT(SORT(A1:B2, -1))", quad()) == "4321"
      assert eval!("CONCAT(SEQUENCE(2, 2))", quad()) == "1234"
    end

    test "an error in the source propagates" do
      cells = Map.put(quad(), "B2", %{"f" => "1/0"})
      assert eval!("CONCAT(A1:B2)", cells) == "#DIV/0!"
      assert eval!("CONCAT(\"a\", 1/0)") == "#DIV/0!"
    end

    test "a result past Excel's 32,767-char cell limit is #VALUE!" do
      assert eval!("LEN(CONCAT(REPT(\"x\", 20000), REPT(\"y\", 12767)))") == 32_767
      assert eval!("CONCAT(REPT(\"x\", 20000), REPT(\"y\", 12768))") == "#VALUE!"
    end

    test "zero arguments is #VALUE!" do
      assert eval!("CONCAT()") == "#VALUE!"
    end
  end

  describe "SUBTOTAL" do
    test "the name reaches function_names/0" do
      assert "SUBTOTAL" in Engine.function_names()
      refute cell!("SUBTOTAL(9, A1:A3)", trio())["stale"]
    end

    test "each of the eleven codes selects its aggregate" do
      c = Map.merge(trio(), %{"A4" => %{"v" => "text"}, "A5" => %{"v" => 8}})

      assert eval!("SUBTOTAL(1, A1:A5)", c) == eval!("AVERAGE(A1:A5)", c)
      assert eval!("SUBTOTAL(2, A1:A5)", c) == eval!("COUNT(A1:A5)", c)
      assert eval!("SUBTOTAL(3, A1:A5)", c) == eval!("COUNTA(A1:A5)", c)
      assert eval!("SUBTOTAL(4, A1:A5)", c) == eval!("MAX(A1:A5)", c)
      assert eval!("SUBTOTAL(5, A1:A5)", c) == eval!("MIN(A1:A5)", c)
      assert eval!("SUBTOTAL(6, A1:A3)", c) == eval!("PRODUCT(A1:A3)", c)
      assert eval!("SUBTOTAL(7, A1:A3)", c) == eval!("STDEV(A1:A3)", c)
      assert eval!("SUBTOTAL(8, A1:A3)", c) == eval!("STDEVP(A1:A3)", c)
      assert eval!("SUBTOTAL(9, A1:A5)", c) == eval!("SUM(A1:A5)", c)
      assert eval!("SUBTOTAL(10, A1:A3)", c) == eval!("VAR(A1:A3)", c)
      assert eval!("SUBTOTAL(11, A1:A3)", c) == eval!("VARP(A1:A3)", c)

      # the everyday one, spelled out
      assert eval!("SUBTOTAL(9, A1:A3)", c) == 12
      # COUNT sees the four numbers; COUNTA also sees the text cell.
      assert eval!("SUBTOTAL(2, A1:A5)", c) == 4
      assert eval!("SUBTOTAL(3, A1:A5)", c) == 5
    end

    test "DOCUMENTED GAP: 101-111 evaluate identically to 1-11 (no row-visibility input)" do
      for {lo, hi} <- Enum.zip(1..11, 101..111) do
        assert eval!("SUBTOTAL(#{lo}, A1:A3)", trio()) ==
                 eval!("SUBTOTAL(#{hi}, A1:A3)", trio()),
               "code #{hi} diverged from #{lo} — the hidden-row gap was closed " <>
                 "without updating the moduledoc"
      end
    end

    test "DOCUMENTED GAP: a nested SUBTOTAL inside the range IS double-counted" do
      # Excel skips a nested SUBTOTAL so stacked totals don't compound.
      # ctx.formulas carries coordinates, never formula TEXT, so this engine
      # cannot see one. Pinned so a future fix reds here first.
      cells = Map.put(trio(), "A4", %{"f" => "SUBTOTAL(9, A1:A3)"})
      assert eval!("SUBTOTAL(9, A1:A4)", cells) == 24
    end

    test "several refs AND-combine like a plain aggregate" do
      cells = Map.merge(trio(), %{"C1" => %{"v" => 10}, "C2" => %{"v" => 20}})
      assert eval!("SUBTOTAL(9, A1:A3, C1:C2)", cells) == 42
    end

    test "an intermediate array is a legal ref" do
      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => 5}, "A3" => %{"v" => 7}}
      assert eval!("SUBTOTAL(9, UNIQUE(A1:A3))", cells) == 12
    end

    test "a code outside 1-11 / 101-111 is #VALUE!" do
      for code <- [0, 12, 100, 112, -1] do
        assert eval!("SUBTOTAL(#{code}, A1:A3)", trio()) == "#VALUE!",
               "code #{code} should be #VALUE!"
      end

      assert eval!("SUBTOTAL(\"nine\", A1:A3)", trio()) == "#VALUE!"
    end

    test "a code cell holding an error propagates; a missing ref is #VALUE!" do
      cells = Map.put(trio(), "B1", %{"f" => "1/0"})
      assert eval!("SUBTOTAL(B1, A1:A3)", cells) == "#DIV/0!"
      assert eval!("SUBTOTAL(9)", trio()) == "#VALUE!"
    end

    test "a fractional code truncates, as Excel does" do
      assert eval!("SUBTOTAL(9.7, A1:A3)", trio()) == 12
    end
  end

  describe "VSTACK / HSTACK" do
    test "the names reach function_names/0" do
      assert "VSTACK" in Engine.function_names()
      assert "HSTACK" in Engine.function_names()
      refute cell!("VSTACK(A1:B1, A2:B2)", quad())["stale"]
      refute cell!("HSTACK(A1:A2, B1:B2)", quad())["stale"]
    end

    test "VSTACK appends grids downward and spills" do
      cells = run(Map.put(quad(), "A4", %{"f" => "VSTACK(A1:B1, A2:B2)"}))

      assert cells["A4"]["spill_dims"] == [2, 2]
      assert Enum.map(~w(A4 B4 A5 B5), &cells[&1]["v"]) == [1, 2, 3, 4]
    end

    test "HSTACK appends grids sideways and spills" do
      # Two adjacent COLUMNS re-stacked sideways reproduce the source rectangle
      # exactly — the identity that makes the axis unambiguous.
      cells = run(Map.put(quad(), "A4", %{"f" => "HSTACK(A1:A2, B1:B2)"}))

      assert cells["A4"]["spill_dims"] == [2, 2]
      assert Enum.map(~w(A4 B4 A5 B5), &cells[&1]["v"]) == [1, 2, 3, 4]

      # …and the axis really is horizontal: stacking the two ROWS sideways
      # gives a 1x4 strip, where VSTACK of the same two rows gives 2x2.
      wide = run(Map.put(quad(), "A4", %{"f" => "HSTACK(A1:B1, A2:B2)"}))
      assert wide["A4"]["spill_dims"] == [1, 4]
      assert Enum.map(~w(A4 B4 C4 D4), &wide[&1]["v"]) == [1, 2, 3, 4]
    end

    test "three arguments stack in order" do
      cells =
        run(%{
          "A1" => %{"v" => 1},
          "A2" => %{"v" => 2},
          "A3" => %{"v" => 3},
          "C1" => %{"f" => "VSTACK(A1, A2, A3)"}
        })

      assert cells["C1"]["spill_dims"] == [3, 1]
      assert Enum.map(~w(C1 C2 C3), &cells[&1]["v"]) == [1, 2, 3]
    end

    test "VSTACK pads a short row with #N/A (Excel)" do
      cells = run(Map.put(quad(), "A4", %{"f" => "VSTACK(A1:B1, A2)"}))

      assert cells["A4"]["spill_dims"] == [2, 2]
      assert Enum.map(~w(A4 B4 A5), &cells[&1]["v"]) == [1, 2, 3]
      assert cells["B5"]["v"] == "#N/A"
      assert cells["B5"]["t"] == "e"
    end

    test "HSTACK pads a short column with #N/A (Excel)" do
      cells = run(Map.put(quad(), "A4", %{"f" => "HSTACK(A1:A2, B1)"}))

      assert cells["A4"]["spill_dims"] == [2, 2]
      assert Enum.map(~w(A4 B4 A5), &cells[&1]["v"]) == [1, 2, 3]
      assert cells["B5"]["v"] == "#N/A"
    end

    test "a generated #N/A pad propagates to an outer aggregate" do
      assert eval!("SUM(VSTACK(A1:B1, A2))", quad()) == "#N/A"
      # the SQUARE stack has no pad, so the same aggregate answers a number
      assert eval!("SUM(VSTACK(A1:B1, A2:B2))", quad()) == 10
    end

    test "a source error rides through in place, distinct from a pad" do
      cells =
        quad()
        |> Map.put("A2", %{"f" => "1/0"})
        |> Map.put("A4", %{"f" => "VSTACK(A1:B1, A2:B2)"})
        |> run()

      assert Enum.map(~w(A4 B4), &cells[&1]["v"]) == [1, 2]
      assert cells["A5"]["v"] == "#DIV/0!"
      assert cells["B5"]["v"] == 4
    end

    test "an argument that materialises to nothing contributes nothing" do
      cells = run(Map.put(quad(), "A4", %{"f" => "VSTACK(A1:B1, M50:N51)"}))

      assert cells["A4"]["spill_dims"] == [1, 2]
      assert Enum.map(~w(A4 B4), &cells[&1]["v"]) == [1, 2]
    end

    test "all-empty is #VALUE!, zero arguments is #VALUE!" do
      assert eval!("VSTACK(M50:N51)", quad()) == "#VALUE!"
      assert eval!("HSTACK(M50:N51)", quad()) == "#VALUE!"
      assert eval!("VSTACK()", quad()) == "#VALUE!"
      assert eval!("HSTACK()", quad()) == "#VALUE!"
    end

    test "a result past the 100,000-cell array cap is #NUM!" do
      assert eval!("VSTACK(SEQUENCE(60000), SEQUENCE(60000))") == "#NUM!"
      assert eval!("HSTACK(SEQUENCE(1, 60000), SEQUENCE(1, 60000))") == "#NUM!"
      # just under the cap still evaluates
      assert eval!("SUM(VSTACK(SEQUENCE(50000), SEQUENCE(50000)))") == 2_500_050_000
    end

    test "stacks compose with TRANSPOSE" do
      assert eval!("TEXTJOIN(\",\", 0, TRANSPOSE(VSTACK(A1:B1, A2:B2)))", quad()) == "1,3,2,4"
    end
  end

  describe "SEQUENCE(rows, cols) — regression lock (this arity already shipped)" do
    test "the two-dimensional form generates row-major and spills" do
      cells = run(%{"A1" => %{"f" => "SEQUENCE(2, 3)"}})

      assert cells["A1"]["spill_dims"] == [2, 3]
      assert Enum.map(~w(A1 B1 C1 A2 B2 C2), &cells[&1]["v"]) == [1, 2, 3, 4, 5, 6]
    end

    test "start and step apply across the whole rectangle" do
      cells = run(%{"A1" => %{"f" => "SEQUENCE(2, 3, 10, 5)"}})

      assert Enum.map(~w(A1 B1 C1 A2 B2 C2), &cells[&1]["v"]) == [10, 15, 20, 25, 30, 35]
    end

    test "a non-positive dimension is #VALUE!, past the cap is #NUM!" do
      assert eval!("SEQUENCE(2, 0)") == "#VALUE!"
      assert eval!("SEQUENCE(0, 2)") == "#VALUE!"
      assert eval!("SEQUENCE(1000, 1000)") == "#NUM!"
    end
  end

  describe "the everyday batch is in function_names/0 and function_specs/0" do
    test "all five new names carry a name, args and a doc" do
      names = Engine.function_names()
      specs = Map.new(Engine.function_specs(), &{&1.name, &1})

      for n <- ~w(TRANSPOSE CONCAT SUBTOTAL HSTACK VSTACK) do
        assert n in names, "#{n} missing from function_names/0"
        assert %{args: args, doc: doc} = specs[n]
        assert args != []
        assert String.ends_with?(doc, ".")
      end
    end
  end
end
