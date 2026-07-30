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

      # KPI denominator (slate-2, stat.go §denom): a dim "/<denom>" riding
      # immediately after the value — the "71/118" read. A DISPLAY string like
      # `value`, never coerced. Absent/blank → the empty suffix, so a denom-less
      # stat stays byte-identical to before.
      denom = block |> get("denom") |> display_string()

      denom_html =
        if denom == "",
          do: "",
          else: ~s|<span class="bp-stat__denom">/#{escape_html(denom)}</span>|

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
        ~s|<div class="bp-stat__v">#{escape_html(value)}#{denom_html}</div>| <>
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

  MODES (slate-2, mirrors heatmap.go's amended contract — calendar + matrix
  marginals/values are branches of THIS one emitter, never siblings):
  `mode:"calendar"` draws the GitHub-style day-rows×week-cols contribution
  calendar; `marginals:true`/`values:true` draw the matrix with Σ sums and/or
  exact cell values. The new modes bin by QUANTILE (`quantile_bins/1`, the
  HeatQuantileBins port) and dual-encode — the bin drives both the color step
  and a non-color channel. With no mode and neither flag the legacy grid below
  renders byte-identically.
  """
  def heatmap_html(block) when is_map(block) do
    grid =
      block
      |> get("cells")
      |> as_list()
      |> Enum.map(fn row -> row |> as_list() |> Enum.map(&(numeric(&1) || 0.0)) end)
      |> Enum.reject(&(&1 == []))

    cond do
      grid == [] ->
        empty("heatmap")

      display_string(get(block, "mode")) == "calendar" ->
        heat_calendar_html(grid, block)

      get(block, "marginals") == true or get(block, "values") == true ->
        heat_matrix_extras_html(grid, block)

      true ->
        heat_grid_html(grid, block)
    end
  end

  def heatmap_html(_), do: empty("heatmap")

  # The legacy value/max intensity grid — the pre-slate-2 emitter body, moved
  # verbatim so a heatmap with no mode and no matrix flags stays byte-identical.
  defp heat_grid_html(grid, block) do
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

  # ── slate-2 heat modes: quantile dual-encode (calendar + matrix extras) ──────

  # GitHub-style contribution calendar (heatRenderCalendar in heatmap.go):
  # day-rows × week-cols, quantile dual-encoded. Where the TUI drops the oldest
  # weeks to fit the terminal, the web renders ALL weeks inside a horizontally
  # scrollable `.bp-heat__scroll` container — it never width-drops. colLabels
  # are per-week month labels stamped along the top; rowLabels are day letters
  # in the gutter.
  defp heat_calendar_html(grid, block) do
    bins = quantile_bins(grid)
    row_labels = block |> get("rowLabels") |> string_list()
    col_labels = block |> get("colLabels") |> string_list()
    weeks = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    head =
      if col_labels == [] do
        ""
      else
        corner = if row_labels == [], do: "", else: ~s|<span class="bp-heat__rl"></span>|

        corner <>
          Enum.map_join(0..(weeks - 1), "", fn w ->
            ~s|<span class="bp-heat__ml">#{escape_html(Enum.at(col_labels, w) || "")}</span>|
          end)
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

        bin_row = Enum.at(bins, i)

        cells =
          Enum.map_join(0..(weeks - 1), "", fn w ->
            # Ragged rows: a missing week reads as a zero cell (bin -1), so the
            # calendar keeps its shape — the web read of heatmap.go's gap rule.
            v = Enum.at(row, w) || 0.0
            bin = Enum.at(bin_row, w) || -1
            ~s|<i class="bp-heat__c #{bin_class(bin)}" title="#{fmt(v)}"></i>|
          end)

        label <> cells
      end)

    track = if row_labels == [], do: "", else: "auto "

    ~s|<div class="bp-heat bp-heat--cal"><div class="bp-heat__scroll"><div class="bp-heat__grid" style="grid-template-columns:#{track}repeat(#{weeks},12px)">| <>
      head <> body <> "</div></div>" <> dual_legend() <> "</div>"
  end

  # The rows×cols heat matrix with the opt-in Σ marginals and/or exact values
  # (heatRenderMatrixExtras in heatmap.go). Cells dual-encode through the
  # quantile bins; with values:true each cell shows its right-aligned number
  # (the bin still keyed as a class for the color channel). Marginal sums render
  # as numbers on the web in BOTH flag combinations — the TUI's pure-shade Σ bar
  # is a 1-char-column constraint the browser doesn't have; the sums ARE the
  # marginal's point.
  defp heat_matrix_extras_html(grid, block) do
    bins = quantile_bins(grid)
    show_vals = get(block, "values") == true
    show_marg = get(block, "marginals") == true
    row_labels = block |> get("rowLabels") |> string_list()
    col_labels = block |> get("colLabels") |> string_list()
    cols = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    # Row / column sums for the marginals; ragged rows contribute 0 (gap rule).
    row_sums = Enum.map(grid, &Enum.sum/1)

    col_sums =
      Enum.map(0..(cols - 1), fn j ->
        grid |> Enum.map(&(Enum.at(&1, j) || 0.0)) |> Enum.sum()
      end)

    grand = Enum.sum(row_sums)

    # The label gutter exists when there are row labels, or when marginals need
    # the Σ footer label (mirrors heatmap.go's labelW floor under showMarg).
    gutter = row_labels != [] or show_marg

    head =
      if col_labels == [] and not show_marg do
        ""
      else
        corner = if gutter, do: ~s|<span class="bp-heat__rl"></span>|, else: ""

        labels =
          Enum.map_join(0..(cols - 1), "", fn j ->
            ~s|<span class="bp-heat__cl">#{escape_html(Enum.at(col_labels, j) || "")}</span>|
          end)

        sum_head =
          if show_marg, do: ~s|<span class="bp-heat__cl bp-heat__cl--sum">Σ</span>|, else: ""

        corner <> labels <> sum_head
      end

    body =
      grid
      |> Enum.with_index()
      |> Enum.map_join("", fn {row, i} ->
        label =
          if gutter do
            ~s|<span class="bp-heat__rl">#{escape_html(Enum.at(row_labels, i) || "")}</span>|
          else
            ""
          end

        bin_row = Enum.at(bins, i)

        cells =
          Enum.map_join(0..(cols - 1), "", fn j ->
            v = Enum.at(row, j) || 0.0
            bin = Enum.at(bin_row, j) || -1
            matrix_cell(bin, v, show_vals)
          end)

        row_sum =
          if show_marg do
            ~s|<span class="bp-heat__sum">#{fmt(Enum.at(row_sums, i))}</span>|
          else
            ""
          end

        label <> cells <> row_sum
      end)

    foot =
      if show_marg do
        ~s|<span class="bp-heat__rl">Σ</span>| <>
          Enum.map_join(col_sums, "", fn s -> ~s|<span class="bp-heat__sum">#{fmt(s)}</span>| end) <>
          ~s|<span class="bp-heat__sum bp-heat__sum--grand">#{fmt(grand)}</span>|
      else
        ""
      end

    track = if gutter, do: "auto ", else: ""
    cell_track = if show_vals, do: "minmax(28px,auto)", else: "minmax(10px,28px)"
    sum_track = if show_marg, do: " auto", else: ""

    ~s|<div class="bp-heat bp-heat--mtx"><div class="bp-heat__grid" style="grid-template-columns:#{track}repeat(#{cols},#{cell_track})#{sum_track}">| <>
      head <> body <> foot <> "</div>" <> dual_legend() <> "</div>"
  end

  # One matrix cell. With values the exact right-aligned number IS the second
  # channel (the bin class keys the color); without, the bin-keyed marker class
  # carries the non-color channel like the calendar cells.
  defp matrix_cell(bin, v, true) do
    ~s|<i class="bp-heat__c #{bin_class(bin)} bp-heat__c--v" title="#{fmt(v)}">#{fmt(v)}</i>|
  end

  defp matrix_cell(bin, v, false) do
    ~s|<i class="bp-heat__c #{bin_class(bin)}" title="#{fmt(v)}"></i>|
  end

  defp bin_class(-1), do: "bp-heat__c--z"
  defp bin_class(k) when is_integer(k), do: "bp-heat__c--b#{k |> max(0) |> min(3)}"

  # The low→high key for the dual-encode modes: the four bin swatches.
  defp dual_legend do
    ~s|<div class="bp-heat__legend">less | <>
      Enum.map_join(0..3, "", fn k -> ~s|<i class="bp-heat__c bp-heat__c--b#{k}"></i>| end) <>
      " more</div>"
  end

  # The HeatQuantileBins port (heatmap.go:318, @canonical heat-quantile-bin):
  # every cell binned into 0..3 by QUANTILE over the NONZERO values; zero/gap
  # cells get -1. Quantile binning is load-bearing — a linear value/max ramp
  # flattens months of ordinary activity into the floor when one spike owns the
  # max. Nearest-rank thresholds; a single distinct value → every nonzero cell
  # bin 0 (a uniform grid is genuinely uniform). This ONE helper owns the bin
  # for BOTH the color step and the second channel, so they can never disagree.
  defp quantile_bins(grid) do
    nz = grid |> List.flatten() |> Enum.filter(&(&1 > 0)) |> Enum.sort()
    n = length(nz)

    q = fn p ->
      if n == 0 do
        0.0
      else
        idx = ceil(p * n) - 1
        Enum.at(nz, idx |> max(0) |> min(n - 1))
      end
    end

    {q1, q2, q3} = {q.(0.25), q.(0.50), q.(0.75)}

    Enum.map(grid, fn row ->
      Enum.map(row, fn v ->
        cond do
          v <= 0 -> -1
          v <= q1 -> 0
          v <= q2 -> 1
          v <= q3 -> 2
          true -> 3
        end
      end)
    end)
  end

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
      # Charter D4 deliberately diverges by surface: the TUI caps at 2 via
      # internal/pdrender/chart.go maxChartSeries, while the web palette caps at 4.
      |> Enum.take(4)

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

        ann = annotations_of(block)

        ~s|<div class="bp-chart">| <>
          cap_html <>
          ~s|<svg viewBox="0 0 #{@vw} #{@vh}" preserveAspectRatio="none" role="img">| <>
          grid_svg(min_v, max_v) <>
          regions_svg(ann, n) <>
          plot_svg(series, kind, min_v, max_v, n) <>
          overlays_svg(ann, series, min_v, max_v, n) <>
          x_labels_svg(x_labels) <>
          "</svg>" <> legend_html(series) <> "</div>"
    end
  end

  def chart_html(_), do: empty("chart")

  # ── chart annotations (the Distill layer) ────────────────────────────────────
  #
  # An OPTIONAL `annotations` map lets the author narrate the plot ON-CANVAS —
  # the layer whose absence forced this week's sanction-curve essay to move its
  # region labels into the caption:
  #
  #   annotations: %{
  #     "regions"  => [%{"from", "to", "label"?, "tone"?}],   # x-INDEX span wash
  #     "refLines" => [%{"y", "label"?, "tone"?}],            # dashed y guide
  #     "points"   => [%{"series"?, "index", "label"}]        # one datum called out
  #   }
  #
  # `from`/`to`/`index` are data-point indexes (the same 0-based x domain the
  # series points occupy; fractional is fine), `y` is a data value, `tone` one of
  # info|ok|warn|danger (anything else → the neutral ink wash). Every entry is
  # fail-soft in the house style: non-numeric coordinates drop the entry, labels
  # go through escape_html, coordinates clamp to the plot area — a hostile block
  # can never draw outside the svg or inject markup. Regions paint BEHIND the
  # series (washes), refLines/points paint ABOVE (guides), so the data always
  # stays legible. Email keeps its text-badge degrade untouched; the TUI twin
  # ignores unknown attrs by construction (charter D4 lets surfaces diverge).
  defp annotations_of(block) do
    case get(block, "annotations") do
      %{} = a ->
        %{
          regions: as_list(get(a, "regions")),
          ref_lines: as_list(get(a, "refLines")),
          points: as_list(get(a, "points"))
        }

      _ ->
        %{regions: [], ref_lines: [], points: []}
    end
  end

  defp tone_class(base, tone) do
    case display_string(tone) do
      t when t in ~w(info ok warn danger) -> "#{base} #{base}--#{t}"
      _ -> base
    end
  end

  defp regions_svg(%{regions: regions}, n) do
    Enum.map_join(regions, "", fn r ->
      from = numeric(get(r, "from"))
      to = numeric(get(r, "to"))

      if is_number(from) and is_number(to) and to > from do
        x1 = x_at(clamp(from, 0.0, max(n - 1, 0) * 1.0), n)
        x2 = x_at(clamp(to, 0.0, max(n - 1, 0) * 1.0), n)
        label = r |> get("label") |> display_string()
        cls = tone_class("bp-chart__region", get(r, "tone"))

        rect =
          ~s|<rect class="#{cls}" x="#{fmt(x1)}" y="#{@pad_t}" width="#{fmt(x2 - x1)}" height="#{fmt(@vh - @pad_t - @pad_b)}"/>|

        label_svg =
          if label == "",
            do: "",
            else:
              ~s|<text class="bp-chart__ann" x="#{fmt((x1 + x2) / 2)}" y="#{@pad_t + 11}" text-anchor="middle">#{escape_html(label)}</text>|

        rect <> label_svg
      else
        ""
      end
    end)
  end

  defp overlays_svg(%{ref_lines: ref_lines, points: points}, series, min_v, max_v, n) do
    lines =
      Enum.map_join(ref_lines, "", fn l ->
        y = numeric(get(l, "y"))

        if is_number(y) do
          gy = y_at(y, min_v, max_v)
          label = l |> get("label") |> display_string()
          cls = tone_class("bp-chart__refline", get(l, "tone"))

          line =
            ~s|<line class="#{cls}" x1="#{@pad_l}" y1="#{fmt(gy)}" x2="#{@vw - @pad_r}" y2="#{fmt(gy)}"/>|

          label_svg =
            if label == "",
              do: "",
              else:
                ~s|<text class="bp-chart__ann" x="#{@vw - @pad_r - 2}" y="#{fmt(gy - 4)}" text-anchor="end">#{escape_html(label)}</text>|

          line <> label_svg
        else
          ""
        end
      end)

    marks =
      Enum.map_join(points, "", fn p ->
        idx = numeric(get(p, "index"))
        si = trunc(numeric(get(p, "series")) || 0.0)
        label = p |> get("label") |> display_string()
        value = point_value(series, si, idx)

        if is_number(idx) and is_number(value) and label != "" do
          i = idx |> clamp(0.0, max(n - 1, 0) * 1.0) |> trunc()
          x = x_at(i, n)
          y = y_at(value, min_v, max_v)
          ly = if y < @pad_t + 20, do: y + 16, else: y - 8

          ~s|<circle class="bp-chart__pt" cx="#{fmt(x)}" cy="#{fmt(y)}" r="3.5"/>| <>
            ~s|<text class="bp-chart__ann" x="#{fmt(x)}" y="#{fmt(ly)}" text-anchor="middle">#{escape_html(label)}</text>|
        else
          ""
        end
      end)

    lines <> marks
  end

  # The called-out datum: series si (author order, clamped in-range), point at
  # trunc(index). Out-of-range series/index → nil → the entry is dropped.
  defp point_value(series, si, idx) when is_number(idx) and idx >= 0 do
    with %{points: pts} <- Enum.at(series, si),
         v when is_number(v) <- Enum.at(pts, trunc(idx)),
         do: v,
         else: (_ -> nil)
  end

  defp point_value(_series, _si, _idx), do: nil

  # ── gauge-list ───────────────────────────────────────────────────────────────
  #
  # Browser twin of pdrender's gaugelist.go (ratified TUI slate). Semantics
  # mirrored EXACTLY: mode 'count'|'share' (absent mode infers share from a bare
  # `rows` key with no `snapshot`, else count); SHARE rows {label,value,note?}
  # in author order, denom = max when positive else Σvalue (guarded to 1),
  # proportion clamped [0,1], readout digit = round(prop*100)%; COUNT buckets the
  # verbatim snapshot rows by groupBy (worker|phase|status|priority, default
  # status; priority via its P<n> label; missing/empty → "(none)"), sorted DESC
  # by count then label ASC, meter = count/maxCount, digit = the count. groupBy
  # "epic" is UNBACKED (the parent→epic join is the wave-3 resolver's job): an
  # honest dim note, never faked. Absent data key → the honest empty box. The
  # `query` field is NEVER read (snapshot-authoritative, same as the TUI).

  @doc "Meter list: label + fill bar + exact readout per row (share or count mode)."
  def gauge_list_html(block) when is_map(block) do
    title = block |> get("title") |> display_string()

    title_html =
      if title == "", do: "", else: ~s|<div class="bp-gauge__t">#{escape_html(title)}</div>|

    case gauge_rows(block) do
      {:error, :epic} ->
        ~s|<div class="bp-gauge">| <>
          title_html <>
          ~s|<div class="bp-gauge__note">groupBy "epic" is unbacked here — needs the epic resolver</div></div>|

      {:ok, []} ->
        empty("gauge-list")

      {:ok, rows} ->
        body =
          Enum.map_join(rows, "", fn g ->
            note_html =
              if g.note == "",
                do: "",
                else: ~s|<span class="bp-gauge__n">#{escape_html(g.note)}</span>|

            ~s|<div class="bp-gauge__row">| <>
              ~s|<span class="bp-gauge__l">#{escape_html(g.label)}</span>| <>
              ~s|<span class="bp-gauge__bar"><i style="width:#{fmt(g.prop * 100)}%"></i></span>| <>
              ~s|<span class="bp-gauge__d">#{escape_html(g.digit)}</span>| <>
              note_html <> "</div>"
          end)

        ~s|<div class="bp-gauge">#{title_html}#{body}</div>|
    end
  end

  def gauge_list_html(_), do: empty("gauge-list")

  # ── bar-chart ──────────────────────────────────────────────────────────────
  #
  # Browser twin of pdrender's bar_chart.go (B003). Horizontal bars for
  # categorical counts: bars [{label, value}] in author order, denom = `max`
  # when positive else the DATA MAX (never the sum — these are counts, not
  # shares, unlike gauge-list share mode), proportion clamped [0,1]. `values:
  # true` prints the raw value after each bar. Absent/empty bars → the honest
  # empty box.

  @doc "Horizontal bars for categorical counts: label + fill bar (+ optional value)."
  def bar_chart_html(block) when is_map(block) do
    bars = block |> get("bars") |> as_list() |> Enum.filter(&is_map/1)

    case bars do
      [] ->
        empty("bar-chart")

      _ ->
        values = Enum.map(bars, &(numeric(get(&1, "value")) || 0.0))
        explicit_max = numeric(get(block, "max"))

        denom =
          case explicit_max do
            m when is_number(m) and m > 0 -> m
            _ -> Enum.max(values)
          end

        denom = if denom > 0, do: denom, else: 1.0
        show_values = get(block, "values") == true

        body =
          bars
          |> Enum.zip(values)
          |> Enum.map_join("", fn {b, value} ->
            prop = clamp(value / denom, 0.0, 1.0)

            digit_html =
              if show_values,
                do: ~s|<span class="bp-bar-chart__d">#{escape_html(fmt(value))}</span>|,
                else: ""

            ~s|<div class="bp-bar-chart__row">| <>
              ~s|<span class="bp-bar-chart__l">#{b |> get("label") |> display_string() |> escape_html()}</span>| <>
              ~s|<span class="bp-bar-chart__bar"><i style="width:#{fmt(prop * 100)}%"></i></span>| <>
              digit_html <> "</div>"
          end)

        ~s|<div class="bp-bar-chart">#{body}</div>|
    end
  end

  def bar_chart_html(_), do: empty("bar-chart")

  @doc "Email-safe bar-chart: a text summary badge (label: value per row), the chart precedent."
  def bar_chart_email_html(block, theme \\ :evergreen)

  def bar_chart_email_html(block, theme) when is_map(block) do
    bars = block |> get("bars") |> as_list() |> Enum.filter(&is_map/1)

    case bars do
      [] ->
        empty_email("bar-chart", theme)

      _ ->
        sk = email_skin(theme)

        rows =
          Enum.map_join(bars, "", fn b ->
            label = b |> get("label") |> display_string()
            value = fmt(numeric(get(b, "value")) || 0.0)

            ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;color:#{sk.ink};margin:2px 0">#{escape_html(label)}: #{escape_html(value)}</div>|
          end)

        ~s|<div style="background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
          rows <>
          ~s|<div style="font-size:11px;color:#{sk.muted};margin-top:6px;font-style:italic">Open the paper to see the live chart.</div></div>|
    end
  end

  def bar_chart_email_html(_, theme), do: empty_email("bar-chart", theme)

  # ── criteria-progress ─────────────────────────────────────────────────────
  #
  # Acceptance-criteria met/total rolled up per row, or aggregated to one
  # total row (B034). Renders from its OWN attrs — no live task-resolver
  # query at render time (the wishlist's `query` shape is a later Edit-time
  # resolver concern, not this birth). Same proportional-bar vocabulary as
  # bar-chart, but the denominator is each row's own `total` (a fraction,
  # not a shared max) and the digit is always shown (met/total IS the
  # datum, not optional embellishment like bar-chart's `values` toggle).
  #
  #   criteria-progress: {rows: [{label, met, total}], detail?: "rows"|"total"}
  #
  #   - rows    [{label, met, total}], author order preserved (default
  #             mode). Empty/absent -> the honest empty box.
  #   - detail  "total" collapses all rows into one aggregate bar (summed
  #             met/total, label "Total"); default "rows" keeps them
  #             separate.

  @doc "Acceptance-criteria met/total per row (or aggregated): label + fraction bar + met/total digits."
  def criteria_progress_html(block) when is_map(block) do
    rows = block |> get("rows") |> as_list() |> Enum.filter(&is_map/1)

    case rows do
      [] ->
        empty("criteria-progress")

      _ ->
        body =
          rows
          |> effective_criteria_rows(get(block, "detail"))
          |> Enum.map_join("", fn row ->
            met = numeric(get(row, "met")) || 0.0
            total = numeric(get(row, "total")) || 0.0
            prop = if total > 0, do: clamp(met / total, 0.0, 1.0), else: 0.0
            label = row |> get("label") |> display_string()

            ~s|<div class="bp-criteria-progress__row">| <>
              ~s|<span class="bp-criteria-progress__l">#{escape_html(label)}</span>| <>
              ~s|<span class="bp-criteria-progress__bar"><i style="width:#{fmt(prop * 100)}%"></i></span>| <>
              ~s|<span class="bp-criteria-progress__d">#{escape_html(fmt(met))}/#{escape_html(fmt(total))}</span>| <>
              "</div>"
          end)

        ~s|<div class="bp-criteria-progress">#{body}</div>|
    end
  end

  def criteria_progress_html(_), do: empty("criteria-progress")

  @doc "Email-safe criteria-progress: a text summary badge (label: met/total per row)."
  def criteria_progress_email_html(block, theme \\ :evergreen)

  def criteria_progress_email_html(block, theme) when is_map(block) do
    rows = block |> get("rows") |> as_list() |> Enum.filter(&is_map/1)

    case rows do
      [] ->
        empty_email("criteria-progress", theme)

      _ ->
        sk = email_skin(theme)

        row_html =
          rows
          |> effective_criteria_rows(get(block, "detail"))
          |> Enum.map_join("", fn row ->
            met = fmt(numeric(get(row, "met")) || 0.0)
            total = fmt(numeric(get(row, "total")) || 0.0)
            label = row |> get("label") |> display_string()

            ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;color:#{sk.ink};margin:2px 0">#{escape_html(label)}: #{escape_html(met)}/#{escape_html(total)}</div>|
          end)

        ~s|<div style="background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
          row_html <>
          ~s|<div style="font-size:11px;color:#{sk.muted};margin-top:6px;font-style:italic">Open the paper to see the live progress.</div></div>|
    end
  end

  def criteria_progress_email_html(_, theme), do: empty_email("criteria-progress", theme)

  defp effective_criteria_rows(rows, "total"), do: [aggregate_criteria_row(rows)]
  defp effective_criteria_rows(rows, _), do: rows

  defp aggregate_criteria_row(rows) do
    {met, total} =
      Enum.reduce(rows, {0.0, 0.0}, fn row, {m, t} ->
        {m + (numeric(get(row, "met")) || 0.0), t + (numeric(get(row, "total")) || 0.0)}
      end)

    %{"label" => "Total", "met" => met, "total" => total}
  end

  # Resolved gauge rows for either mode: {:ok, [%{label, prop, digit, note}]},
  # {:ok, []} when the mode's data key is absent/empty, {:error, :epic} for the
  # unbacked count groupBy.
  defp gauge_rows(block) do
    case gauge_mode(block) do
      "share" -> {:ok, share_gauges(block)}
      "count" -> count_gauges(block)
    end
  end

  defp gauge_mode(block) do
    case block |> get("mode") |> display_string() |> String.downcase() do
      "count" ->
        "count"

      "share" ->
        "share"

      _ ->
        if is_map(block) and Map.has_key?(block, "rows") and not Map.has_key?(block, "snapshot"),
          do: "share",
          else: "count"
    end
  end

  defp share_gauges(block) do
    items = block |> get("rows") |> as_list() |> Enum.filter(&is_map/1)

    if items == [] do
      []
    else
      sum = items |> Enum.map(&(numeric(get(&1, "value")) || 0.0)) |> Enum.sum()
      max = numeric(get(block, "max"))
      denom = if max != nil and max > 0, do: max, else: sum
      denom = if denom > 0, do: denom, else: 1.0

      Enum.map(items, fn it ->
        prop = clamp((numeric(get(it, "value")) || 0.0) / denom, 0.0, 1.0)

        %{
          label: it |> get("label") |> display_string(),
          prop: prop,
          digit: "#{round(prop * 100)}%",
          note: it |> get("note") |> display_string()
        }
      end)
    end
  end

  defp count_gauges(block) do
    group_by =
      case block |> get("groupBy") |> display_string() do
        "" -> "status"
        g -> g
      end

    cond do
      group_by == "epic" ->
        {:error, :epic}

      true ->
        rows = block |> get("snapshot") |> as_list() |> Enum.filter(&is_map/1)

        if rows == [] do
          {:ok, []}
        else
          counts = Enum.frequencies_by(rows, &gauge_bucket_key(&1, group_by))
          max_count = counts |> Map.values() |> Enum.max() |> max(1)

          gauges =
            counts
            |> Enum.sort_by(fn {label, count} -> {-count, label} end)
            |> Enum.map(fn {label, count} ->
              %{
                label: label,
                prop: count / max_count,
                digit: Integer.to_string(count),
                note: ""
              }
            end)

          {:ok, gauges}
        end
    end
  end

  # A task row's bucket label: priority via its P<n> label, every other field
  # by its trimmed string; missing/empty → "(none)" so unassigned work is
  # counted, never dropped (gaugelist.go gaugeBucketKey).
  defp gauge_bucket_key(row, "priority") do
    case row |> get("priority") |> display_string() do
      "" -> "(none)"
      p -> "P" <> p
    end
  end

  defp gauge_bucket_key(row, group_by) do
    case row |> get(group_by) |> display_string() do
      "" -> "(none)"
      key -> key
    end
  end

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
        ~s|<text class="bp-chart__tick" x="#{@pad_l - 6}" y="#{fmt(y + 4)}" text-anchor="end">#{tick_compact(v)}</text>|
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

  # ── email variants (gp-w3 email view) ────────────────────────────────────────
  #
  # The article emitters above lean on paper-surface.css classes and SVG strokes
  # — in a stylesheet-less email client the classed SVG paints as BLACK FILLED
  # BLOBS (no fill:none rule). These variants are the inline-styled, email-safe
  # reads: stat cells as styled divs, the grid as a real <table>, the heatmap as
  # bgcolor cells (intensity mixed into the accent IN ELIXIR), and the chart as
  # an honest per-series summary box — never a broken picture.

  # Email-safe skin — resolved PER THEME at render time (charter D28 relocation).
  # Was a block of compile-time @email_* module attributes frozen to evergreen;
  # every email emitter now takes a `theme` (defaulting :evergreen) and reads the
  # skin through here. Sourced from the same captured paperEmail hex the email
  # palette and article var() fallbacks draw on (Palettes.email_skin/1 — single
  # source, zero re-typing). Evergreen output is byte-identical to the old attrs.
  # The two RGB tuples for the heatmap accent-over-ground mix (no color-mix() in
  # email) derive HERE at render time from the resolved accent/ground hex — was
  # the compile-time @email_accent_rgb / @email_ground_rgb.
  defp email_skin(theme) do
    s = Barkpark.PortableDoc.Render.Palettes.email_skin(theme)

    %{
      ink: s.text,
      muted: s.muted,
      accent: s.brand,
      ground: s.page_bg,
      border: s.rule,
      paper: s.paper,
      accent_rgb: hex_to_rgb(s.brand),
      ground_rgb: hex_to_rgb(s.page_bg)
    }
  end

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>),
    do: {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

  @doc "Email-safe stat cell: inline-styled value/bar/label, no SVG."
  def stat_email_html(block, theme \\ :evergreen)

  def stat_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    value = block |> get("value") |> display_string()

    if value == "" do
      empty_email("stat", theme)
    else
      label = block |> get("label") |> display_string()
      max = numeric(get(block, "max"))

      bar =
        if max != nil and max > 0 do
          pct =
            case numeric(value) do
              nil -> 0.0
              v -> clamp(v / max, 0.0, 1.0)
            end

          ~s|<div style="height:6px;border-radius:3px;background:#{sk.border};margin-bottom:6px"><div style="height:6px;border-radius:3px;width:#{fmt(pct * 100)}%;background:#{sk.accent}"></div></div>|
        else
          ""
        end

      label_html =
        if label == "",
          do: "",
          else:
            ~s|<div style="font-size:12px;color:#{sk.muted};margin-top:2px">#{escape_html(label)}</div>|

      ~s|<div style="display:inline-block;min-width:120px;background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:8px 8px 8px 0;vertical-align:top">| <>
        bar <>
        ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:24px;font-weight:700;color:#{sk.ink};line-height:1.1">#{escape_html(value)}</div>| <>
        label_html <> "</div>"
    end
  end

  def stat_email_html(_, theme), do: empty_email("stat", theme)

  @doc "Email-safe KPI grid: one row of stat cells."
  def stats_email_html(block, theme \\ :evergreen)

  def stats_email_html(block, theme) when is_map(block) do
    items = block |> get("items") |> as_list() |> Enum.filter(&is_map/1)

    case items do
      [] -> empty_email("stats", theme)
      _ -> ~s|<div>| <> Enum.map_join(items, "", &stat_email_html(&1, theme)) <> "</div>"
    end
  end

  def stats_email_html(_, theme), do: empty_email("stats", theme)

  @doc "Email-safe heatmap: a real <table>, intensity baked into bgcolor."
  def heatmap_email_html(block, theme \\ :evergreen)

  def heatmap_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)

    grid =
      block
      |> get("cells")
      |> as_list()
      |> Enum.map(fn row -> row |> as_list() |> Enum.map(&(numeric(&1) || 0.0)) end)
      |> Enum.reject(&(&1 == []))

    if grid == [] do
      empty_email("heatmap", theme)
    else
      max_val =
        case numeric(get(block, "max")) do
          m when is_float(m) and m > 0 -> m
          _ -> grid |> List.flatten() |> Enum.max(fn -> 1.0 end) |> max(1.0e-9)
        end

      row_labels = block |> get("rowLabels") |> string_list()
      col_labels = block |> get("colLabels") |> string_list()
      cols = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      label_td =
        ~s|style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:11px;color:#{sk.muted};padding:2px 8px 2px 0;text-align:right"|

      head =
        if col_labels == [] do
          ""
        else
          corner = if row_labels == [], do: "", else: "<td></td>"

          "<tr>" <>
            corner <>
            Enum.map_join(0..(cols - 1), "", fn j ->
              ~s|<td style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:11px;color:#{sk.muted};padding:2px 3px;text-align:center">#{escape_html(Enum.at(col_labels, j) || "")}</td>|
            end) <> "</tr>"
        end

      body =
        grid
        |> Enum.with_index()
        |> Enum.map_join("", fn {row, i} ->
          label =
            if row_labels == [],
              do: "",
              else: ~s|<td #{label_td}>#{escape_html(Enum.at(row_labels, i) || "")}</td>|

          "<tr>" <>
            label <>
            Enum.map_join(0..(cols - 1), "", fn j ->
              v = Enum.at(row, j) || 0.0

              ~s|<td style="width:22px;height:18px;border-radius:3px;background:#{mix_hex(clamp(v / max_val, 0.0, 1.0), sk)}" title="#{fmt(v)}"></td>|
            end) <> "</tr>"
        end)

      ~s|<div style="display:inline-block;background:#{sk.paper};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
        ~s|<table cellspacing="3" cellpadding="0" style="border-collapse:separate">| <>
        head <> body <> "</table></div>"
    end
  end

  def heatmap_email_html(_, theme), do: empty_email("heatmap", theme)

  @doc """
  Email-safe chart: an honest per-series summary (label · min→max · last) —
  a broken SVG is worse than no picture; the live chart is one click away in
  the reader.
  """
  def chart_email_html(block, theme \\ :evergreen)

  def chart_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)

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
        empty_email("chart", theme)

      _ ->
        caption = block |> get("caption") |> display_string()

        cap_html =
          if caption == "",
            do: "",
            else:
              ~s|<div style="font-size:13px;font-weight:600;color:#{sk.ink};margin-bottom:6px">#{escape_html(caption)}</div>|

        rows =
          series
          |> Enum.with_index()
          |> Enum.map_join("", fn {s, si} ->
            label = if s.label == "", do: "series #{si + 1}", else: s.label
            last = List.last(s.points)

            ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;color:#{sk.muted};margin:2px 0"><span style="display:inline-block;width:12px;height:3px;border-radius:2px;background:#{sk.accent};margin-right:8px;vertical-align:middle"></span>#{escape_html(label)} · #{tick(Enum.min(s.points))} → #{tick(Enum.max(s.points))} · now #{tick(last)}</div>|
          end)

        ~s|<div style="background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
          cap_html <>
          rows <>
          ~s|<div style="font-size:11px;color:#{sk.muted};margin-top:6px;font-style:italic">Open the paper to see the live chart.</div></div>|
    end
  end

  def chart_email_html(_, theme), do: empty_email("chart", theme)

  @doc "Email-safe gauge list: inline-styled label/track/readout rows as a table."
  def gauge_list_email_html(block, theme \\ :evergreen)

  def gauge_list_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    title = block |> get("title") |> display_string()

    title_html =
      if title == "",
        do: "",
        else:
          ~s|<div style="font-weight:700;color:#{sk.ink};margin-bottom:8px">#{escape_html(title)}</div>|

    case gauge_rows(block) do
      {:error, :epic} ->
        ~s|<div style="background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
          title_html <>
          ~s|<div style="font-size:12px;color:#{sk.muted}">groupBy "epic" is unbacked here — needs the epic resolver</div></div>|

      {:ok, []} ->
        empty_email("gauge-list", theme)

      {:ok, rows} ->
        body =
          Enum.map_join(rows, "", fn g ->
            note_html =
              if g.note == "",
                do: "",
                else:
                  ~s|<td style="font-size:11px;color:#{sk.muted};padding:3px 0 3px 10px;white-space:nowrap">#{escape_html(g.note)}</td>|

            ~s|<tr>| <>
              ~s|<td style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;color:#{sk.ink};padding:3px 10px 3px 0;white-space:nowrap">#{escape_html(g.label)}</td>| <>
              ~s|<td style="width:60%;padding:3px 0"><div style="height:8px;border-radius:4px;background:#{sk.border}"><div style="height:8px;border-radius:4px;width:#{fmt(g.prop * 100)}%;background:#{sk.accent}"></div></div></td>| <>
              ~s|<td style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;color:#{sk.ink};padding:3px 0 3px 10px;text-align:right;white-space:nowrap">#{escape_html(g.digit)}</td>| <>
              note_html <> "</tr>"
          end)

        ~s|<div style="background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:12px 0">| <>
          title_html <>
          ~s|<table role="presentation" style="border-collapse:collapse;width:100%">#{body}</table></div>|
    end
  end

  def gauge_list_email_html(_, theme), do: empty_email("gauge-list", theme)

  # accent mixed over the ground at intensity t, computed here because email
  # has no color-mix() — the same read the stylesheet gives the reader. The
  # accent/ground RGB tuples come from the theme-resolved skin (charter D28).
  defp mix_hex(t, sk) do
    {ar, ag, ab} = sk.accent_rgb
    {gr, gg, gb} = sk.ground_rgb
    mix = fn a, g -> round(a * t + g * (1 - t)) end

    "#" <>
      Enum.map_join([mix.(ar, gr), mix.(ag, gg), mix.(ab, gb)], "", fn c ->
        c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
      end)
  end

  defp empty_email(kind, theme) do
    sk = email_skin(theme)

    ~s|<div style="border:1px dashed #{sk.border};border-radius:10px;padding:10px 13px;color:#{sk.muted};font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:12px;margin:12px 0">#{escape_html(kind)} — no data</div>|
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

  # Compact SI-style y-tick once |v| reaches 10000 — 40000→"40k", 45500000→
  # "45.5M", 2000000000→"2B", one decimal with a trailing ".0" trimmed, sign
  # carried through the division (formatTickCompact in chart.go). BELOW the
  # threshold it delegates to tick/1, byte-identical to before — small-value
  # chart output never moves. Article axis only; the email summary keeps tick/1.
  defp tick_compact(v) do
    if abs(v) < 10_000 do
      tick(v)
    else
      {div, suffix} =
        cond do
          abs(v) >= 1.0e9 -> {1.0e9, "B"}
          abs(v) >= 1.0e6 -> {1.0e6, "M"}
          true -> {1.0e3, "k"}
        end

      (v / div)
      |> :erlang.float_to_binary(decimals: 1)
      |> String.replace_suffix(".0", "")
      |> Kernel.<>(suffix)
    end
  end
end
