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
  # Bitwise ops for the encoded-polyline varint decoder (route block).
  import Bitwise

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

      # Unit/qualifier riding after the number ("%", "USD", "dager"). A separate
      # span, never fused into the display string — the number keeps its own
      # typography (jarl figure family, jdf-bl-historiene-renderer-reconciliation).
      unit = block |> get("unit") |> display_string()

      unit_html =
        if unit == "",
          do: "",
          else: ~s|<span class="bp-stat__unit">#{escape_html(unit)}</span>|

      # One-sentence prose under the label — what the tile's number means.
      body = block |> get("body") |> display_string()

      body_html =
        if body == "", do: "", else: ~s|<div class="bp-stat__body">#{escape_html(body)}</div>|

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

      # THE KILDE LAW: a stat is a datum, and a datum carries its provenance —
      # `source` (commit:|paper:|task:|https://) surfaced as the «kilde» stamp.
      kilde =
        block
        |> get("source")
        |> display_string()
        |> parse_source_ref()
        |> List.wrap()
        |> kilde_html()

      ~s|<div class="bp-stat">| <>
        bar <>
        ~s|<div class="bp-stat__v">#{escape_html(value)}#{denom_html}#{unit_html}</div>| <>
        label_html <> body_html <> spark_svg(spark) <> kilde <> "</div>"
    end
  end

  def stat_html(_), do: empty("stat")

  @doc """
  The plural KPI grid: N stat cells in an auto-fit grid. Per-cell `source`
  refs (with the grid's `sourceDefault` as fallback) aggregate into ONE
  deduped kilde footer — cells never stamp their own.
  """
  def stats_html(block) when is_map(block) do
    items = block |> get("items") |> as_list() |> Enum.filter(&is_map/1)

    case items do
      [] ->
        empty("stats")

      _ ->
        default = block |> get("sourceDefault") |> display_string()
        refs = figure_refs(items, default, &(display_string(get(&1, "value")) != ""))
        cells = Enum.map_join(items, "", &stat_html(Map.delete(&1, "source")))
        ~s|<div class="bp-stats">| <> cells <> kilde_html(refs) <> "</div>"
    end
  end

  def stats_html(_), do: empty("stats")

  # ── kilde (source provenance) ────────────────────────────────────────────────
  #
  # THE KILDE LAW (jdf-bl-historiene-renderer-reconciliation): every figure
  # datum carries a source ref — `commit:<sha>` | `paper:<slug>` | `task:<id>` |
  # `https://…` — surfaced as a small «kilde» stamp under the figure. A ref that
  # does not parse never renders: a bad ref is not evidence. Only https refs
  # link out; commit/paper/task print as plain provenance text.

  @doc "Parse one source ref into %{raw, label, href} — nil when it is not a valid ref."
  def parse_source_ref(ref) when is_binary(ref) do
    cond do
      Regex.match?(~r/^commit:[0-9a-f]{7,40}$/, ref) ->
        %{raw: ref, label: "commit:" <> binary_part(ref, 7, 7), href: nil}

      Regex.match?(~r/^paper:[a-z0-9][a-z0-9-]*$/, ref) ->
        %{raw: ref, label: ref, href: nil}

      Regex.match?(~r/^task:[A-Za-z0-9._-]+$/, ref) ->
        %{raw: ref, label: ref, href: nil}

      String.starts_with?(ref, "https://") and byte_size(ref) > 8 ->
        label = ref |> String.replace_prefix("https://", "") |> String.trim_trailing("/")
        %{raw: ref, label: label, href: ref}

      true ->
        nil
    end
  end

  def parse_source_ref(_), do: nil

  # Collect the kilde refs for a figure's items: only datum-bearing items
  # (per `datum?`) carry the provenance obligation; each takes its own
  # `source` or the figure's `sourceDefault`; invalid refs drop; dedup by raw
  # ref in first-use order (authored order is never re-sorted).
  defp figure_refs(items, default, datum?) do
    items
    |> Enum.filter(datum?)
    |> Enum.map(fn it ->
      s = it |> get("source") |> display_string()
      if s == "", do: default, else: s
    end)
    |> Enum.map(&parse_source_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.raw)
  end

  # The «kilde» stamp: "Kilde" (one ref) / "Kilder" (several), then each ref.
  defp kilde_html([]), do: ""

  defp kilde_html(refs) do
    word = if length(refs) > 1, do: "Kilder", else: "Kilde"

    spans =
      Enum.map_join(refs, "", fn r ->
        inner =
          if r.href,
            do: ~s|<a href="#{escape_html(r.href)}">#{escape_html(r.label)}</a>|,
            else: escape_html(r.label)

        ~s|<span class="bp-kilde__ref">#{inner}</span>|
      end)

    ~s|<p class="bp-kilde"><span class="bp-kilde__word">#{word}</span>| <> spans <> "</p>"
  end

  # ── duel ─────────────────────────────────────────────────────────────────────

  @doc """
  Two-arm comparison table (jarl figure family): named legend columns (arm A
  carries the accent), rows of `%{label, delta, valueA, valueB, unit, source}`.
  The delta annotation rides under the row label — it is authored display text
  ("−30 %"), never computed. Both legends are REQUIRED — unnamed columns are a
  meaningless comparison → the honest empty box. Kilde law: every row is a
  datum; per-row `source` (fallback `sourceDefault`) aggregates into the stamp.
  """
  def duel_html(block) when is_map(block) do
    legend_a = block |> get("legendA") |> display_string()
    legend_b = block |> get("legendB") |> display_string()

    rows =
      block
      |> get("rows")
      |> as_list()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn r ->
        Enum.any?(["label", "valueA", "valueB"], &(display_string(get(r, &1)) != ""))
      end)

    if rows == [] or legend_a == "" or legend_b == "" do
      empty("duel")
    else
      default = block |> get("sourceDefault") |> display_string()

      refs =
        figure_refs(rows, default, fn r ->
          display_string(get(r, "valueA")) != "" or display_string(get(r, "valueB")) != ""
        end)

      head =
        ~s|<thead><tr><th class="bp-duel__th"></th>| <>
          ~s|<th class="bp-duel__th bp-duel__th--a" scope="col">#{escape_html(legend_a)}</th>| <>
          ~s|<th class="bp-duel__th" scope="col">#{escape_html(legend_b)}</th></tr></thead>|

      body = Enum.map_join(rows, "", &duel_row_html/1)

      ~s|<div class="bp-duel"><table class="bp-duel__table">| <>
        head <> "<tbody>" <> body <> "</tbody></table>" <> kilde_html(refs) <> "</div>"
    end
  end

  def duel_html(_), do: empty("duel")

  defp duel_row_html(r) do
    label = r |> get("label") |> display_string()
    delta = r |> get("delta") |> display_string()
    unit = r |> get("unit") |> display_string()
    va = r |> get("valueA") |> display_string()
    vb = r |> get("valueB") |> display_string()

    delta_html =
      if delta == "", do: "", else: ~s|<span class="bp-duel__delta">#{escape_html(delta)}</span>|

    unit_html =
      if unit == "", do: "", else: ~s|<span class="bp-duel__unit">#{escape_html(unit)}</span>|

    ~s|<tr class="bp-duel__row"><th class="bp-duel__label" scope="row">#{escape_html(label)}#{delta_html}</th>| <>
      ~s|<td class="bp-duel__val bp-duel__val--a">#{escape_html(va)}#{unit_html}</td>| <>
      ~s|<td class="bp-duel__val">#{escape_html(vb)}#{unit_html}</td></tr>|
  end

  # ── lineage ──────────────────────────────────────────────────────────────────

  @doc """
  Dated nodes on a line (jarl figure family): each node is
  `%{overline, title, body, value, unit, source}` — `overline` carries the
  date/period ("jan–sep 2025", "i dag") or qualifier, `value`+`unit` an
  optional datum. Nodes render in authored order; a node with nothing to say
  contributes nothing. Kilde law: datum-bearing nodes (those with a `value`)
  carry the provenance obligation (own `source`, else `sourceDefault`).
  """
  def lineage_html(block) when is_map(block) do
    nodes =
      block
      |> get("nodes")
      |> as_list()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn n ->
        Enum.any?(["overline", "title", "body", "value"], &(display_string(get(n, &1)) != ""))
      end)

    case nodes do
      [] ->
        empty("lineage")

      _ ->
        default = block |> get("sourceDefault") |> display_string()
        refs = figure_refs(nodes, default, &(display_string(get(&1, "value")) != ""))
        lis = Enum.map_join(nodes, "", &lineage_node_html/1)

        ~s|<div class="bp-lineage"><ol class="bp-lineage__nodes">| <>
          lis <> "</ol>" <> kilde_html(refs) <> "</div>"
    end
  end

  def lineage_html(_), do: empty("lineage")

  defp lineage_node_html(n) do
    overline = n |> get("overline") |> display_string()
    title = n |> get("title") |> display_string()
    value = n |> get("value") |> display_string()
    unit = n |> get("unit") |> display_string()
    body = n |> get("body") |> display_string()

    unit_html =
      if unit == "",
        do: "",
        else: ~s|<span class="bp-lineage__unit">#{escape_html(unit)}</span>|

    parts =
      if(overline == "",
        do: "",
        else: ~s|<div class="bp-lineage__overline">#{escape_html(overline)}</div>|
      ) <>
        if(title == "",
          do: "",
          else: ~s|<div class="bp-lineage__title">#{escape_html(title)}</div>|
        ) <>
        if(value == "",
          do: "",
          else: ~s|<div class="bp-lineage__value">#{escape_html(value)}#{unit_html}</div>|
        ) <>
        if body == "", do: "", else: ~s|<div class="bp-lineage__body">#{escape_html(body)}</div>|

    ~s|<li class="bp-lineage__node">| <> parts <> "</li>"
  end

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

    ~s|<div class="bp-heat"><div class="bp-heat__grid" style="grid-template-columns:#{track}repeat(#{cols},minmax(10px,44px))">| <>
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
    cell_track = if show_vals, do: "minmax(28px,auto)", else: "minmax(10px,44px)"
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

        # The svg rides its own scroll container (same idiom as the calendar
        # heatmap's bp-heat__scroll): CSS gives the svg a min-width at the
        # viewBox size, so viewBox-unit text never paints below its authored px
        # at narrow viewports — the figure scrolls instead of shrinking its
        # labels away (probe-figure-fidelity-2026-08-12 measured 11px ticks
        # painting 4.26px at a 360 viewport under plain width:100%).
        ~s|<div class="bp-chart">| <>
          cap_html <>
          ~s|<div class="bp-chart__scroll">| <>
          ~s|<svg viewBox="0 0 #{@vw} #{@vh}" preserveAspectRatio="none" role="img">| <>
          grid_svg(min_v, max_v) <>
          regions_svg(ann, n) <>
          plot_svg(series, kind, min_v, max_v, n) <>
          overlays_svg(ann, series, min_v, max_v, n) <>
          x_labels_svg(x_labels) <>
          "</svg></div>" <> legend_html(series) <> "</div>"
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
          anchor = ann_anchor(x, label)

          ~s|<circle class="bp-chart__pt" cx="#{fmt(x)}" cy="#{fmt(y)}" r="3.5"/>| <>
            ~s|<text class="bp-chart__ann" x="#{fmt(x)}" y="#{fmt(ly)}" text-anchor="#{anchor}">#{escape_html(label)}</text>|
        else
          ""
        end
      end)

    lines <> marks
  end

  # Edge-aware anchor for the point call-out label — the horizontal clamp the
  # regions/reflines already have (their labels are pinned mid-region / hard
  # right). A blanket text-anchor middle let a last-index label paint past the
  # viewBox (probe-figure-fidelity-2026-08-12 measured bbox right 654.1 vs 640).
  # The SVG is emitted server-side, so the text box can't be measured; estimate
  # the 10px mono label at ~3.1 viewBox units per half-char (SF Mono advance
  # ≈6.2/char at scale 1, slightly generous) and flip the anchor when the
  # estimated box would cross a viewBox edge: near the right edge the label
  # ends at the datum, near the left it starts there, everywhere else it stays
  # centered. The circle marker keeps the exact datum x either way.
  defp ann_anchor(x, label) do
    half = String.length(label) * 3.1

    cond do
      x + half > @vw - 2 -> "end"
      x - half < 2 -> "start"
      true -> "middle"
    end
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
      unit = block |> get("unit") |> display_string()
      body = block |> get("body") |> display_string()
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

      unit_html =
        if unit == "",
          do: "",
          else:
            ~s| <span style="font-size:12px;font-weight:400;color:#{sk.muted}">#{escape_html(unit)}</span>|

      body_html =
        if body == "",
          do: "",
          else:
            ~s|<div style="font-size:12px;color:#{sk.ink};margin-top:4px">#{escape_html(body)}</div>|

      kilde =
        block
        |> get("source")
        |> display_string()
        |> parse_source_ref()
        |> List.wrap()
        |> kilde_email_html(sk)

      ~s|<div style="display:inline-block;min-width:120px;background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:12px 14px;margin:8px 8px 8px 0;vertical-align:top">| <>
        bar <>
        ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:24px;font-weight:700;color:#{sk.ink};line-height:1.1">#{escape_html(value)}#{unit_html}</div>| <>
        label_html <> body_html <> kilde <> "</div>"
    end
  end

  def stat_email_html(_, theme), do: empty_email("stat", theme)

  # Email leg of the kilde stamp — same law, inline styles (D4/D8: classed
  # markup arrives unstyled in a stylesheet-less client).
  defp kilde_email_html([], _sk), do: ""

  defp kilde_email_html(refs, sk) do
    word = if length(refs) > 1, do: "Kilder", else: "Kilde"

    labels =
      Enum.map_join(refs, " · ", fn r ->
        if r.href,
          do:
            ~s|<a href="#{escape_html(r.href)}" style="color:#{sk.muted}">#{escape_html(r.label)}</a>|,
          else: escape_html(r.label)
      end)

    ~s|<div style="font-family:#{Barkpark.PortableDoc.Render.Palettes.font_mono()};font-size:11px;color:#{sk.muted};margin-top:8px">#{word}: #{labels}</div>|
  end

  @doc "Email-safe duel: a real bordered <table>, arm A accented, kilde as a dim line."
  def duel_email_html(block, theme \\ :evergreen)

  def duel_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    legend_a = block |> get("legendA") |> display_string()
    legend_b = block |> get("legendB") |> display_string()

    rows =
      block
      |> get("rows")
      |> as_list()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn r ->
        Enum.any?(["label", "valueA", "valueB"], &(display_string(get(r, &1)) != ""))
      end)

    if rows == [] or legend_a == "" or legend_b == "" do
      empty_email("duel", theme)
    else
      default = block |> get("sourceDefault") |> display_string()

      refs =
        figure_refs(rows, default, fn r ->
          display_string(get(r, "valueA")) != "" or display_string(get(r, "valueB")) != ""
        end)

      mono = Barkpark.PortableDoc.Render.Palettes.font_mono()

      head =
        ~s|<tr><td style="padding:6px 10px"></td>| <>
          ~s|<td style="padding:6px 10px;font-size:12px;text-align:right;color:#{sk.accent};font-weight:700">#{escape_html(legend_a)}</td>| <>
          ~s|<td style="padding:6px 10px;font-size:12px;text-align:right;color:#{sk.muted};font-weight:700">#{escape_html(legend_b)}</td></tr>|

      body =
        Enum.map_join(rows, "", fn r ->
          label = r |> get("label") |> display_string()
          delta = r |> get("delta") |> display_string()
          unit = r |> get("unit") |> display_string()
          va = r |> get("valueA") |> display_string()
          vb = r |> get("valueB") |> display_string()
          unit_sfx = if unit == "", do: "", else: " " <> escape_html(unit)

          delta_html =
            if delta == "",
              do: "",
              else:
                ~s|<div style="font-family:#{mono};font-size:11px;color:#{sk.muted}">#{escape_html(delta)}</div>|

          ~s|<tr><td style="padding:6px 10px;border-top:1px solid #{sk.border};font-size:13px;color:#{sk.ink}">#{escape_html(label)}#{delta_html}</td>| <>
            ~s|<td style="padding:6px 10px;border-top:1px solid #{sk.border};font-family:#{mono};font-size:13px;text-align:right;color:#{sk.accent}">#{escape_html(va)}#{unit_sfx}</td>| <>
            ~s|<td style="padding:6px 10px;border-top:1px solid #{sk.border};font-family:#{mono};font-size:13px;text-align:right;color:#{sk.ink}">#{escape_html(vb)}#{unit_sfx}</td></tr>|
        end)

      ~s|<div style="margin:12px 0"><table cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%;background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px">| <>
        head <> body <> "</table>" <> kilde_email_html(refs, sk) <> "</div>"
    end
  end

  def duel_email_html(_, theme), do: empty_email("duel", theme)

  @doc "Email-safe lineage: stacked dated nodes, kilde as a dim line."
  def lineage_email_html(block, theme \\ :evergreen)

  def lineage_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)

    nodes =
      block
      |> get("nodes")
      |> as_list()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn n ->
        Enum.any?(["overline", "title", "body", "value"], &(display_string(get(n, &1)) != ""))
      end)

    case nodes do
      [] ->
        empty_email("lineage", theme)

      _ ->
        default = block |> get("sourceDefault") |> display_string()
        refs = figure_refs(nodes, default, &(display_string(get(&1, "value")) != ""))
        mono = Barkpark.PortableDoc.Render.Palettes.font_mono()

        body =
          Enum.map_join(nodes, "", fn n ->
            overline = n |> get("overline") |> display_string()
            title = n |> get("title") |> display_string()
            value = n |> get("value") |> display_string()
            unit = n |> get("unit") |> display_string()
            text = n |> get("body") |> display_string()
            unit_sfx = if unit == "", do: "", else: " " <> escape_html(unit)

            parts =
              if(overline == "",
                do: "",
                else:
                  ~s|<div style="font-family:#{mono};font-size:11px;color:#{sk.muted};text-transform:uppercase;letter-spacing:.04em">#{escape_html(overline)}</div>|
              ) <>
                if(title == "",
                  do: "",
                  else:
                    ~s|<div style="font-size:14px;font-weight:700;color:#{sk.ink}">#{escape_html(title)}</div>|
                ) <>
                if(value == "",
                  do: "",
                  else:
                    ~s|<div style="font-family:#{mono};font-size:16px;color:#{sk.accent}">#{escape_html(value)}#{unit_sfx}</div>|
                ) <>
                if text == "",
                  do: "",
                  else: ~s|<div style="font-size:13px;color:#{sk.ink}">#{escape_html(text)}</div>|

            ~s|<div style="padding:10px 0;border-top:1px solid #{sk.border}">| <>
              parts <> "</div>"
          end)

        ~s|<div style="margin:12px 0">| <> body <> kilde_email_html(refs, sk) <> "</div>"
    end
  end

  def lineage_email_html(_, theme), do: empty_email("lineage", theme)

  @doc "Email-safe KPI grid: one row of stat cells."
  def stats_email_html(block, theme \\ :evergreen)

  def stats_email_html(block, theme) when is_map(block) do
    items = block |> get("items") |> as_list() |> Enum.filter(&is_map/1)

    case items do
      [] ->
        empty_email("stats", theme)

      _ ->
        # Kilde law, aggregated exactly like the :article grid: cells never
        # stamp their own — one deduped footer under the row.
        default = block |> get("sourceDefault") |> display_string()
        refs = figure_refs(items, default, &(display_string(get(&1, "value")) != ""))
        cells = Enum.map_join(items, "", &stat_email_html(Map.delete(&1, "source"), theme))
        ~s|<div>| <> cells <> kilde_email_html(refs, email_skin(theme)) <> "</div>"
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

  # ── route ────────────────────────────────────────────────────────────────────
  #
  # A sport track (cycling, running, …): the block's `polyline` carries a Google
  # ENCODED POLYLINE string — the whole GPS trace as one compact ASCII value, the
  # same "opaque data, renderer draws" contract as diagram/mermaid — plus display
  # attrs (`sport`/`distance`/`elevation`/`duration`/`caption`, all author
  # strings, never coerced). Rendered as a SELF-CONTAINED SVG track outline with
  # start (○ green) / finish (● terracotta) markers and a meta row — deliberately
  # NO map tiles and NO JS, so the identical figure works in the reader AND in
  # email (interactive slippy maps stay a <demo> island until the pattern earns
  # graduation). The projection is equirectangular with a cos(mid-lat) x-scale —
  # exact enough for any single track; this draws a route's SHAPE, not a survey.
  # The TUI twin rasterises the same polyline through the braille canvas
  # (internal/pdrender/route.go).

  @route_w 640
  @route_max_h 400
  @route_pad 16
  # Track/marker colors: article reads the paper accent token (falling back to
  # the evergreen brand hex); email carries literal hex — a stylesheet-less
  # client must never paint the var() default (black blobs, see the email-skin
  # note above). Start/finish greens/terracotta are SEMANTIC, not authorable.
  @route_start "#2f9e63"
  @route_finish "#c65a3f"

  @doc "Sport track: encoded polyline → self-contained SVG shape + meta row."
  def route_html(block, style \\ :article) when is_map(block) do
    points = block |> get("polyline") |> display_string() |> decode_polyline()

    if length(points) < 2 do
      empty("route")
    else
      skin = email_skin(:evergreen)

      track =
        case style do
          :article -> "var(--paper-accent, #{skin.accent})"
          _ -> skin.accent
        end

      meta =
        ["sport", "distance", "elevation", "duration"]
        |> Enum.map(fn k -> block |> get(k) |> display_string() end)
        |> Enum.reject(&(&1 == ""))

      meta_html =
        if meta == [] do
          ""
        else
          ~s|<div class="bp-route__meta" style="font-size:13px;color:#{skin.muted};margin-top:6px;">| <>
            Enum.map_join(
              meta,
              ~s| <span style="color:#{skin.border};">·</span> |,
              &escape_html/1
            ) <>
            "</div>"
        end

      caption = block |> get("caption") |> display_string()

      caption_html =
        if caption == "",
          do: "",
          else:
            ~s|<div class="bp-route__caption" style="font-size:13px;color:#{skin.muted};font-style:italic;margin-top:2px;">#{escape_html(caption)}</div>|

      ~s|<div class="bp-route">| <>
        route_svg(points, track) <> meta_html <> caption_html <> "</div>"
    end
  end

  # The SVG shape: presentation attributes only (no stylesheet dependency), so
  # the same bytes survive a CSS-less client. Width is fluid up to @route_w.
  defp route_svg(points, track) do
    {xs, ys} = project_route(points)
    min_x = Enum.min(xs)
    min_y = Enum.min(ys)
    span_x = max(Enum.max(xs) - min_x, 1.0e-9)
    span_y = max(Enum.max(ys) - min_y, 1.0e-9)

    inner_w = @route_w - 2 * @route_pad
    scale = min(inner_w / span_x, (@route_max_h - 2 * @route_pad) / span_y)
    w = @route_w
    h = round(span_y * scale) + 2 * @route_pad

    coords =
      Enum.zip(xs, ys)
      |> Enum.map(fn {x, y} ->
        {fmt2((x - min_x) * scale + @route_pad), fmt2((y - min_y) * scale + @route_pad)}
      end)

    d =
      coords
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {{x, y}, i} -> "#{if i == 0, do: "M", else: "L"}#{x},#{y}" end)

    {sx, sy} = List.first(coords)
    {fx, fy} = List.last(coords)

    ~s|<svg class="bp-route__map" viewBox="0 0 #{w} #{h}" role="img" aria-label="route track" style="display:block;width:100%;max-width:#{w}px;height:auto;">| <>
      ~s|<path d="#{d}" fill="none" stroke="#{track}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>| <>
      ~s|<circle cx="#{sx}" cy="#{sy}" r="5.5" fill="none" stroke="#{@route_start}" stroke-width="3"/>| <>
      ~s|<circle cx="#{fx}" cy="#{fy}" r="5.5" fill="#{@route_finish}"/>| <>
      "</svg>"
  end

  # Equirectangular projection: x = lng·cos(mid-lat) so a track keeps its aspect
  # away from the equator; y flips (north up) at the caller via (maxLat − lat) —
  # here as negated lat, normalized later.
  defp project_route(points) do
    mid_lat = points |> Enum.map(&elem(&1, 0)) |> then(&(Enum.sum(&1) / length(&1)))
    k = :math.cos(mid_lat * :math.pi() / 180.0)

    {Enum.map(points, fn {_lat, lng} -> lng * k end),
     Enum.map(points, fn {lat, _lng} -> -lat end)}
  end

  defp fmt2(f), do: :erlang.float_to_binary(f / 1, decimals: 2)

  @doc """
  Google encoded-polyline decoder (the Strava/OSRM/Google interchange format):
  ASCII 63–126, 5-decimal fixed point, delta-encoded lat/lng pairs. Returns
  `[{lat, lng}]`; a malformed tail is DROPPED at the last whole pair (render
  what the data supports, never invent) and any non-string yields `[]`.
  """
  def decode_polyline(s) when is_binary(s), do: decode_polyline(s, 0, 0, [])
  def decode_polyline(_), do: []

  defp decode_polyline(<<>>, _lat, _lng, acc), do: Enum.reverse(acc)

  defp decode_polyline(bin, lat, lng, acc) do
    with {dlat, rest} <- decode_chunk(bin, 0, 0),
         {dlng, rest} <- decode_chunk(rest, 0, 0) do
      lat = lat + dlat
      lng = lng + dlng
      decode_polyline(rest, lat, lng, [{lat / 1.0e5, lng / 1.0e5} | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  # One varint chunk: 5-bit groups, char − 63, bit 0x20 continues; the sign
  # rides the low bit (zig-zag).
  defp decode_chunk(<<c, rest::binary>>, shift, acc) when c >= 63 and c <= 126 do
    acc = acc ||| (c - 63 &&& 0x1F) <<< shift

    if (c - 63 &&& 0x20) != 0 do
      decode_chunk(rest, shift + 5, acc)
    else
      value = if (acc &&& 1) != 0, do: -((acc >>> 1) + 1), else: acc >>> 1
      {value, rest}
    end
  end

  defp decode_chunk(_bin, _shift, _acc), do: :malformed

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
