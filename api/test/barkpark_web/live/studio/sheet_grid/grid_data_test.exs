defmodule BarkparkWeb.Studio.SheetGrid.GridDataTest do
  @moduledoc """
  Pure-unit coverage for `BarkparkWeb.Studio.SheetGrid.GridData` — the frozen
  band coercion in particular. No DB; `async: true`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.CondFormat
  alias BarkparkWeb.Studio.SheetGrid.GridData

  describe "clamp_frozen/2" do
    test "positive integer clamps to the limit" do
      assert GridData.clamp_frozen(2, 10) == 2
      assert GridData.clamp_frozen(20, 10) == 10
    end

    test "zero / negative / non-frozen inputs collapse to 0" do
      assert GridData.clamp_frozen(0, 10) == 0
      assert GridData.clamp_frozen(-3, 10) == 0
      assert GridData.clamp_frozen(nil, 10) == 0
    end

    # The schema/document-editor path persists the frozen band as a STRING;
    # every other reader (Core, XlsxExport, Structure) Integer.parses it, so
    # Studio must coerce it too or it hides a real freeze.
    test "a string frozen band parses like the other readers" do
      assert GridData.clamp_frozen("2", 10) == 2
      assert GridData.clamp_frozen("20", 10) == 10
    end

    test "a non-positive or non-numeric string collapses to 0" do
      assert GridData.clamp_frozen("0", 10) == 0
      assert GridData.clamp_frozen("-1", 10) == 0
      assert GridData.clamp_frozen("2x", 10) == 0
      assert GridData.clamp_frozen("", 10) == 0
    end
  end

  describe "derive_grid/1 frozen band" do
    # Protective: a sheet saved with a string frozen_rows ("2") — the shape the
    # document editor / raw API persist — must surface as an integer 2 in the
    # grid assigns, matching reader/exports. Fails on the pre-fix is_integer-only
    # clause (which drops it to 0).
    test "seeds a string frozen_rows/frozen_cols into integer assigns" do
      content = %{
        "tabs" => [
          %{
            "name" => "Sheet 1",
            "cells" => %{"A1" => %{"v" => 1}},
            "frozen_rows" => "2",
            "frozen_cols" => "1"
          }
        ]
      }

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(content: content, tab: 0)
        |> GridData.derive_grid()

      assert socket.assigns.frozen_rows == 2
      assert socket.assigns.frozen_cols == 1
    end
  end

  @grid %{
    "tabs" => [
      %{
        "name" => "S",
        "cells" => %{
          "A1" => %{"v" => 5},
          "A2" => %{"v" => 1},
          "A3" => %{"v" => 9},
          "A4" => %{"v" => 2}
        }
      }
    ]
  }

  defp derive(content, extra \\ %{}) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(Map.merge(%{content: content, tab: 0}, extra))
    |> GridData.derive_grid()
  end

  describe "derive_grid/1 visible_rows (SF-B filter pipeline)" do
    test "no filter → visible_rows is the full contiguous window (byte-identical)" do
      socket = derive(@grid)
      # used_rows 4 → rows = max(6, 20) = 20; the whole window renders, none hidden.
      assert socket.assigns.visible_rows == Enum.to_list(socket.assigns.row_range)
      assert socket.assigns.visible_rows == Enum.to_list(1..20)
      refute socket.assigns.filter_active
      assert socket.assigns.filter_hidden_count == 0
      assert socket.assigns.visible_first == 1
      assert socket.assigns.visible_last == 20
    end

    test "an active filter drops the non-matching DATA rows, keeps the padding" do
      socket = derive(@grid, %{filters: %{1 => %{"op" => "gt", "value" => 3}}})
      # A1=5 & A3=9 match; A2=1 & A4=2 fail; rows 5–20 are padding (always shown).
      assert socket.assigns.visible_rows == [1, 3] ++ Enum.to_list(5..20)
      assert socket.assigns.filter_active
      # The two failing DATA rows (2 and 4) are hidden.
      assert socket.assigns.filter_hidden_count == 2
    end

    test "the page window COUNTS visible rows, not logical rows (SF-D8)" do
      # 1200 data rows, only every 100th is > 0 so 12 match — but the padding
      # rows past used_rows are always visible, so pin the count instead: a
      # filter that hides most rows still slices <=500 VISIBLE rows per page.
      cells = for r <- 1..1200, into: %{}, do: {"A#{r}", %{"v" => rem(r, 2)}}
      content = %{"tabs" => [%{"name" => "S", "cells" => cells}]}

      # Keep only rows whose A is 0 (600 of the 1200 data rows) + padding.
      socket = derive(content, %{filters: %{1 => %{"op" => "eq", "value" => 0}}})

      # Page 0 fills with 500 VISIBLE rows (not 500 logical rows).
      assert length(socket.assigns.visible_rows) == 500
      assert socket.assigns.page_next?
      # Every rendered row actually passes the filter or is padding.
      assert Enum.all?(socket.assigns.visible_rows, fn r -> rem(r, 2) == 0 or r > 1200 end)
    end

    test "no-filter core assigns are unchanged by the filter plumbing" do
      socket = derive(@grid)
      # The historical logical-paging assigns still hold their old meaning.
      assert socket.assigns.row_range == 1..20
      assert socket.assigns.row_page_end == 20
      assert socket.assigns.rows == 20
      refute socket.assigns.page_next?
    end
  end

  describe "cf_styles/2 — live-grid conditional-format projection (CF-C stage A)" do
    test "projects only OCCUPIED matching cells via the ONE kernel (CF-D8)" do
      rules =
        CondFormat.parse_rules([
          %{
            "id" => "r1",
            "range" => "A1:A4",
            "when" => %{"op" => "gt", "value" => 10},
            "style" => %{"bg" => "#ff0000"}
          }
        ])

      cells = %{"A1" => %{"v" => 5}, "A2" => %{"v" => 20}, "A3" => %{"v" => 50}}
      styles = GridData.cf_styles(rules, cells)

      # A1 (5) doesn't match; A2/A3 do; A4 is blank (occupied-only, no entry).
      refute Map.has_key?(styles, {1, 1})
      assert styles[{1, 2}] == %{"bg" => "#ff0000"}
      assert styles[{1, 3}] == %{"bg" => "#ff0000"}
      refute Map.has_key?(styles, {1, 4})
    end

    test "empty rules → empty map (byte-identical no-CF default)" do
      assert GridData.cf_styles([], %{"A1" => %{"v" => 1}}) == %{}
    end

    test "first-match-wins under overlapping same-range rules (kernel priority)" do
      rules =
        CondFormat.parse_rules([
          %{
            "id" => "r1",
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 0},
            "style" => %{"bg" => "#111111"}
          },
          %{
            "id" => "r2",
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 0},
            "style" => %{"bg" => "#222222"}
          }
        ])

      assert GridData.cf_styles(rules, %{"A1" => %{"v" => 9}}) == %{
               {1, 1} => %{"bg" => "#111111"}
             }
    end
  end

  describe "derive_grid/1 conditional formatting" do
    test "derives cf_styles occupied-only and carries the raw rules for the panel" do
      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{"B2" => %{"v" => 200}, "B3" => %{"v" => 1}},
            "cond_formats" => [
              %{
                "id" => "r1",
                "range" => "B2:B3",
                "when" => %{"op" => "gt", "value" => 100},
                "style" => %{"bg" => "#ff0000"}
              }
            ]
          }
        ]
      }

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(content: content, tab: 0)
        |> GridData.derive_grid()

      assert socket.assigns.cf_styles == %{{2, 2} => %{"bg" => "#ff0000"}}
      assert [%{"id" => "r1"}] = socket.assigns.cf_rules
    end

    test "malformed cond_formats yields an empty cf_styles map and never raises" do
      content = %{
        "tabs" => [
          %{"name" => "S", "cells" => %{"A1" => %{"v" => 1}}, "cond_formats" => "garbage"}
        ]
      }

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(content: content, tab: 0)
        |> GridData.derive_grid()

      assert socket.assigns.cf_styles == %{}
      # A non-list stored value collapses to [] so the panel's :for never faults.
      assert socket.assigns.cf_rules == []
    end

    test "non-map entries inside a stored rules LIST are dropped from cf_rules" do
      # The panel reads rule["id"]/["when"]/["style"] per row and Access raises
      # on a non-map — a gate-bypassed bare-string entry must degrade, not
      # crash the render. Valid map entries around it survive.
      valid = %{
        "id" => "r1",
        "range" => "A1",
        "when" => %{"op" => "gt", "value" => 0},
        "style" => %{"bg" => "#ff0000"}
      }

      content = %{
        "tabs" => [
          %{
            "name" => "S",
            "cells" => %{"A1" => %{"v" => 1}},
            "cond_formats" => ["garbage", valid, 42]
          }
        ]
      }

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(content: content, tab: 0)
        |> GridData.derive_grid()

      assert socket.assigns.cf_rules == [valid]
      # The kernel path was already total: only the valid rule paints.
      assert socket.assigns.cf_styles == %{{1, 1} => %{"bg" => "#ff0000"}}
    end
  end
end
