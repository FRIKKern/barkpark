defmodule BarkparkWeb.Studio.SheetGrid.GeometryTest do
  @moduledoc """
  Pure-unit coverage for `BarkparkWeb.Studio.SheetGrid.Geometry`.
  No socket, no DB — `async: true`.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.SheetGrid.Geometry

  # Layout constants mirrored from the module for assertions
  @rowhead_px 44
  @headrow_px 25
  @default_col_px 88
  @default_row_px 24

  describe "selection_rect/2" do
    test "nil anchor produces a single-cell rect" do
      assert Geometry.selection_rect({3, 5}, nil) == {3, 3, 5, 5}
    end

    test "normalises reversed coordinates (anchor before cursor)" do
      # anchor col > cursor col, anchor row > cursor row
      assert Geometry.selection_rect({2, 3}, {5, 7}) == {2, 5, 3, 7}
      assert Geometry.selection_rect({5, 7}, {2, 3}) == {2, 5, 3, 7}
    end

    test "same cell for cursor and anchor yields single-cell rect" do
      assert Geometry.selection_rect({4, 4}, {4, 4}) == {4, 4, 4, 4}
    end
  end

  describe "grid_sel/3" do
    test "read_only=true always returns the zero sentinel rect" do
      assert Geometry.grid_sel({2, 3}, {5, 7}, true) == {0, 0, 0, 0}
    end

    test "read_only=false delegates to selection_rect" do
      assert Geometry.grid_sel({1, 1}, {3, 3}, false) == {1, 3, 1, 3}
    end
  end

  describe "grid_cursor/2" do
    test "read_only=true returns zero sentinel" do
      assert Geometry.grid_cursor({2, 5}, true) == {0, 0}
    end

    test "read_only=false returns the active cell unchanged" do
      assert Geometry.grid_cursor({4, 7}, false) == {4, 7}
    end
  end

  describe "data_edge/4" do
    # Excel Ctrl+Arrow semantics over the sparse A1-keyed cells map.
    # Column A holds the run A1..A3, a gap, then A5. Row 1 holds the run
    # A1..C1, a gap, then E1. Bounds are a 10x10 grid.
    @cells %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3},
      "A5" => %{"v" => 5},
      "B1" => %{"v" => "b"},
      "C1" => %{"v" => "c"},
      "E1" => %{"v" => "e"}
    }
    @bounds {10, 10}

    test "down: from inside a filled run, jump to the run's last cell before the gap" do
      assert Geometry.data_edge(@cells, {1, 1}, "down", @bounds) == {1, 3}
      assert Geometry.data_edge(@cells, {1, 2}, "down", @bounds) == {1, 3}
    end

    test "down: from a run's end, skip the gap to the next filled cell" do
      assert Geometry.data_edge(@cells, {1, 3}, "down", @bounds) == {1, 5}
    end

    test "down: from the last filled cell, clamp to the grid edge" do
      assert Geometry.data_edge(@cells, {1, 5}, "down", @bounds) == {1, 10}
    end

    test "down: from an empty cell, jump to the next filled cell" do
      # B5 is empty; nothing below in column B → edge. A4 (the gap) → A5.
      assert Geometry.data_edge(@cells, {1, 4}, "down", @bounds) == {1, 5}
      assert Geometry.data_edge(@cells, {2, 5}, "down", @bounds) == {2, 10}
    end

    test "up: run walk, gap skip, and edge clamp mirror the down cases" do
      assert Geometry.data_edge(@cells, {1, 5}, "up", @bounds) == {1, 3}
      assert Geometry.data_edge(@cells, {1, 3}, "up", @bounds) == {1, 1}
      assert Geometry.data_edge(@cells, {1, 1}, "up", @bounds) == {1, 1}
      # Empty B9 → the next filled cell upward is B1.
      assert Geometry.data_edge(@cells, {2, 9}, "up", @bounds) == {2, 1}
    end

    test "right: run walk, gap skip, and edge clamp" do
      assert Geometry.data_edge(@cells, {1, 1}, "right", @bounds) == {3, 1}
      assert Geometry.data_edge(@cells, {3, 1}, "right", @bounds) == {5, 1}
      assert Geometry.data_edge(@cells, {5, 1}, "right", @bounds) == {10, 1}
      # Empty D1 (the gap) → E1.
      assert Geometry.data_edge(@cells, {4, 1}, "right", @bounds) == {5, 1}
    end

    test "left: run walk, gap skip, and edge clamp" do
      assert Geometry.data_edge(@cells, {5, 1}, "left", @bounds) == {3, 1}
      assert Geometry.data_edge(@cells, {3, 1}, "left", @bounds) == {1, 1}
      assert Geometry.data_edge(@cells, {1, 1}, "left", @bounds) == {1, 1}
      # Empty row 7 → nothing leftward → col 1.
      assert Geometry.data_edge(@cells, {8, 7}, "left", @bounds) == {1, 7}
    end

    test "already at the grid edge stays put in every direction" do
      assert Geometry.data_edge(@cells, {1, 10}, "down", @bounds) == {1, 10}
      assert Geometry.data_edge(@cells, {10, 1}, "right", @bounds) == {10, 1}
      assert Geometry.data_edge(@cells, {1, 1}, "up", @bounds) == {1, 1}
      assert Geometry.data_edge(@cells, {1, 1}, "left", @bounds) == {1, 1}
    end

    test "a two-cell run ending at the grid edge walks onto the edge cell" do
      cells = %{"A9" => %{"v" => 1}, "A10" => %{"v" => 2}}
      assert Geometry.data_edge(cells, {1, 9}, "down", {10, 10}) == {1, 10}
    end

    test "an empty grid jumps straight to the edge" do
      assert Geometry.data_edge(%{}, {3, 3}, "down", @bounds) == {3, 10}
      assert Geometry.data_edge(%{}, {3, 3}, "up", @bounds) == {3, 1}
      assert Geometry.data_edge(%{}, {3, 3}, "left", @bounds) == {1, 3}
      assert Geometry.data_edge(%{}, {3, 3}, "right", @bounds) == {10, 3}
    end
  end

  describe "parse_range/1" do
    test "valid A1:C3 range returns normalised tuple" do
      assert {:ok, {1, 1, 3, 3}} = Geometry.parse_range("A1:C3")
    end

    test "reversed range is normalised (larger cell first)" do
      # C3:A1 should give same result as A1:C3
      assert {:ok, {1, 1, 3, 3}} = Geometry.parse_range("C3:A1")
    end

    test "non-string input returns :error" do
      assert :error = Geometry.parse_range(nil)
      assert :error = Geometry.parse_range(42)
    end

    test "malformed string returns :error" do
      assert :error = Geometry.parse_range("not-a-range")
      assert :error = Geometry.parse_range("A1")
    end
  end

  describe "col_px/2 and row_px/2" do
    test "returns custom width when present in map" do
      assert Geometry.col_px(%{"2" => 120}, 2) == 120
    end

    test "falls back to default when key missing" do
      assert Geometry.col_px(%{}, 1) == @default_col_px
    end

    test "falls back to default for zero/negative values" do
      assert Geometry.col_px(%{"1" => 0}, 1) == @default_col_px
      assert Geometry.row_px(%{"1" => -5}, 1) == @default_row_px
    end

    test "row_px returns default when map is empty" do
      assert Geometry.row_px(%{}, 3) == @default_row_px
    end
  end

  describe "left_px/2 and top_px/2" do
    test "column 1 has left = rowhead offset (no preceding columns)" do
      assert Geometry.left_px(1, %{}) == @rowhead_px
    end

    test "column 3 sums preceding two default-width columns plus rowhead" do
      expected = @rowhead_px + @default_col_px + @default_col_px
      assert Geometry.left_px(3, %{}) == expected
    end

    test "row 1 has top = headrow offset (no preceding rows)" do
      assert Geometry.top_px(1, %{}) == @headrow_px
    end

    test "custom col widths are included in left_px sum" do
      # col 1 = 50, col 2 = 70 → left_px(3) = 44 + 50 + 70
      assert Geometry.left_px(3, %{"1" => 50, "2" => 70}) == 44 + 50 + 70
    end
  end

  describe "col_letters/1" do
    test "single-letter columns A-Z" do
      assert Geometry.col_letters(1) == "A"
      assert Geometry.col_letters(26) == "Z"
    end

    test "two-letter columns beyond Z" do
      assert Geometry.col_letters(27) == "AA"
      assert Geometry.col_letters(52) == "AZ"
      assert Geometry.col_letters(53) == "BA"
    end
  end

  describe "rgba/2" do
    test "converts hex colour and alpha to rgba string" do
      assert Geometry.rgba("#ff0000", 0.5) == "rgba(255, 0, 0, 0.5)"
      assert Geometry.rgba("#1a2b3c", 1) == "rgba(26, 43, 60, 1)"
    end
  end
end
