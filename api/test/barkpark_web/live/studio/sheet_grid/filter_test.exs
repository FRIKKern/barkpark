defmodule BarkparkWeb.Studio.SheetGrid.FilterTest do
  @moduledoc """
  Pins the per-viewer filter predicate matrix (slice SF-B, paper §3+§4). Pure,
  no DB, `async: true`. The five value ops ride the ONE `CondFormat.matches?/2`
  kernel (CF-D5), so this file asserts the FILTER-specific contract: the
  `blank`/`nonblank` occupancy ops, that value ops hide blanks like Excel, the
  multi-column AND, and the always-visible frozen-head + growth-padding bands.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.SheetGrid.Filter

  describe "matches?/2 — occupancy ops" do
    test "blank fires on a missing cell, nil v, or empty-string v" do
      assert Filter.matches?(%{"op" => "blank"}, nil)
      assert Filter.matches?(%{"op" => "blank"}, %{"v" => nil})
      assert Filter.matches?(%{"op" => "blank"}, %{"v" => ""})
      assert Filter.matches?(%{"op" => "blank"}, %{"s" => %{"b" => true}})
      refute Filter.matches?(%{"op" => "blank"}, %{"v" => 0})
      refute Filter.matches?(%{"op" => "blank"}, %{"v" => "x"})
    end

    test "nonblank is the exact complement of blank" do
      refute Filter.matches?(%{"op" => "nonblank"}, nil)
      refute Filter.matches?(%{"op" => "nonblank"}, %{"v" => ""})
      assert Filter.matches?(%{"op" => "nonblank"}, %{"v" => 0})
      assert Filter.matches?(%{"op" => "nonblank"}, %{"v" => "x"})
      # An error cell is NOT blank — it holds a value.
      assert Filter.matches?(%{"op" => "nonblank"}, %{"v" => "#DIV/0!", "t" => "e"})
    end
  end

  describe "matches?/2 — value ops delegate to the CF-D5 kernel" do
    test "gt / lt on a numeric cell" do
      assert Filter.matches?(%{"op" => "gt", "value" => 3}, %{"v" => 5})
      refute Filter.matches?(%{"op" => "gt", "value" => 5}, %{"v" => 5})
      assert Filter.matches?(%{"op" => "lt", "value" => 10}, %{"v" => 5})
      refute Filter.matches?(%{"op" => "lt", "value" => 1}, %{"v" => 5})
    end

    test "eq is same-class (1 == 1.0, case-insensitive text, no cross-type)" do
      assert Filter.matches?(%{"op" => "eq", "value" => 1}, %{"v" => 1.0})
      assert Filter.matches?(%{"op" => "eq", "value" => "Apple"}, %{"v" => "apple"})
      refute Filter.matches?(%{"op" => "eq", "value" => "1"}, %{"v" => 1})
    end

    test "between is inclusive on both ends" do
      assert Filter.matches?(%{"op" => "between", "value" => 1, "value2" => 10}, %{"v" => 1})
      assert Filter.matches?(%{"op" => "between", "value" => 1, "value2" => 10}, %{"v" => 10})
      refute Filter.matches?(%{"op" => "between", "value" => 1, "value2" => 10}, %{"v" => 11})
    end

    test "contains is a case-insensitive substring over the display string" do
      assert Filter.matches?(%{"op" => "contains", "value" => "PL"}, %{"v" => "apple"})
      assert Filter.matches?(%{"op" => "contains", "value" => "2"}, %{"v" => 1234})
      refute Filter.matches?(%{"op" => "contains", "value" => "z"}, %{"v" => "apple"})
    end

    # THE Excel semantics: a value criterion hides blank AND error rows, exactly
    # like a number filter — the CF-D5 matrix has blank/error never match a
    # value op, so the row falls out of `row_visible?`.
    test "value ops NEVER match a blank cell (blanks hidden like Excel)" do
      for op <- [
            %{"op" => "gt", "value" => 0},
            %{"op" => "lt", "value" => 100},
            %{"op" => "eq", "value" => 0},
            %{"op" => "between", "value" => 0, "value2" => 100},
            %{"op" => "contains", "value" => ""}
          ] do
        refute Filter.matches?(op, nil)
        refute Filter.matches?(op, %{"v" => ""})
      end
    end

    test "value ops NEVER match an error cell" do
      err = %{"v" => "#DIV/0!", "t" => "e"}
      refute Filter.matches?(%{"op" => "gt", "value" => 0}, err)
      refute Filter.matches?(%{"op" => "contains", "value" => "DIV"}, err)
    end

    # A criterion this module cannot understand fails OPEN — filter is
    # view-state, so an unknown op must never make a viewer's data vanish.
    test "an unknown criterion never hides a row (fail-open)" do
      assert Filter.matches?(%{"op" => "wat"}, %{"v" => 5})
      assert Filter.matches?(%{"op" => "wat"}, nil)
      assert Filter.matches?("garbage", %{"v" => 5})
    end
  end

  describe "row_visible?/5 — the AND across columns + the always-visible bands" do
    # A (col 1), B (col 2) over rows 2..3; used_rows = 3, no frozen band.
    @cells %{
      "A2" => %{"v" => 5},
      "B2" => %{"v" => "keep"},
      "A3" => %{"v" => 1},
      "B3" => %{"v" => "drop"}
    }

    test "empty criteria → every row visible (the no-filter fast path)" do
      assert Filter.row_visible?(2, %{}, @cells, 3, 0)
      assert Filter.row_visible?(3, %{}, @cells, 3, 0)
    end

    test "a single-column criterion filters data rows" do
      crit = %{1 => %{"op" => "gt", "value" => 3}}
      assert Filter.row_visible?(2, crit, @cells, 3, 0)
      refute Filter.row_visible?(3, crit, @cells, 3, 0)
    end

    test "multi-column criteria are ANDed — EVERY column must match" do
      crit = %{1 => %{"op" => "gt", "value" => 3}, 2 => %{"op" => "eq", "value" => "keep"}}
      # row 2: A2=5>3 AND B2==keep → visible.
      assert Filter.row_visible?(2, crit, @cells, 3, 0)
      # A row whose A matches but B does not is hidden.
      cells = Map.put(@cells, "B2", %{"v" => "other"})
      refute Filter.row_visible?(2, crit, cells, 3, 0)
    end

    test "the growth padding (row > used_rows) is ALWAYS visible" do
      crit = %{1 => %{"op" => "gt", "value" => 1000}}
      # Row 3 is a data row and fails → hidden; row 4 is past used_rows → visible.
      refute Filter.row_visible?(3, crit, @cells, 3, 0)
      assert Filter.row_visible?(4, crit, @cells, 3, 0)
      assert Filter.row_visible?(20, crit, @cells, 3, 0)
    end

    test "the frozen head band (row <= frozen_rows) is ALWAYS visible" do
      crit = %{1 => %{"op" => "nonblank"}}
      # A1 is blank and would fail nonblank, but row 1 is frozen head → visible.
      assert Filter.row_visible?(1, crit, @cells, 3, 1)
      # Row 2 is a data row below the freeze → the predicate applies.
      assert Filter.row_visible?(2, crit, @cells, 3, 1)
    end
  end

  describe "visible_rows/5" do
    test "filters a range down to the visible logical rows, ascending" do
      cells = %{"A2" => %{"v" => 5}, "A3" => %{"v" => 1}, "A4" => %{"v" => 9}}
      crit = %{1 => %{"op" => "gt", "value" => 3}}
      # used_rows 4, no freeze: row 1 (blank) & row 3 (=1) fail gt → hidden;
      # rows 2 & 4 match; rows 5–6 are past used_rows (padding) → visible.
      assert Filter.visible_rows(1..6, crit, cells, 4, 0) == [2, 4, 5, 6]
    end
  end
end
