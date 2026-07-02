defmodule BarkparkWeb.Studio.SheetGrid.CellsTest do
  @moduledoc """
  Pure-unit coverage for `BarkparkWeb.Studio.SheetGrid.Cells`.
  No socket, no DB — `async: true`.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.SheetGrid.Cells

  describe "display/1" do
    test "boolean true renders as 'TRUE'" do
      assert Cells.display(%{"v" => true}) == "TRUE"
    end

    test "boolean false renders as 'FALSE'" do
      assert Cells.display(%{"v" => false}) == "FALSE"
    end

    test "integer value converts to string" do
      assert Cells.display(%{"v" => 42}) == "42"
    end

    test "float value converts to string" do
      assert Cells.display(%{"v" => 3.14}) == "3.14"
    end

    test "whole float renders integral (no scientific notation)" do
      # to_string(1_000_000.0) == "1.0e6"; the shared formatter keeps it plain.
      assert Cells.display(%{"v" => 1_000_000.0}) == "1000000"
    end

    test "non-whole floats keep their decimals" do
      assert Cells.display(%{"v" => 0.1}) == "0.1"
      assert Cells.display(%{"v" => 1.5}) == "1.5"
      assert Cells.display(%{"v" => -2.5}) == "-2.5"
      assert Cells.display(%{"v" => 123_456_789.123}) == "123456789.123"
      refute Cells.display(%{"v" => 123_456_789.123}) =~ "e"
    end

    test "extreme magnitudes keep exponent form, like Excel General" do
      assert Cells.display(%{"v" => 1.0e-7}) =~ "e"
      assert Cells.display(%{"v" => 1.0e21}) =~ "e"
    end

    test "binary value is returned as-is" do
      assert Cells.display(%{"v" => "hello"}) == "hello"
    end

    test "nil cell returns empty string" do
      assert Cells.display(nil) == ""
    end

    test "empty map returns empty string" do
      assert Cells.display(%{}) == ""
    end

    test "cell with no 'v' key returns empty string" do
      assert Cells.display(%{"f" => "A1+B1"}) == ""
    end
  end

  describe "raw_of/1" do
    test "cell with formula returns '=' prefix followed by formula" do
      assert Cells.raw_of(%{"f" => "A1+B1"}) == "=A1+B1"
    end

    test "formula already starting with '=' is not double-prefixed" do
      assert Cells.raw_of(%{"f" => "=SUM(A1:A5)"}) == "=SUM(A1:A5)"
    end

    test "cell without formula falls through to display" do
      assert Cells.raw_of(%{"v" => "text"}) == "text"
    end

    test "nil cell falls through to display (empty string)" do
      assert Cells.raw_of(nil) == ""
    end
  end

  describe "fmt raw/display split" do
    # A fmt cell: the visible display formats, but the formula bar (raw_of)
    # and the TSV clipboard (data_v) both round-trip the RAW value so an edit
    # or a paste never sees "25.00%".
    @pct %{"v" => 0.25, "fmt" => "percent"}

    test "display/1 renders the fmt class" do
      assert Cells.display(@pct) == "25.00%"
    end

    test "raw_of/1 returns the raw value, not the formatted display" do
      assert Cells.raw_of(@pct) == "0.25"
    end

    test "data_v/1 returns the raw value for TSV copy" do
      assert Cells.data_v(@pct) == "0.25"
    end

    test "display, raw_of and data_v diverge exactly on a fmt cell" do
      assert Cells.display(@pct) == "25.00%"
      assert Cells.raw_of(@pct) == "0.25"
      assert Cells.data_v(@pct) == "0.25"
    end

    test "a no-fmt float: all three agree with number_to_display" do
      cell = %{"v" => 1_000_000.0}
      expected = Barkpark.Plugins.Sheets.Core.number_to_display(1_000_000.0)
      assert expected == "1000000"
      assert Cells.display(cell) == expected
      assert Cells.raw_of(cell) == expected
      assert Cells.data_v(cell) == expected
    end

    test "a formula fmt cell: display formats, data_v is the raw value, raw_of is the formula" do
      cell = %{"f" => "=A1*B1", "v" => 0.25, "fmt" => "percent"}
      assert Cells.display(cell) == "25.00%"
      assert Cells.data_v(cell) == "0.25"
      assert Cells.raw_of(cell) == "=A1*B1"
    end
  end

  describe "bar_value/2" do
    test "returns raw value of the active cell from the cells map" do
      cells = %{"A1" => %{"v" => "hello"}}
      assert Cells.bar_value(cells, {1, 1}) == "hello"
    end

    test "returns formula string when cell has formula" do
      cells = %{"B2" => %{"f" => "SUM(A1:A5)"}}
      assert Cells.bar_value(cells, {2, 2}) == "=SUM(A1:A5)"
    end

    test "returns empty string when active cell is not in map" do
      assert Cells.bar_value(%{}, {1, 1}) == ""
    end
  end

  describe "cell_class/5" do
    # selection rect {c1, c2, r1, r2}
    test "plain cell has only 'sheet-cell' class" do
      assert Cells.cell_class(5, 5, {1, 3, 1, 3}, {9, 9}, nil) == "sheet-cell"
    end

    test "cell within selection rect gets 'sheet-sel' class" do
      result = Cells.cell_class(2, 2, {1, 3, 1, 3}, {9, 9}, nil)
      assert result =~ "sheet-sel"
      assert result =~ "sheet-cell"
    end

    test "active cell gets 'sheet-active' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {1, 1}, nil)
      assert result =~ "sheet-active"
    end

    test "cell with engine error value gets 'sheet-err' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "#VALUE!"})
      assert result =~ "sheet-err"
    end

    test "cell with #N/A error value gets 'sheet-err' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "#N/A"})
      assert result =~ "sheet-err"
    end

    test "cell with stale flag gets 'sheet-stale' class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"stale" => true})
      assert result =~ "sheet-stale"
    end

    test "normal string value does not get err class" do
      result = Cells.cell_class(1, 1, {5, 6, 5, 6}, {9, 9}, %{"v" => "hello"})
      refute result =~ "sheet-err"
    end
  end

  describe "cell_dom_id/2" do
    test "builds a stable per-cell id from the table id and the {c, r}" do
      assert Cells.cell_dom_id("sheet-grid-q3", {2, 5}) == "sheet-grid-q3-cell-2-5"
    end

    test "the active cell id matches the id stamped on that cell" do
      assert Cells.cell_dom_id("t", {1, 1}) == "t-cell-1-1"
    end
  end

  describe "aria_selected/3" do
    # sel rect is {c1, c2, r1, r2} — the same shape cell_class consumes.
    test "cell inside the sel rect is aria-selected true" do
      assert Cells.aria_selected({1, 3, 1, 3}, 2, 2) == "true"
    end

    test "cell on the sel-rect boundary is aria-selected true" do
      assert Cells.aria_selected({1, 3, 1, 3}, 3, 1) == "true"
    end

    test "cell outside the sel rect is aria-selected false" do
      assert Cells.aria_selected({1, 3, 1, 3}, 5, 5) == "false"
    end

    test "nil sel is aria-selected false (never crashes)" do
      assert Cells.aria_selected(nil, 1, 1) == "false"
    end

    test "shares cell_class's predicate: aria_selected true iff sheet-sel present" do
      sel = {2, 4, 2, 4}

      for c <- 1..6, r <- 1..6 do
        selected? = Cells.cell_class(c, r, sel, {0, 0}, nil) =~ "sheet-sel"
        assert Cells.aria_selected(sel, c, r) == if(selected?, do: "true", else: "false")
      end
    end
  end

  describe "cell_style/7" do
    test "non-frozen cell with no inline style returns nil" do
      assert Cells.cell_style(3, 3, 0, 0, %{}, %{}, nil) == nil
    end

    test "frozen column cell gets sticky left style" do
      style = Cells.cell_style(1, 3, 1, 0, %{}, %{}, nil)
      assert is_binary(style)
      assert style =~ "position: sticky"
      assert style =~ "left:"
    end

    test "frozen row cell gets sticky top style" do
      style = Cells.cell_style(3, 1, 0, 1, %{}, %{}, nil)
      assert is_binary(style)
      assert style =~ "position: sticky"
      assert style =~ "top:"
    end

    test "corner cell (frozen col + row) gets both left and top" do
      style = Cells.cell_style(1, 1, 1, 1, %{}, %{}, nil)
      assert style =~ "left:"
      assert style =~ "top:"
      assert style =~ "z-index: 2"
    end

    test "cell with bold style appends font-weight" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"b" => true}})
      assert style =~ "font-weight: 600"
    end

    test "cell with valid hex background gets background style" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"bg" => "#ff0000"}})
      assert style =~ "background: #ff0000"
    end

    test "cell with invalid hex background is ignored" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"bg" => "red"}})
      assert style == nil
    end

    test "cell with text-align returns alignment style" do
      style = Cells.cell_style(3, 3, 0, 0, %{}, %{}, %{"s" => %{"al" => "center"}})
      assert style =~ "text-align: center"
    end
  end

  describe "col_head_style/3" do
    test "frozen column returns sticky left style string" do
      style = Cells.col_head_style(1, 2, %{})
      assert is_binary(style)
      assert style =~ "left:"
      assert style =~ "z-index: 5"
    end

    test "non-frozen column returns nil" do
      assert Cells.col_head_style(5, 2, %{}) == nil
    end
  end

  describe "row_head_style/3" do
    test "frozen row returns sticky top style string" do
      style = Cells.row_head_style(1, 2, %{})
      assert is_binary(style)
      assert style =~ "top:"
      assert style =~ "z-index: 5"
    end

    test "non-frozen row returns nil" do
      assert Cells.row_head_style(5, 2, %{}) == nil
    end
  end
end
