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
    test "float * and + overflow yields #VALUE! instead of raising" do
      big = %{"A1" => %{"v" => 1.0e308}}
      # 1.0e308 * 1.0e308 and 1.0e308 + 1.0e308 both exceed the double range.
      assert eval!("A1*A1", big) == "#VALUE!"
      assert eval!("A1+A1", big) == "#VALUE!"
      assert eval!("A1-A1", big) == 0.0

      # a sum that stays in range is untouched
      half = %{"A1" => %{"v" => 5.0e307}}
      assert eval!("A1+A1", half) == 1.0e308
    end

    test "an unbounded integer exponent is capped to #VALUE!, no runaway bignum" do
      assert eval!("2^100000000") == "#VALUE!"
      # small exponents and the identity bases are untouched
      assert eval!("2^10") == 1024
      assert eval!("2^1024") == Integer.pow(2, 1024)
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

    test "numeric domain errors map to #VALUE!" do
      assert eval!("(-8)^0.5") == "#VALUE!"
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
end
