defmodule BarkparkWeb.Studio.SheetGrid.Charts do
  @moduledoc """
  Charts in the sheet grid: the `chart-*` events, the toolbar button with its
  form, and the charts drawn under the grid (Studio and the public reader).

  The model, its validation and the data a chart reads live in
  `Barkpark.Plugins.Sheets.Charts`. The drawing is the paper renderer's
  `DataViz.chart_html/1` — server-side inline SVG, no script. A chart is drawn
  from the tab's cells each time `GridData.derive_grid/1` runs, so it follows
  every delta the grid applies: this editor's edits and a collaborator's.

  Every write is a `set_chart` / `delete_chart` session op sent through the
  grid's own `send_ops/2` (passed in by the facade), so it meets the same
  write wall as a cell edit: a host that may not write sends nothing.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import BarkparkWeb.StudioComponents.Controls

  alias Barkpark.PortableDoc.Render.DataViz
  alias Barkpark.Plugins.Sheets.Charts, as: Model
  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias BarkparkWeb.Studio.SheetGrid.Geometry

  # ── derived views (called from GridData.derive_grid/1) ───────────────────

  @doc "One view per chart on the tab: the chart, what it reads, and its SVG."
  def views(tab) when is_map(tab) do
    cells = Map.get(tab, "cells") || %{}

    for chart <- Model.list(tab) do
      data = Model.data(chart, cells)
      %{id: to_string(Map.get(chart, "id")), chart: chart, data: data, svg: svg(chart, data)}
    end
  end

  def views(_tab), do: []

  defp svg(chart, %{state: :ok} = data) do
    DataViz.chart_html(%{
      "kind" => if(Map.get(chart, "type") == "bar", do: "bars", else: "line"),
      "series" => Enum.map(data.series, &%{"label" => &1.label, "points" => &1.points}),
      "axes" => Map.merge(%{"xLabels" => data.labels}, axis_pins(chart, data))
    })
  end

  defp svg(_chart, _data), do: nil

  # Pin the y-axis so its four ticks land on round numbers: the renderer draws
  # them at even thirds of the span, which gives 126.7 for a 40..300 range.
  # Bars keep a zero baseline. A flat series is left to the renderer.
  defp axis_pins(chart, data) do
    points = Enum.flat_map(data.series, & &1.points)
    {lo, hi} = Enum.min_max(points)
    lo = if Map.get(chart, "type") == "bar", do: min(lo, 0), else: lo
    hi = if Map.get(chart, "type") == "bar", do: max(hi, 0), else: hi

    with true <- hi > lo,
         mag = :math.pow(10, Float.floor(:math.log10((hi - lo) / 3))),
         {min, max} <-
           Enum.find_value([1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 15], fn m ->
             step = m * mag
             base = Float.floor(lo / step) * step
             if base + 3 * step >= hi, do: {base, base + 3 * step}
           end) do
      %{"min" => min, "max" => max}
    else
      _ -> %{}
    end
  end

  # ── events ───────────────────────────────────────────────────────────────

  @doc """
  Handle a `chart-*` event. `send_ops` is the grid's own write path
  (`SheetGrid.send_ops/2`): it re-asks the write predicate and drops the ops
  for a host that may not write.
  """
  def handle_event(_event, _params, %{assigns: %{write_capable: false}} = socket, _send_ops),
    do: socket

  def handle_event("chart-open", params, socket, _send_ops) do
    panel =
      case Enum.find(socket.assigns.chart_views, &(&1.id == params["id"])) do
        nil -> new_form(socket)
        %{chart: chart} -> edit_form(chart)
      end

    socket
    |> assign(chart_panel: panel, menu: nil)
    |> Phoenix.LiveView.push_event("bp:sheet-focus-first", %{
      id: "#{socket.assigns.id}-chart-panel"
    })
  end

  def handle_event("chart-close", _params, socket, _send_ops),
    do: assign(socket, chart_panel: nil)

  def handle_event("chart-form-change", params, socket, _send_ops),
    do: assign(socket, chart_panel: form_state(params))

  def handle_event("chart-save", params, socket, send_ops) do
    form = form_state(params)

    chart =
      form
      |> Map.take(~w(range type title headers labels))
      |> Map.update!("range", &String.trim/1)
      |> then(&if(form["id"] == "", do: &1, else: Map.put(&1, "id", form["id"])))

    op = %{"op" => "set_chart", "tab" => socket.assigns.tab, "chart" => chart}
    socket = send_ops.(assign(socket, notice: nil), [op])
    # A refused chart keeps the form (the notice says why).
    assign(socket, chart_panel: if(socket.assigns.notice, do: form, else: nil))
  end

  def handle_event("chart-delete", %{"id" => id}, socket, send_ops) do
    op = %{"op" => "delete_chart", "tab" => socket.assigns.tab, "id" => id}
    send_ops.(assign(socket, chart_panel: nil), [op])
  end

  def handle_event("chart-move", %{"id" => id, "dir" => dir}, socket, send_ops)
      when dir in ["up", "down"] do
    views = socket.assigns.chart_views
    at = Enum.find_index(views, &(&1.id == id))
    to = at && at + if(dir == "up", do: -1, else: 1)

    if (at && to >= 0) and to < length(views) do
      chart = Enum.at(views, at).chart

      send_ops.(socket, [
        %{"op" => "set_chart", "tab" => socket.assigns.tab, "chart" => chart, "at" => to}
      ])
    else
      socket
    end
  end

  def handle_event(_event, _params, socket, _send_ops), do: socket

  defp new_form(socket) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    a = Sheets.format_ref({c1, r1})
    range = if {c1, r1} == {c2, r2}, do: a, else: a <> ":" <> Sheets.format_ref({c2, r2})

    %{
      "id" => "",
      "range" => range,
      "type" => "line",
      "title" => "",
      "headers" => true,
      "labels" => true
    }
  end

  defp edit_form(chart) do
    %{
      "id" => to_string(Map.get(chart, "id")),
      "range" => to_string(Map.get(chart, "range")),
      "type" => if(Map.get(chart, "type") == "bar", do: "bar", else: "line"),
      "title" => to_string(Map.get(chart, "title") || ""),
      "headers" => Map.get(chart, "headers", true) == true,
      "labels" => Map.get(chart, "labels", true) == true
    }
  end

  # An unticked checkbox sends no key at all, so absent reads as off.
  defp form_state(params) do
    %{
      "id" => to_string(params["chart_id"] || ""),
      "range" => to_string(params["range"] || ""),
      "type" => if(params["type"] == "bar", do: "bar", else: "line"),
      "title" => to_string(params["title"] || ""),
      "headers" => params["headers"] in ["on", "true", true],
      "labels" => params["labels"] in ["on", "true", true]
    }
  end

  # ── toolbar: the Insert chart button and its form ────────────────────────

  attr :id, :string, required: true
  attr :panel, :map, default: nil
  attr :myself, :any, required: true

  def chart_tools(assigns) do
    ~H"""
    <div class="sheet-cf-group" role="group" aria-label={gettext("Charts")} data-test-id="sheet-chart-group">
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click={if @panel, do: "chart-close", else: "chart-open"}
        phx-target={@myself}
        aria-haspopup="dialog"
        aria-expanded={to_string(@panel != nil)}
        title={gettext("Insert a chart of the selected cells")}
        id={"#{@id}-chart-btn"}
        data-test-id="sheet-chart-btn"
      ><%= gettext("Chart") %></button>

      <div
        :if={@panel}
        class="sheet-popover sheet-cf-panel"
        role="dialog"
        aria-label={if @panel["id"] == "", do: gettext("Insert chart"), else: gettext("Edit chart")}
        id={"#{@id}-chart-panel"}
        phx-window-keydown="chart-close"
        phx-key="Escape"
        phx-target={@myself}
        data-test-id="sheet-chart-panel"
      >
        <div class="sheet-cf-head">
          <span class="sheet-cf-title"><%= if @panel["id"] == "", do: gettext("Insert chart"), else: gettext("Edit chart") %></span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="chart-close" phx-target={@myself} aria-label={gettext("Close chart form")} data-test-id="sheet-chart-close">×</button>
        </div>
        <form class="sheet-cf-form" phx-submit="chart-save" phx-change="chart-form-change" phx-target={@myself} data-test-id="sheet-chart-form">
          <input type="hidden" name="chart_id" value={@panel["id"]} />
          <label class="sheet-cf-field">
            <span><%= gettext("Cells to chart") %></span>
            <.bp_input name="range" value={@panel["range"]} placeholder="A1:C6" autocomplete="off" spellcheck="false" data-test-id="sheet-chart-range" />
          </label>
          <label class="sheet-cf-field">
            <span><%= gettext("Chart type") %></span>
            <.bp_select
              name="type"
              value={@panel["type"]}
              options={[{"line", gettext("Line")}, {"bar", gettext("Bar")}]}
              data-test-id="sheet-chart-type"
            />
          </label>
          <label class="sheet-cf-field">
            <span><%= gettext("Title") %></span>
            <.bp_input name="title" value={@panel["title"]} autocomplete="off" data-test-id="sheet-chart-title" />
          </label>
          <div class="sheet-cf-field">
            <.bp_checkbox name="headers" label={gettext("First row is headers")} checked={@panel["headers"]} data-test-id="sheet-chart-headers" />
            <.bp_checkbox name="labels" label={gettext("First column is labels")} checked={@panel["labels"]} data-test-id="sheet-chart-labels" />
          </div>
          <div class="sheet-cf-actions">
            <button type="submit" class="btn btn-primary btn-sm" data-test-id="sheet-chart-submit"><%= if @panel["id"] == "", do: gettext("Insert chart"), else: gettext("Save chart") %></button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── the charts under the grid ────────────────────────────────────────────

  attr :id, :string, required: true
  attr :views, :list, required: true
  attr :editable, :boolean, default: false
  attr :myself, :any, required: true

  def charts(assigns) do
    ~H"""
    <section :if={@views != []} class="sheet-charts" aria-label={gettext("Charts")} data-test-id="sheet-charts">
      <style>
        .sheet-charts {
          flex: none; max-height: 46vh; overflow: auto; padding: 10px 12px;
          border-top: 1px solid var(--border); background: var(--bg);
          display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 540px), 1fr));
          --sheet-chart-s0: #2563eb; --sheet-chart-s1: #c2410c; --sheet-chart-s2: #047857; --sheet-chart-s3: #a21caf;
        }
        html[data-theme="dark"] .sheet-charts { --sheet-chart-s0: #7aa7ff; --sheet-chart-s1: #fb923c; --sheet-chart-s2: #34d399; --sheet-chart-s3: #e879f9; }
        @media (prefers-color-scheme: dark) {
          html:not([data-theme]) .sheet-charts { --sheet-chart-s0: #7aa7ff; --sheet-chart-s1: #fb923c; --sheet-chart-s2: #34d399; --sheet-chart-s3: #e879f9; }
        }
        .sheet-reader:has(.sheet-charts) { max-height: none; }
        .sheet-reader:has(.sheet-charts) .sheet-grid-wrap { max-height: 70vh; }
        .sheet-reader .sheet-charts { max-height: none; }
        .sheet-chart { margin: 0; min-width: 0; max-width: 720px; padding: 10px 12px; border: 1px solid var(--border); border-radius: 8px; color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        .sheet-chart-head { display: flex; align-items: center; gap: 4px; margin-bottom: 6px; }
        .sheet-chart-title { flex: 1; min-width: 0; font-size: 13px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .sheet-chart-note { margin: 6px 0 0; font-size: 12px; color: var(--fg-dim, var(--fg)); }
        .sheet-chart .bp-chart__scroll { overflow-x: auto; }
        .sheet-chart .bp-chart svg { display: block; width: 100%; min-width: 500px; height: auto; }
        .sheet-chart .bp-chart__grid { stroke: var(--border); stroke-width: 1; vector-effect: non-scaling-stroke; }
        .sheet-chart .bp-chart__axis { stroke: var(--fg-dim, var(--fg)); stroke-width: 1; vector-effect: non-scaling-stroke; }
        .sheet-chart .bp-chart__tick { fill: var(--fg-dim, var(--fg)); font-size: 12px; }
        .sheet-chart .bp-chart__s { fill: none; stroke-width: 2; vector-effect: non-scaling-stroke; stroke-linejoin: round; stroke-linecap: round; }
        .sheet-chart .bp-chart__b { stroke: none; }
        .sheet-chart .bp-chart__s0 { stroke: var(--sheet-chart-s0); }
        .sheet-chart .bp-chart__s1 { stroke: var(--sheet-chart-s1); }
        .sheet-chart .bp-chart__s2 { stroke: var(--sheet-chart-s2); }
        .sheet-chart .bp-chart__s3 { stroke: var(--sheet-chart-s3); }
        .sheet-chart rect.bp-chart__s0, .sheet-chart .bp-chart__swatch.bp-chart__s0 { fill: var(--sheet-chart-s0); background: var(--sheet-chart-s0); }
        .sheet-chart rect.bp-chart__s1, .sheet-chart .bp-chart__swatch.bp-chart__s1 { fill: var(--sheet-chart-s1); background: var(--sheet-chart-s1); }
        .sheet-chart rect.bp-chart__s2, .sheet-chart .bp-chart__swatch.bp-chart__s2 { fill: var(--sheet-chart-s2); background: var(--sheet-chart-s2); }
        .sheet-chart rect.bp-chart__s3, .sheet-chart .bp-chart__swatch.bp-chart__s3 { fill: var(--sheet-chart-s3); background: var(--sheet-chart-s3); }
        .sheet-chart .bp-chart__legend { display: flex; flex-wrap: wrap; gap: 4px 16px; margin-top: 6px; }
        .sheet-chart .bp-chart__key { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--fg); }
        .sheet-chart .bp-chart__swatch { width: 14px; height: 4px; border-radius: 2px; }
        .sheet-chart-data { margin-top: 6px; font-size: 12px; color: var(--fg-dim, var(--fg)); }
        .sheet-chart-data summary { cursor: pointer; }
        .sheet-chart-data table { margin-top: 4px; border-collapse: collapse; font-variant-numeric: tabular-nums; color: var(--fg); }
        .sheet-chart-data th, .sheet-chart-data td { padding: 2px 10px 2px 0; text-align: right; font-weight: 400; }
        .sheet-chart-data th:first-child { text-align: left; }
        .sheet-chart-data thead th { font-weight: 600; }
      </style>
      <figure
        :for={{view, i} <- Enum.with_index(@views)}
        id={"#{@id}-chart-#{view.id}"}
        class="sheet-chart"
        role="group"
        aria-label={summary(view)}
        data-test-id="sheet-chart"
        data-chart-id={view.id}
        data-chart-type={view.chart["type"]}
        data-chart-range={view.chart["range"]}
      >
        <figcaption class="sheet-chart-head">
          <span class="sheet-chart-title" data-test-id="sheet-chart-heading"><%= title(view) %></span>
          <%= if @editable do %>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="chart-move" phx-value-id={view.id} phx-value-dir="up" phx-target={@myself} disabled={i == 0} aria-label={gettext("Move %{chart} up", chart: title(view))} title={gettext("Move up")} data-test-id="sheet-chart-up">↑</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="chart-move" phx-value-id={view.id} phx-value-dir="down" phx-target={@myself} disabled={i == length(@views) - 1} aria-label={gettext("Move %{chart} down", chart: title(view))} title={gettext("Move down")} data-test-id="sheet-chart-down">↓</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="chart-open" phx-value-id={view.id} phx-target={@myself} aria-label={gettext("Edit %{chart}", chart: title(view))} data-test-id="sheet-chart-edit"><%= gettext("Edit") %></button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="chart-delete" phx-value-id={view.id} phx-target={@myself} aria-label={gettext("Delete %{chart}", chart: title(view))} data-test-id="sheet-chart-delete"><%= gettext("Delete") %></button>
          <% end %>
        </figcaption>
        <%= if view.svg do %>
          <%= Phoenix.HTML.raw(view.svg) %>
          <p :for={note <- notes(view.data)} class="sheet-chart-note" data-test-id="sheet-chart-note"><%= note %></p>
          <details class="sheet-chart-data">
            <summary><%= gettext("Data") %></summary>
            <table data-test-id="sheet-chart-table">
              <thead>
                <tr><th :for={h <- hd(view.data.table)} scope="col"><%= h %></th></tr>
              </thead>
              <tbody>
                <tr :for={[head | values] <- tl(view.data.table)}>
                  <th scope="row"><%= head %></th>
                  <td :for={v <- values}><%= v %></td>
                </tr>
              </tbody>
            </table>
          </details>
        <% else %>
          <p class="sheet-chart-note" data-test-id="sheet-chart-empty"><%= empty_text(view) %></p>
        <% end %>
      </figure>
    </section>
    """
  end

  defp title(%{chart: chart}) do
    case Map.get(chart, "title") do
      t when is_binary(t) and t != "" -> t
      _ -> gettext("Chart of %{range}", range: to_string(Map.get(chart, "range")))
    end
  end

  # The figure's accessible name: what kind of chart, of what, how much.
  defp summary(%{data: %{state: :ok} = data} = view) do
    series = Enum.map_join(data.series, ", ", & &1.label)
    points = length(hd(data.series).points)

    if view.chart["type"] == "bar" do
      gettext("%{title}. Bar chart of %{series}, %{count} points.",
        title: title(view),
        series: series,
        count: points
      )
    else
      gettext("%{title}. Line chart of %{series}, %{count} points.",
        title: title(view),
        series: series,
        count: points
      )
    end
  end

  defp summary(view), do: "#{title(view)}. #{empty_text(view)}"

  defp empty_text(%{data: %{state: :no_numbers}, chart: chart}),
    do:
      gettext("No numbers in %{range}, so there is nothing to draw.",
        range: to_string(Map.get(chart, "range"))
      )

  defp empty_text(_view),
    do: gettext("This chart's cells cannot be read. Edit it to pick new ones.")

  defp notes(data) do
    [
      data.skipped > 0 &&
        ngettext(
          "%{count} row left out: it holds a cell that is not a number.",
          "%{count} rows left out: they hold a cell that is not a number.",
          data.skipped
        ),
      data.more_series > 0 &&
        gettext("Showing the first %{shown} number columns of %{total}.",
          shown: length(data.series),
          total: length(data.series) + data.more_series
        ),
      data.truncated &&
        gettext("Showing the first %{count} rows.", count: length(hd(data.series).points))
    ]
    |> Enum.filter(& &1)
  end
end
