defmodule BarkparkWeb.Studio.SheetGrid.GridDataTest do
  @moduledoc """
  Pure-unit coverage for `BarkparkWeb.Studio.SheetGrid.GridData` — the frozen
  band coercion in particular. No DB; `async: true`.
  """
  use ExUnit.Case, async: true

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
end
