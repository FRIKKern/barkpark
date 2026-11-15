defmodule BarkparkWeb.Studio.SheetGrid.ChartsLiveTest do
  @moduledoc """
  Charts in the Studio sheet grid, end to end on one live sheet: insert a
  chart from the selected cells, see it redraw when a cell in its range
  changes (this editor's edit, a formula, and another writer's op), see it on
  the public reader after a publish, and see the reader refuse to change it.

  `async: false` — sheet sessions are globally registered processes.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, debounce_ms: 60_000, idle_stop_ms: 60_000)
    )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  test "insert a chart from the selection; it redraws on edits; the reader shows it read-only",
       %{conn: conn} do
    slug = "charts-live-#{System.unique_integer([:positive, :monotonic])}"

    cells =
      for {ref, v} <- [
            {"A1", "Month"},
            {"B1", "Sales"},
            {"C1", "Cost"},
            {"A2", "Jan"},
            {"B2", 10},
            {"C2", 4},
            {"A3", "Feb"},
            {"B3", 20},
            {"C3", 5}
          ],
          into: %{},
          do: {ref, %{"v" => v}}

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "Data", "cells" => cells}]}},
        @dataset
      )

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    grid = with_target(view, "#sheet-grid-#{slug}")
    refute html =~ ~s(data-test-id="sheet-chart")

    # Select A1:C3, open the form (range prefilled), insert a line chart.
    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "C3", "shift" => true})
    view |> element(~s([data-test-id="sheet-chart-btn"])) |> render_click()

    assert view |> element(~s([data-test-id="sheet-chart-range"])) |> render() =~
             ~s(value="A1:C3")

    view
    |> element(~s([data-test-id="sheet-chart-form"]))
    |> render_submit(%{
      "chart_id" => "",
      "range" => "A1:C3",
      "type" => "line",
      "title" => "Sales and cost",
      "headers" => "on",
      "labels" => "on"
    })

    first = chart_html(view)
    assert first =~ "Sales and cost"
    assert first =~ "<polyline"
    # The legend names both series; the labels column is not a series.
    assert first =~ ~r/bp-chart__key.*Sales/s
    assert first =~ ~r/bp-chart__key.*Cost/s
    refute first =~ ~r/bp-chart__key[^<]*<i[^>]*><\/i>Month/
    assert first =~ ~s(aria-label="Sales and cost. Line chart of Sales, Cost, 2 points.")
    assert table_values(first) == ["Jan", "10", "4", "Feb", "20", "5"]

    # This editor's own edit, as a formula: the chart draws the computed value.
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => false})
    render_hook(grid, "edit-commit", %{"value" => "=B2+89", "move" => "down"})
    own = chart_html(view)
    assert table_values(own) == ["Jan", "10", "4", "Feb", "99", "5"]
    assert polylines(own) != polylines(first)

    # Another writer's op arrives over the session's delta broadcast.
    {:ok, %{errors: []}} =
      Session.apply_ops(slug, @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "C2", "raw" => 77, "user" => "someone-else"}
      ])

    assert table_values(chart_html(view)) == ["Jan", "10", "77", "Feb", "99", "5"]

    # Edit the chart: switch it to bars.
    view |> element(~s([data-test-id="sheet-chart-edit"])) |> render_click()

    view
    |> element(~s([data-test-id="sheet-chart-form"]))
    |> render_submit(%{
      "chart_id" => "ch-1",
      "range" => "A1:C3",
      "type" => "bar",
      "title" => "Sales and cost",
      "headers" => "on",
      "labels" => "on"
    })

    bars = chart_html(view)
    assert bars =~ "<rect"
    refute bars =~ "<polyline"
    # The y-axis is pinned to round ticks (0..120 for a top value of 99);
    # the last end-anchored label is the final x label.
    assert Regex.scan(~r/bp-chart__tick"[^>]*text-anchor="end">([^<]*)</, bars)
           |> Enum.map(&List.last/1) == ["120", "80", "40", "0", "Feb"]

    # A range of text only says so instead of drawing an empty chart.
    view |> element(~s([data-test-id="sheet-chart-btn"])) |> render_click()

    view
    |> element(~s([data-test-id="sheet-chart-form"]))
    |> render_submit(%{"chart_id" => "", "range" => "A1:A3", "type" => "line", "title" => ""})

    assert view |> element(~s([data-test-id="sheet-chart-empty"])) |> render() =~
             "No numbers in A1:A3"

    # The public reader shows the charts after a publish, with nothing to press.
    :ok = Session.flush(slug, @dataset)
    {:ok, _} = Content.publish_document(slug, "sheet", @dataset)
    {:ok, reader, reader_html} = live(conn, "/sheets/#{slug}")
    assert reader_html =~ "Sales and cost"
    assert reader_html =~ "<rect"
    refute reader_html =~ "sheet-chart-edit"
    refute reader_html =~ "sheet-chart-btn"

    # A forged write from the reader is dropped on the server.
    reader_grid = with_target(reader, "#sheet-reader-#{slug}")
    render_hook(reader_grid, "chart-delete", %{"id" => "ch-1"})

    render_hook(reader_grid, "chart-save", %{
      "chart_id" => "",
      "range" => "B1:B3",
      "type" => "line",
      "title" => "forged"
    })

    {:ok, content} = Session.peek(slug, @dataset)
    assert ["ch-1", "ch-2"] == for(c <- hd(content["tabs"])["charts"], do: c["id"])
    refute render(reader) =~ "forged"
  end

  defp chart_html(view), do: view |> element(~s([data-chart-id="ch-1"])) |> render()

  defp polylines(html), do: Regex.scan(~r/<polyline[^>]*>/, html)

  # The data-table fallback's body, row by row.
  defp table_values(html) do
    [body] = Regex.run(~r/<tbody>.*<\/tbody>/s, html)
    ~r/<t[hd][^>]*>([^<]*)<\/t[hd]>/ |> Regex.scan(body) |> Enum.map(&List.last/1)
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
