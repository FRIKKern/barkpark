defmodule Barkpark.Plugins.Sheets.ChartsTest do
  @moduledoc """
  Charts on a sheet tab: the `set_chart` / `delete_chart` session ops and
  their undo, how a row/column edit moves a chart's range, what the gate
  refuses, and what a chart reads from the cells.

  No session process: `Session.Ops.apply_one/2` is a state-map transform. It
  needs the DB only because the delta broadcast resolves its topic there.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Plugins.Sheets.Charts
  alias Barkpark.Plugins.Sheets.Session.Ops

  @user "u1"

  defp n(v), do: %{"v" => v}

  defp cells do
    %{
      "A1" => n("Month"),
      "B1" => n("Sales"),
      "C1" => n("Cost"),
      "A2" => n("Jan"),
      "B2" => n(10),
      "C2" => n(4),
      "A3" => n("Feb"),
      "B3" => n(20),
      "C3" => n(5),
      "A4" => n("Mar"),
      "B4" => n(30),
      "C4" => n("n/a")
    }
  end

  defp state do
    content = %{"tabs" => [%{"name" => "Sheet 1", "cells" => cells()}]}

    %{
      slug: "charts-test-#{System.unique_integer([:positive])}",
      dataset: "test",
      workspace_id: nil,
      project_id: nil,
      content: content,
      rev: 0,
      epoch: 1,
      dirty?: false,
      ops_since_flush: 0,
      dirty_tabs: %{},
      nonempty: Ops.count_nonempty(content),
      formula_counts: Ops.count_formulas(content),
      cross_tab_index: Ops.build_cross_tab_index(content),
      undo: %{},
      redo: %{},
      cfg: %{cell_cap: 100_000}
    }
  end

  # One op as one user gesture, the way the session's batch loop records it.
  defp run(state, op) do
    op = Map.put(op, "user", @user)
    {:ok, state, inverse} = Ops.apply_one(op, state)
    Ops.record_batch_undo(state, [{op, inverse}])
  end

  defp history(state, kind) do
    {:ok, state, nil} = Ops.apply_one(%{"op" => kind, "user" => @user}, state)
    state
  end

  defp charts(state), do: state.content |> Map.fetch!("tabs") |> hd() |> Charts.list()

  defp set(range, extra \\ %{}) do
    %{
      "op" => "set_chart",
      "tab" => 0,
      "chart" => Map.merge(%{"range" => range, "type" => "line"}, extra)
    }
  end

  test "set_chart stores a chart; undo removes it; redo restores it" do
    state = run(state(), set("a1:c4", %{"title" => " Sales "}))

    assert [
             %{
               "id" => "ch-1",
               "range" => "A1:C4",
               "type" => "line",
               "title" => "Sales",
               "headers" => true,
               "labels" => true
             } = chart
           ] = charts(state)

    assert charts(history(state, "undo")) == []
    assert charts(state |> history("undo") |> history("redo")) == [chart]

    # An edit replaces in place and undoes to the prior chart; delete undoes too.
    edited = run(state, set("A1:B4", %{"id" => "ch-1", "type" => "bar"}))
    assert [%{"range" => "A1:B4", "type" => "bar"}] = charts(edited)
    assert charts(history(edited, "undo")) == [chart]

    deleted = run(state, %{"op" => "delete_chart", "tab" => 0, "id" => "ch-1"})
    assert charts(deleted) == []
    assert charts(history(deleted, "undo")) == [chart]
  end

  test "a row insert above shifts the range; a column delete inside shrinks it; undo restores" do
    state = run(state(), set("A1:C4"))

    shifted = run(state, %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2})
    assert [%{"range" => "A3:C6"}] = charts(shifted)

    shrunk = run(shifted, %{"op" => "delete_cols", "tab" => 0, "at" => 2, "count" => 1})
    assert [%{"range" => "A3:B6"}] = charts(shrunk)
    assert [%{"range" => "A3:C6"}] = charts(history(shrunk, "undo"))

    # Deleting every row the chart reads removes the chart; undo brings it back.
    gone = run(shifted, %{"op" => "delete_rows", "tab" => 0, "at" => 3, "count" => 4})
    assert charts(gone) == []
    assert [%{"id" => "ch-1", "range" => "A3:C6"}] = charts(history(gone, "undo"))
    assert charts(gone |> history("undo") |> history("redo")) == []
  end

  test "refuses a range outside the sheet, an unknown type, an oversized range and a 21st chart" do
    refused = fn op -> Ops.apply_one(op, state()) end

    assert {:error, "invalid_chart", outside} = refused.(set("A1:XFE5"))
    assert outside =~ "outside the sheet"
    assert {:error, "invalid_chart", _} = refused.(set("nope"))
    assert {:error, "invalid_chart", type} = refused.(set("A1:B2", %{"type" => "pie"}))
    assert type =~ "type must be one of"
    assert {:error, "invalid_chart", big} = refused.(set("A1:Z500"))
    assert big =~ "at most #{Charts.area_cap()}"
    assert {:error, "invalid_chart", _} = refused.(set("A1:B2", %{"script" => "x"}))
    assert {:error, "tab_not_found", _} = refused.(Map.put(set("A1:B2"), "tab", 7))

    assert {:error, "chart_not_found", _} =
             refused.(%{"op" => "delete_chart", "tab" => 0, "id" => "x"})

    full = Enum.reduce(1..Charts.chart_cap(), state(), fn _, st -> run(st, set("A1:B2")) end)
    assert length(charts(full)) == Charts.chart_cap()
    assert {:error, "invalid_chart", cap} = Ops.apply_one(set("A1:B2"), full)
    assert cap =~ "at most #{Charts.chart_cap()}"

    # The save gate speaks the same rules.
    assert Charts.list_errors([%{"id" => "a", "range" => "A1:B2", "type" => "line"}], 0) == []
    assert [_] = Charts.list_errors([%{"id" => "a", "range" => "A1:B2", "type" => "pie"}], 0)
    assert [_] = Charts.list_errors("charts", 0)
  end

  defp tall_state(rows) do
    cells = for r <- 1..rows, c <- ["A", "B"], into: %{}, do: {"#{c}#{r}", n(r)}
    st = state()
    content = %{"tabs" => [%{"name" => "Sheet 1", "cells" => cells}]}
    %{st | content: content, nonempty: Ops.count_nonempty(content)}
  end

  defp tab_cells(state), do: state.content |> Map.fetch!("tabs") |> hd() |> Map.fetch!("cells")

  test "undo of a row delete brings the rows back when the chart sits at the cell cap" do
    state = run(tall_state(1001), set("A1:B1000"))

    # An insert inside would grow the range to 2,006 cells: its end is trimmed.
    grown = run(state, %{"op" => "insert_rows", "tab" => 0, "at" => 5, "count" => 3})
    assert [%{"range" => "A1:B1000"} = chart] = charts(grown)
    assert Charts.list_errors(charts(grown), 0) == []

    deleted = run(grown, %{"op" => "delete_rows", "tab" => 0, "at" => 10, "count" => 1})
    assert [%{"range" => "A1:B999"}] = charts(deleted)
    refute tab_cells(deleted) == tab_cells(grown)

    undone = history(deleted, "undo")
    assert tab_cells(undone) == tab_cells(grown)
    assert charts(undone) == [chart]
    assert charts(history(undone, "redo")) == charts(deleted)

    # The insert undoes exactly too, and the chart can still be changed.
    back = undone |> history("undo")
    assert tab_cells(back) == tab_cells(state)
    assert charts(back) == charts(state)

    assert [%{"title" => "t"}] =
             charts(run(grown, set("A1:B1000", %{"id" => "ch-1", "title" => "t"})))

    gone = run(grown, %{"op" => "delete_chart", "tab" => 0, "id" => "ch-1"})
    assert charts(history(gone, "undo")) == [chart]
  end

  test "undo of a row delete brings the rows back when the tab is full of charts again" do
    state = run(tall_state(30), set("A20:B22"))
    full = Enum.reduce(1..19, state, fn _, st -> run(st, set("A1:B2")) end)
    assert length(charts(full)) == 20

    deleted = run(full, %{"op" => "delete_rows", "tab" => 0, "at" => 20, "count" => 3})
    assert length(charts(deleted)) == 19
    {:ok, refilled, _} = Ops.apply_one(Map.put(set("A1:B3"), "user", "someone-else"), deleted)

    # The rows come back; the chart has no room, so it is the part left out.
    undone = history(refilled, "undo")
    assert tab_cells(undone) == tab_cells(full)
    assert length(charts(undone)) == 20
    refute Enum.any?(charts(undone), &(&1["id"] == "ch-1"))
  end

  test "a generated id is never handed out twice on a tab" do
    state = run(state(), set("A1:B2", %{"title" => "mine"}))
    deleted = run(state, %{"op" => "delete_chart", "tab" => 0, "id" => "ch-1"})

    {:ok, other, _} =
      Ops.apply_one(Map.put(set("A1:C4", %{"title" => "theirs"}), "user", "u2"), deleted)

    assert [%{"id" => "ch-2", "title" => "theirs"}] = charts(other)

    # My undo puts my chart back beside theirs, not over it.
    assert [%{"id" => "ch-1", "title" => "mine"}, %{"id" => "ch-2", "title" => "theirs"}] =
             charts(history(other, "undo"))
  end

  test "reading stored charts is total: junk is dropped, never raised on" do
    good = %{"id" => "a", "range" => "A1:B2", "type" => "line"}

    for junk <- [
          "charts",
          %{"a" => 1},
          5,
          [1, "x", nil, [], %{}],
          [%{"id" => %{}}],
          [%{"id" => "a", "range" => %{}, "type" => "line"}],
          [%{"id" => "a", "range" => "A1:B2", "type" => %{}}],
          [%{"id" => [1], "range" => "A1", "type" => "bar", "title" => %{}}]
        ] do
      tab = %{"cells" => cells(), "charts" => junk}
      assert Charts.list(tab) == []
      assert BarkparkWeb.Studio.SheetGrid.Charts.views(tab) == []
      assert %{"tabs" => [%{"charts" => []}]} = Charts.clean_content(%{"tabs" => [tab]})
    end

    # Good entries survive beside junk; a repeated id and the 21st are dropped;
    # a range over the cell cap is trimmed, and the gate refuses it untrimmed.
    many = for i <- 1..30, do: Map.put(good, "id", "c#{i}")
    assert length(Charts.list(%{"charts" => [%{"id" => %{}}, good, good | many]})) == 20
    big = Map.put(good, "range", "A1:Z5000")
    assert [%{"range" => "A1:Z76"}] = Charts.list(%{"charts" => [big]})
    assert [error] = Charts.list_errors([big], 0)
    assert error =~ "at most 2000"

    assert Charts.clean_content(%{"tabs" => [%{"name" => "t"}]}) == %{
             "tabs" => [%{"name" => "t"}]
           }
  end

  test "a duplicated tab keeps its charts; exports and the snapshot ignore them" do
    state = run(state(), set("A1:C4"))
    copied = run(state, %{"op" => "duplicate_tab", "tab" => 0})
    assert [%{"charts" => [chart]}, %{"charts" => [chart]}] = copied.content["tabs"]

    removed = run(copied, %{"op" => "delete_tab", "tab" => 1})
    assert [%{"charts" => [^chart]}] = removed.content["tabs"]

    assert {:ok, xlsx} = Barkpark.Plugins.Sheets.XlsxExport.to_binary(state.content)
    assert is_binary(xlsx)
    assert {:ok, "Month,Sales,Cost" <> _} = Barkpark.Plugins.Sheets.Csv.export(state.content)
    assert %{"rows" => [_ | _]} = Barkpark.Plugins.Sheets.Core.snapshot_for(state.content, 0)
  end

  test "data skips cells that are not numbers and says when nothing is" do
    chart = %{"range" => "A1:C4", "headers" => true, "labels" => true}

    # C4 is text: the Mar row is left out for both series, never drawn as zero.
    assert %{
             state: :ok,
             series: [%{label: "Sales", points: [10, 20]}, %{label: "Cost", points: [4, 5]}],
             labels: ["Jan", "Feb"],
             skipped: 1,
             table: [["Month", "Sales", "Cost"], ["Jan", "10", "4"], ["Feb", "20", "5"]]
           } = Charts.data(chart, cells())

    assert %{state: :no_numbers, series: []} = Charts.data(%{"range" => "A1:A4"}, cells())
    assert %{state: :bad_range} = Charts.data(%{"range" => nil}, cells())

    # Without the toggles the header row is data: B1 is text, so row 1 drops.
    assert %{series: [%{label: "B", points: [10, 20, 30]}], labels: []} =
             Charts.data(%{"range" => "B1:B4", "headers" => false, "labels" => false}, cells())
  end
end
