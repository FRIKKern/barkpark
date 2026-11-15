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
