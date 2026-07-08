defmodule Barkpark.PortableDoc.Render.DataViz do
  @moduledoc """
  Data-viz PortableDoc components — the `_raw` HTML emitters for the creative
  slate (`stat`, `stats`/`stat-grid`, `heatmap`, `chart`), the browser twins of
  the TUI renderers in `internal/pdrender/{stat,heatmap,chart}.go`.

  Same family contract as `Render.Components`: pure, snapshot-driven leaf
  emitters — a block carries literal data in its attrs, this module renders a
  byte string that `compose_block` wraps as `%{"kind" => "_raw", "html" => …}`.
  No DB, no plugin, deterministic output (testable byte-for-byte).

  ## Palette

  All color comes from the paper tokens (`--paper-accent`, `--paper-ink-soft`,
  `--bp-tone-*`), so the blocks re-skin with the reader scheme for free. Series
  and cells never carry author-controlled color — intensity/series index drive
  a CSS custom property / class only.

  ## Semantics mirrored from the TUI (ratified, pbp-tui-creative-slate)

    * stat — `value` is a DISPLAY string, never coerced for display; `max`
      present-and-positive switches to the bullet-bar mode (value/max coerced
      numeric for the proportion only); `spark` draws the trend.
    * heatmap — intensity = value/max (explicit positive `max`, else data max;
      all-zero guarded), non-numeric cells read as 0 so the grid keeps shape.
    * chart — `axes.min`/`axes.max` PIN the y-span (both partial pins work),
      out-of-span points CLAMP to the plot edge, malformed pins (non-numeric,
      or both pinned with min >= max) are ignored; `axes.xLabels` draws the
      FIRST and LAST label. A series with no usable points is dropped; no
      usable series → the honest empty box.

  Absent/empty data → `<div class="bp-dataviz bp-dataviz--empty">` naming the
  block type — the browser twin of pdrender's `unresolvedPlaceholder`.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1]

  # ── stat ─────────────────────────────────────────────────────────────────────

  @doc "One KPI cell: big number (or value/max bullet-bar) + label + sparkline."
  def stat_html(block) when is_map(block) do
    value = block |> get("value") |> display_string()

    if value == "" do
      empty("stat")
    else
      label = block |> get("label") |> display_string()
      max = numeric(get(block, "max"))
      spark = block |> get("spark") |> number_list()

      bar =
        if max != nil and max > 0 do
          pct =
            case numeric(value) do
              nil -> 0.0
              v -> clamp(v / max, 0.0, 1.0)
            end

          ~s|<div class="bp-stat__bar"><i style="width:#{fmt(pct * 100)}%"></i></div>|
        else
          ""
        end

      label_html =
        if label == "", do: "", else: ~s|<div class="bp-stat__l">#{escape_html(label)}</div>|

      ~s|<div class="bp-stat">| <>
        bar <>
        ~s|<div class="bp-stat__v">#{escape_html(value)}</div>| <>
        label_html <> spark_svg(spark) <> "</div>"
    end
  end

  def stat_html(_), do: empty("stat")

  @doc "The plural KPI grid: N stat cells in an auto-fit grid."
  def stats_html(block) when is_map(block) do
    items = block |> get("items") |> as_list() |> Enum.filter(&is_map/1)

    case items do
      [] -> empty("stats")
      _ -> ~s|<div class="bp-stats">| <> Enum.map_join(items, "", &stat_html/1) <> "</div>"
    end
  end

  def stats_html(_), do: empty("stats")

  # ── heatmap ──────────────────────────────────────────────────────────────────

  @doc """
  Row-major intensity grid. Each cell carries `--i` (0..1) which the stylesheet
  mixes into the accent — the browser read of the TUI shade ramp.
  """
  def heatmap_html(block) when is_map(block) do
    grid =
      block
      |> get("cells")
      |> as_list()
      |> Enum.map(fn row -> row |> as_list() |> Enum.map(&(numeric(&1) || 0.0)) end)
      |> Enum.reject(&(&1 == []))

    if grid == [] do
      empty("heatmap")
    else
      max_val =
        case numeric(get(block, "max")) do
          m when is_float(m) and m > 0 -> m
          _ -> grid |> List.flatten() |> Enum.max(fn -> 1.0 end) |> max(1.0e-9)
        end

      row_labels = block |> get("rowLabels") |> string_list()
      col_labels = block |> get("colLabels") |> string_list()
      cols = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      head =
        if col_labels == [] do
          ""
        else
          cells =
            Enum.map_join(0..(cols - 1), "", fn j ->
              ~s|<span class="bp-heat__cl">#{escape_html(Enum.at(col_labels, j) || "")}</span>|
            end)

          corner = if row_labels == [], do: "", else: ~s|<span class="bp-heat__rl"></span>|
          corner <> cells
        end

      body =
        grid
        |> Enum.with_index()
        |> Enum.map_join("", fn {row, i} ->
          label =
            if row_labels == [] do
              ""
            else
              ~s|<span class="bp-heat__rl">#{escape_html(Enum.at(row_labels, i) || "")}</span>|
            end

          cells =
            Enum.map_join(0..(cols - 1), "", fn j ->
              v = Enum.at(row, j) || 0.0
              i_norm = clamp(v / max_val, 0.0, 1.0)
              ~s|<i class="bp-heat__c" style="--i:#{fmt3(i_norm)}" title="#{fmt(v)}"></i>|
            end)

          label <> cells
        end)

      track = if row_labels == [], do: "", else: "auto "

      ~s|<div class="bp-heat"><div class="bp-heat__grid" style="grid-template-columns:#{track}repeat(#{cols},minmax(10px,28px))">| <>
        head <>
        body <>
        ~s|</div><div class="bp-heat__legend">less | <>
        Enum.map_join([0.15, 0.35, 0.55, 0.75, 1.0], "", fn i ->
          ~s|<i class="bp-heat__c" style="--i:#{fmt3(i)}"></i>|
        end) <>
        " more</div></div>"
    end
  end

  def heatmap_html(_), do: empty("heatmap")

  # ── chart ────────────────────────────────────────────────────────────────────

  # SVG plot geometry (viewBox units). The y-gutter holds tick labels, the
  # bottom band the x rule + labels; width is fluid via preserveAspectRatio.
  @vw 640
  @vh 190
  @pad_l 46
  @pad_r 10
  @pad_t 8
  @pad_b 30

  @doc "Line/bars plot of one or more numeric series, as inline SVG."
  def chart_html(block) when is_map(block) do
    series =
      block
      |> get("series")
      |> as_list()
      |> Enum.map(fn s ->
        %{
          label: s |> get("label") |> display_string(),
          points: s |> get("points") |> number_list()
        }
      end)
      |> Enum.filter(&(&1.points != []))

    case series do
      [] ->
        empty("chart")

      _ ->
        kind = if display_string(get(block, "kind")) == "bars", do: :bars, else: :line
        axes = if is_map(get(block, "axes")), do: get(block, "axes"), else: %{}
        {min_v, max_v} = span(series, axes)

        # Bars imply a zero baseline: with no explicit min pin, a bar at the
        # data minimum would have zero height and read as "no data".
        min_v =
          if kind == :bars and numeric(get(axes, "min")) == nil,
            do: min(0.0, min_v),
            else: min_v

        x_labels = axes |> get("xLabels") |> string_list()
        caption = block |> get("caption") |> display_string()

        n = series |> Enum.map(&length(&1.points)) |> Enum.max()

        cap_html =
          if caption == "",
            do: "",
            else: ~s|<div class="bp-chart__t">#{escape_html(caption)}</div>|

        ~s|<div class="bp-chart">| <>
          cap_html <>
          ~s|<svg viewBox="0 0 #{@vw} #{@vh}" preserveAspectRatio="none" role="img">| <>
          grid_svg(min_v, max_v) <>
          plot_svg(series, kind, min_v, max_v, n) <>
          x_labels_svg(x_labels) <>
          "</svg>" <> legend_html(series) <> "</div>"
    end
  end

  def chart_html(_), do: empty("chart")

  # The effective y-span: pdrender semantics (chart.go). Partial pins work;
  # malformed pins (non-numeric, both pinned min >= max) → auto-scale; a
  # degenerate flat span expands by 1 so the floor never divides by zero.
  defp span(series, axes) do
    data = series |> Enum.flat_map(& &1.points)
    dmin = Enum.min(data)
    dmax = Enum.max(data)
    pmin = numeric(get(axes, "min"))
    pmax = numeric(get(axes, "max"))

    {min_v, max_v} =
      cond do
        pmin != nil and pmax != nil and pmin >= pmax -> {dmin, dmax}
        true -> {pmin || dmin, pmax || dmax}
      end

    if max_v <= min_v, do: {min_v, min_v + 1.0}, else: {min_v, max_v}
  end

  defp x_at(i, n) do
    inner = @vw - @pad_l - @pad_r
    if n <= 1, do: @pad_l + inner / 2, else: @pad_l + inner * i / (n - 1)
  end

  defp y_at(v, min_v, max_v) do
    inner = @vh - @pad_t - @pad_b
    norm = clamp((v - min_v) / (max_v - min_v), 0.0, 1.0)
    @pad_t + inner * (1.0 - norm)
  end

  defp grid_svg(min_v, max_v) do
    Enum.map_join(0..3, "", fn k ->
      v = min_v + (max_v - min_v) * (3 - k) / 3
      y = y_at(v, min_v, max_v)

      ~s|<line class="bp-chart__grid" x1="#{@pad_l}" y1="#{fmt(y)}" x2="#{@vw - @pad_r}" y2="#{fmt(y)}"/>| <>
        ~s|<text class="bp-chart__tick" x="#{@pad_l - 6}" y="#{fmt(y + 4)}" text-anchor="end">#{tick(v)}</text>|
    end) <>
      ~s|<line class="bp-chart__axis" x1="#{@pad_l}" y1="#{@vh - @pad_b}" x2="#{@vw - @pad_r}" y2="#{@vh - @pad_b}"/>|
  end

  defp plot_svg(series, :line, min_v, max_v, n) do
    series
    |> Enum.with_index()
    |> Enum.map_join("", fn {s, si} ->
      pts =
        s.points
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {v, i} ->
          "#{fmt(x_at(i, n))},#{fmt(y_at(v, min_v, max_v))}"
        end)

      ~s|<polyline class="bp-chart__s bp-chart__s#{rem(si, 4)}" points="#{pts}"/>|
    end)
  end

  defp plot_svg(series, :bars, min_v, max_v, n) do
    ns = length(series)
    slot = (@vw - @pad_l - @pad_r) / max(n, 1)
    bar_w = max(slot * 0.7 / ns, 1.0)
    floor_y = @vh - @pad_b

    series
    |> Enum.with_index()
    |> Enum.map_join("", fn {s, si} ->
      s.points
      |> Enum.with_index()
      |> Enum.map_join("", fn {v, i} ->
        x = @pad_l + slot * i + slot * 0.15 + bar_w * si
        y = y_at(v, min_v, max_v)

        ~s|<rect class="bp-chart__b bp-chart__s#{rem(si, 4)}" x="#{fmt(x)}" y="#{fmt(y)}" width="#{fmt(bar_w)}" height="#{fmt(max(floor_y - y, 0.0))}"/>|
      end)
    end)
  end

  defp x_labels_svg([]), do: ""

  defp x_labels_svg(labels) do
    first = List.first(labels) || ""
    last = List.last(labels) || ""
    y = @vh - @pad_b + 16

    ~s|<text class="bp-chart__tick" x="#{@pad_l}" y="#{y}" text-anchor="start">#{escape_html(first)}</text>| <>
      if last != "" and length(labels) > 1 do
        ~s|<text class="bp-chart__tick" x="#{@vw - @pad_r}" y="#{y}" text-anchor="end">#{escape_html(last)}</text>|
      else
        ""
      end
  end

  defp legend_html(series) do
    ~s|<div class="bp-chart__legend">| <>
      (series
       |> Enum.with_index()
       |> Enum.map_join("", fn {s, si} ->
         label = if s.label == "", do: "series #{si + 1}", else: s.label

         ~s|<span class="bp-chart__key"><i class="bp-chart__swatch bp-chart__s#{rem(si, 4)}"></i>#{escape_html(label)}</span>|
       end)) <> "</div>"
  end

  # ── the sparkline primitive (stat) ───────────────────────────────────────────

  defp spark_svg([]), do: ""

  defp spark_svg(values) do
    n = length(values)
    min_v = Enum.min(values)
    max_v = Enum.max(values)
    span = if max_v - min_v <= 0, do: 1.0, else: max_v - min_v
    w = 120
    h = 26

    pts =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = if n <= 1, do: w / 2, else: w * i / (n - 1)
        y = 2 + (h - 4) * (1.0 - (v - min_v) / span)
        "#{fmt(x)},#{fmt(y)}"
      end)

    ~s|<svg class="bp-stat__spark" viewBox="0 0 #{w} #{h}" preserveAspectRatio="none" aria-hidden="true"><polyline points="#{pts}"/></svg>|
  end

  # ── small helpers (Components conventions) ───────────────────────────────────

  defp empty(kind),
    do: ~s|<div class="bp-dataviz bp-dataviz--empty">#{escape_html(kind)} — no data</div>|

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []

  defp display_string(s) when is_binary(s), do: String.trim(s)
  defp display_string(n) when is_integer(n), do: Integer.to_string(n)
  defp display_string(n) when is_float(n), do: fmt(n)
  defp display_string(_), do: ""

  defp numeric(v) when is_integer(v), do: v * 1.0
  defp numeric(v) when is_float(v), do: v

  defp numeric(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp numeric(_), do: nil

  defp number_list(l) when is_list(l), do: l |> Enum.map(&numeric/1) |> Enum.reject(&is_nil/1)
  defp number_list(_), do: []

  defp string_list(l) when is_list(l), do: Enum.map(l, &display_string/1)
  defp string_list(_), do: []

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # Deterministic 1-decimal formatting for SVG geometry; integers stay bare.
  defp fmt(v) when is_float(v) do
    if v == Float.round(v),
      do: Integer.to_string(trunc(v)),
      else: :erlang.float_to_binary(v, decimals: 1)
  end

  defp fmt(v) when is_integer(v), do: Integer.to_string(v)

  defp fmt3(v), do: :erlang.float_to_binary(v * 1.0, decimals: 3)

  # y-tick label: whole numbers bare, else one decimal (mirrors the TUI ticks).
  defp tick(v) do
    r = Float.round(v * 1.0, 1)

    if r == Float.round(r),
      do: Integer.to_string(trunc(r)),
      else: :erlang.float_to_binary(r, decimals: 1)
  end
end
