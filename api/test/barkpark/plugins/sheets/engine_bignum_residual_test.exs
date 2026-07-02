defmodule Barkpark.Plugins.Sheets.EngineBignumResidualTest do
  @moduledoc """
  The bignum crash-class RESIDUAL (the #877 remainder). #877 wrapped many
  arithmetic sites in `safe_arith`/`divide`, but a single poisoned bignum cell
  (e.g. 10^400, entering via an API JSON literal or a `t:"n"` string) still
  raised ArithmeticError in nine remaining sites — making the doc unsaveable
  and crash-looping the per-sheet Session for every collaborator. Every case
  here raised on the unfixed source and must now degrade to `#NUM!`.

  The positive controls pin the boundary: exact bignum integers UP TO the
  float64 edge (2^1023 and friends) must keep computing exactly.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Engine

  # 10^400 — far past float64 (max ~1.8e308); any float coercion raises.
  @big Integer.pow(10, 400)

  # Recompute a single-tab content map and return its cells.
  defp run(cells) do
    %{"tabs" => [%{"name" => "T", "cells" => cells}]}
    |> Engine.recompute()
    |> get_in(["tabs", Access.at(0), "cells"])
  end

  # Evaluate one formula (in Z99, away from fixture cells) and return its v.
  defp eval!(formula, cells \\ %{}) do
    run(Map.put(cells, "Z99", %{"f" => formula}))["Z99"]["v"]
  end

  # The poison pair: a bignum int + a float sibling forces a float coercion
  # inside any naked `+` (Enum.sum, median pair, sparkline span).
  defp poison_pair, do: %{"A1" => %{"v" => @big}, "A2" => %{"v" => 1.5}}

  describe "aggregates over a poisoned bignum + float pair degrade to #NUM!" do
    test "SUM" do
      assert eval!("SUM(A1:A2)", poison_pair()) == "#NUM!"
    end

    test "AVG / AVERAGE" do
      assert eval!("AVG(A1:A2)", poison_pair()) == "#NUM!"
      assert eval!("AVERAGE(A1:A2)", poison_pair()) == "#NUM!"
    end

    test "SUMIF" do
      assert eval!(~s{SUMIF(A1:A2,">0")}, poison_pair()) == "#NUM!"
    end

    test "AVERAGEIF" do
      assert eval!(~s{AVERAGEIF(A1:A2,">0")}, poison_pair()) == "#NUM!"
    end

    test "SUMIFS" do
      cells = Map.merge(poison_pair(), %{"B1" => %{"v" => 1}, "B2" => %{"v" => 1}})
      assert eval!("SUMIFS(A1:A2,B1:B2,1)", cells) == "#NUM!"
    end

    test "AVERAGEIFS" do
      cells = Map.merge(poison_pair(), %{"B1" => %{"v" => 1}, "B2" => %{"v" => 1}})
      assert eval!("AVERAGEIFS(A1:A2,B1:B2,1)", cells) == "#NUM!"
    end

    test "MEDIAN (even pair — the internal pair sum overflows)" do
      assert eval!("MEDIAN(A1:A2)", poison_pair()) == "#NUM!"
    end

    test "SPARKLINE (the span subtraction overflows)" do
      assert eval!("SPARKLINE(A1:A2)", poison_pair()) == "#NUM!"
    end

    test "the t:\"n\" string entry path hits SUM identically" do
      cells = %{
        "A1" => %{"v" => "1" <> String.duplicate("0", 400), "t" => "n"},
        "A2" => %{"v" => 1.5}
      }

      assert eval!("SUM(A1:A2)", cells) == "#NUM!"
    end
  end

  describe "the remaining scalar sites degrade to #NUM!" do
    test "power on a stored bignum base: A1^2" do
      assert eval!("A1^2", %{"A1" => %{"v" => @big}}) == "#NUM!"
    end

    test "SEQUENCE generating a float-overflowing element" do
      cells = %{"A1" => %{"v" => 1.0e308}}
      assert eval!("SUM(SEQUENCE(2,1,A1,A1))", cells) == "#NUM!"
    end

    test "INT on a stored bignum" do
      assert eval!("INT(A1)", %{"A1" => %{"v" => @big}}) == "#NUM!"
    end

    test "VALUE on a bignum percent text" do
      nines = String.duplicate("9", 400)
      assert eval!(~s{VALUE("#{nines}%")}) == "#NUM!"
    end
  end

  describe "positive controls — the boundary stays exact" do
    test "2^1023 still computes to the exact 308-digit integer" do
      expected = Integer.pow(2, 1023)
      assert eval!("2^1023") === expected
      assert expected |> Integer.to_string() |> String.length() == 308
    end

    test "SUM over two exact 2^1022 ints is the exact 2^1023" do
      assert eval!("SUM(2^1022,2^1022)") === Integer.pow(2, 1023)
    end

    test "VALUE(\"200%\") stays the exact integer 2" do
      assert eval!(~s{VALUE("200%")}) === 2
    end

    test "plain large-float arithmetic is unchanged" do
      cells = %{"A1" => %{"v" => 1.7e308}}
      assert eval!("A1+0", cells) === 1.7e308
      assert eval!("SUM(A1)", cells) === 1.7e308
    end
  end
end
