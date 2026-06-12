defmodule Barkpark.Sheets.EngineTest do
  @moduledoc """
  Unit tests for `Barkpark.Sheets.Engine` — the formula engine. Pure
  functions, no DB: every test drives `recompute/1` on an in-memory content
  map and asserts the written-back cell descriptors.
  """
  use ExUnit.Case, async: true

  doctest Barkpark.Sheets.Engine

  alias Barkpark.Sheets.Engine

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
end
