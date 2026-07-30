defmodule Barkpark.PortableDoc.Render.DataVizTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.DataViz

  # ── stat ─────────────────────────────────────────────────────────────────────

  test "stat renders the display value verbatim, label, and a sparkline" do
    html =
      DataViz.stat_html(%{
        "type" => "stat",
        "value" => "14/14",
        "label" => "renderers at parity",
        "spark" => [3, 5, 8, 14]
      })

    assert html =~ ~s|class="bp-stat"|
    assert html =~ ">14/14</div>"
    assert html =~ "renderers at parity"
    assert html =~ ~s|class="bp-stat__spark"|
    assert html =~ "<polyline points="
    refute html =~ "bp-stat__bar"
  end

  test "stat with positive max switches to bullet-bar mode with a clamped proportion" do
    html = DataViz.stat_html(%{"type" => "stat", "value" => "3", "max" => 4})
    assert html =~ ~s|class="bp-stat__bar"|
    assert html =~ ~s|style="width:75%"|

    over = DataViz.stat_html(%{"type" => "stat", "value" => "9", "max" => 4})
    assert over =~ ~s|style="width:100%"|
  end

  test "stat value is display-only — never reformatted" do
    html = DataViz.stat_html(%{"type" => "stat", "value" => "$42.10"})
    assert html =~ ">$42.10</div>"
  end

  test "stat without a value degrades to the honest empty box" do
    assert DataViz.stat_html(%{"type" => "stat"}) =~ "bp-dataviz--empty"
    assert DataViz.stat_html(%{"type" => "stat"}) =~ "stat — no data"
  end

  test "stats renders one cell per item and stat-grid aliases through compose" do
    html =
      DataViz.stats_html(%{
        "type" => "stats",
        "items" => [%{"value" => "6"}, %{"value" => "80"}, %{"value" => "97%"}]
      })

    assert html =~ ~s|class="bp-stats"|
    assert 3 == html |> String.split(~s|class="bp-stat"|) |> length() |> Kernel.-(1)

    for t <- ["stats", "stat-grid"] do
      %{"kind" => "_raw", "html" => h} =
        Compose.compose_block(%{"type" => t, "items" => [%{"value" => "1"}]}, :article)

      assert h =~ "bp-stats"
    end
  end

  # ── heatmap ──────────────────────────────────────────────────────────────────

  test "heatmap normalizes intensity against the explicit max and keeps grid shape on junk" do
    html =
      DataViz.heatmap_html(%{
        "type" => "heatmap",
        "max" => 10,
        "cells" => [[10, 5, "junk"], [2.5, 0, 10]],
        "rowLabels" => ["a", "b"],
        "colLabels" => ["Mon", "Tue", "Wed"]
      })

    assert html =~ ~s|style="--i:1.000"|
    assert html =~ ~s|style="--i:0.500"|
    assert html =~ ~s|style="--i:0.250"|
    # junk cell reads as 0 — the grid never shifts columns
    assert html =~ ~s|style="--i:0.000"|
    assert html =~ "Mon"
    assert html =~ ~s|grid-template-columns:auto repeat(3,|
    # 6 data cells + 5 legend swatches (exact-class split — bp-heat__cl would
    # substring-match a bare "bp-heat__c")
    assert 11 == html |> String.split(~s|class="bp-heat__c" style|) |> length() |> Kernel.-(1)
  end

  test "heatmap defaults max to the data max and degrades honestly when empty" do
    html = DataViz.heatmap_html(%{"type" => "heatmap", "cells" => [[2, 4]]})
    assert html =~ ~s|style="--i:1.000"|
    assert html =~ ~s|style="--i:0.500"|

    assert DataViz.heatmap_html(%{"type" => "heatmap"}) =~ "bp-dataviz--empty"
    assert DataViz.heatmap_html(%{"type" => "heatmap", "cells" => []}) =~ "bp-dataviz--empty"
  end

  # ── chart ────────────────────────────────────────────────────────────────────

  test "chart renders one polyline per series plus ticks, x labels and a legend" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "caption" => "Blocks at parity",
        "series" => [
          %{"label" => "renderers", "points" => [3, 5, 8]},
          %{"label" => "goldens", "points" => [1, 4, 6]}
        ],
        "axes" => %{"min" => 0, "xLabels" => ["w1", "", "w3"]}
      })

    assert html =~ "Blocks at parity"
    assert 2 == html |> String.split("<polyline") |> length() |> Kernel.-(1)
    assert html =~ "bp-chart__s0"
    assert html =~ "bp-chart__s1"
    assert html =~ ">w1</text>"
    assert html =~ ">w3</text>"
    assert html =~ "renderers"
    assert html =~ "bp-chart__legend"
    # min pinned to 0 → the bottom tick reads 0
    assert html =~ ">0</text>"
  end

  test "chart annotations: region wash behind the plot, tone class, centered label" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"label" => "crime", "points" => [80, 30, 20, 35, 75]}],
        "axes" => %{"min" => 0, "max" => 100},
        "annotations" => %{
          "regions" => [
            %{"from" => 0, "to" => 1.5, "label" => "NORM COLLAPSE", "tone" => "warn"},
            %{"from" => 3, "to" => 4, "tone" => "danger"}
          ]
        }
      })

    assert html =~ ~s(class="bp-chart__region bp-chart__region--warn")
    assert html =~ ~s(class="bp-chart__region bp-chart__region--danger")
    assert html =~ ">NORM COLLAPSE</text>"
    # the wash renders BEFORE the series polyline (behind it in paint order)
    assert :binary.match(html, "bp-chart__region") |> elem(0) <
             :binary.match(html, "<polyline") |> elem(0)
  end

  test "chart annotations: refLine at the data y with right-aligned label above it" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"label" => "count", "points" => [0, 10]}],
        "axes" => %{"min" => 0, "max" => 10},
        "annotations" => %{"refLines" => [%{"y" => 5, "label" => "target", "tone" => "ok"}]}
      })

    assert html =~ ~s(class="bp-chart__refline bp-chart__refline--ok")
    assert html =~ ">target</text>"
    # refLines paint ABOVE the series
    assert :binary.match(html, "bp-chart__refline") |> elem(0) >
             :binary.match(html, "<polyline") |> elem(0)
  end

  test "chart annotations: point callout anchors at the series datum" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"label" => "s", "points" => [0, 100, 0]}],
        "axes" => %{"min" => 0, "max" => 100},
        "annotations" => %{"points" => [%{"index" => 1, "label" => "the peak"}]}
      })

    assert html =~ "bp-chart__pt"
    assert html =~ ">the peak</text>"
    # datum at max with min pinned 0 → the marker sits at the TOP pad (y=8)
    assert html =~ ~s(cy="8")
  end

  test "chart annotations are fail-soft and escaped: junk coordinates drop, labels never inject" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"label" => "s", "points" => [1, 2]}],
        "annotations" => %{
          "regions" => [
            %{"from" => "x", "to" => 1, "label" => "dropped"},
            %{"from" => 1, "to" => 0}
          ],
          "refLines" => [%{"label" => "no y"}],
          "points" => [
            %{"index" => 99, "label" => "out of range"},
            %{"index" => 0, "label" => "<img onerror=x>"}
          ]
        }
      })

    refute html =~ "dropped"
    refute html =~ "bp-chart__region"
    refute html =~ "bp-chart__refline"
    refute html =~ "out of range"
    refute html =~ "<img"
    assert html =~ "&lt;img onerror=x&gt;"
  end

  test "chart without annotations is byte-identical to before (no annotation markup)" do
    block = %{"type" => "chart", "series" => [%{"label" => "s", "points" => [1, 2, 3]}]}
    html = DataViz.chart_html(block)

    refute html =~ "bp-chart__region"
    refute html =~ "bp-chart__refline"
    refute html =~ "bp-chart__ann"
    refute html =~ "bp-chart__pt"
  end

  test "chart clamps out-of-span points to the pinned edge (pdrender semantics)" do
    # max pinned to 5: the point at 10 must land on the SAME y as a point at 5.
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [0, 5, 10]}],
        "axes" => %{"min" => 0, "max" => 5}
      })

    [_, pts] = Regex.run(~r/points="([^"]+)"/, html)
    ys = pts |> String.split(" ") |> Enum.map(fn p -> p |> String.split(",") |> List.last() end)
    assert Enum.at(ys, 1) == Enum.at(ys, 2)
  end

  test "chart ignores malformed pins (both pinned, min >= max) and auto-scales" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [2, 8]}],
        "axes" => %{"min" => 9, "max" => 1}
      })

    # auto-scale: top tick is the data max
    assert html =~ ">8</text>"
    assert html =~ ">2</text>"
  end

  test "chart bars mode emits floor-anchored rects; empty series drop; none → empty box" do
    html =
      DataViz.chart_html(%{
        "type" => "chart",
        "kind" => "bars",
        "series" => [%{"label" => "a", "points" => [1, 3]}, %{"points" => []}]
      })

    assert 2 == html |> String.split("<rect") |> length() |> Kernel.-(1)
    refute html =~ "<polyline"
    # bars imply a zero baseline when min is unpinned → bottom tick reads 0
    assert html =~ ">0</text>"

    assert DataViz.chart_html(%{"type" => "chart", "series" => [%{"points" => []}]}) =~
             "bp-dataviz--empty"
  end

  # ── slate-2: stat denominator ────────────────────────────────────────────────

  test "stat denom renders a dim /denom suffix riding the value; absent denom is byte-identical" do
    with_denom =
      DataViz.stat_html(%{
        "type" => "stat",
        "value" => 71,
        "denom" => 118,
        "label" => "tasks done"
      })

    assert with_denom =~ ~s|>71<span class="bp-stat__denom">/118</span></div>|

    without =
      DataViz.stat_html(%{"type" => "stat", "value" => 71, "label" => "tasks done"})

    refute without =~ "bp-stat__denom"
    # denom-less output is the with-denom output minus EXACTLY the suffix span —
    # every other byte identical (stat.go's "byte-identical to before" law).
    assert without ==
             String.replace(with_denom, ~s|<span class="bp-stat__denom">/118</span>|, "")
  end

  test "stat denom joins bullet-bar mode and is escaped" do
    html =
      DataViz.stat_html(%{"type" => "stat", "value" => 71, "max" => 118, "denom" => 118})

    assert html =~ "bp-stat__bar"
    assert html =~ ~s|<span class="bp-stat__denom">/118</span>|

    evil = DataViz.stat_html(%{"type" => "stat", "value" => "1", "denom" => "<x>"})
    refute evil =~ "<x>"
    assert evil =~ "/&lt;x&gt;"
  end

  # ── slate-2: heatmap calendar mode ───────────────────────────────────────────

  # nz = [1,3,3,3,4,5,7,7,38] → nearest-rank quartiles q1=3, q2=4, q3=7:
  # 38 lands in bin 3, 4 in bin 1, 5/7 in bin 2, 1/3 in bin 0, zeros in --z.
  @cal_block %{
    "type" => "heatmap",
    "mode" => "calendar",
    "rowLabels" => ["M", "", "W"],
    "colLabels" => ["Jan", "", "", "", "Feb"],
    "cells" => [[3, 5, 0, 7, 1], [0, 3, 0, 0, 3], [0, 7, 0, 4, 38]]
  }

  test "heatmap calendar renders day-rows x week-cols in a scrollable container with ALL weeks" do
    html = DataViz.heatmap_html(@cal_block)

    assert html =~ ~s|class="bp-heat bp-heat--cal"|
    assert html =~ ~s|class="bp-heat__scroll"|
    # all 5 weeks render at a fixed track — the web scrolls, never width-drops
    assert html =~ "repeat(5,12px)"
    # month labels along the top, day letters in the gutter
    assert html =~ ~s|<span class="bp-heat__ml">Jan</span>|
    assert html =~ ~s|<span class="bp-heat__rl">M</span>|
    # 15 data cells + 4 legend swatches, all bin-classed
    assert 19 ==
             html |> String.split(~s|class="bp-heat__c bp-heat__c--|) |> length() |> Kernel.-(1)
  end

  test "heatmap calendar quantile-bins by nonzero quartiles and dual-encodes every bin" do
    html = DataViz.heatmap_html(@cal_block)

    # the spike owns bin 3 alone — quantile binning spreads the rest instead of
    # flattening months of ordinary activity off one spike (HeatQuantileBins law)
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b3" title="38"></i>|
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b2" title="7"></i>|
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b1" title="4"></i>|
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b0" title="3"></i>|
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--z" title="0"></i>|
    # ragged rows keep the calendar shape: missing weeks read as zero cells
    ragged =
      DataViz.heatmap_html(%{"type" => "heatmap", "mode" => "calendar", "cells" => [[1, 2], [3]]})

    assert ragged =~ "repeat(2,12px)"
    assert ragged =~ ~s|bp-heat__c--z" title="0"|
  end

  test "slate-2 modes ride the ONE article emitter through compose; the email variant is untouched" do
    %{"kind" => "_raw", "html" => article} = Compose.compose_block(@cal_block, :article)
    assert article =~ "bp-heat--cal"

    # the gate-locked email emitter ignores the new mode: same inline table read
    %{"kind" => "_raw", "html" => email} = Compose.compose_block(@cal_block, :email)
    assert email =~ "<table"
    refute email =~ ~s(class="bp-)
  end

  test "a uniform grid is genuinely uniform — single distinct value puts every nonzero cell in bin 0" do
    html =
      DataViz.heatmap_html(%{
        "type" => "heatmap",
        "mode" => "calendar",
        "cells" => [[5, 5], [0, 5]]
      })

    [grid_part | _] = String.split(html, "bp-heat__legend")
    assert grid_part =~ "bp-heat__c--b0"
    refute grid_part =~ "bp-heat__c--b1"
    refute grid_part =~ "bp-heat__c--b2"
    refute grid_part =~ "bp-heat__c--b3"
  end

  # ── slate-2: heatmap matrix marginals / values ───────────────────────────────

  test "heatmap values:true prints the exact value with the bin class on the SAME cell (dual-encode)" do
    html =
      DataViz.heatmap_html(%{
        "type" => "heatmap",
        "marginals" => true,
        "values" => true,
        "rowLabels" => ["Ada", "Lin", "Sam", "Ravi"],
        "colLabels" => ["Expl", "Buil", "Rev", "Ship", "Docs"],
        "cells" => [[12, 34, 6, 9, 3], [4, 18, 2, 21, 0], [0, 7, 11, 4, 8], [9, 2, 0, 15, 1]]
      })

    assert html =~ ~s|class="bp-heat bp-heat--mtx"|
    # bin class + exact value TEXT together on one cell — the two channels can
    # never disagree because one quantile_bins call drives both
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b3 bp-heat__c--v" title="34">34</i>|
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--z bp-heat__c--v" title="0">0</i>|
    # Σ marginals: row sums, col sums, grand total, headers
    assert html =~ ~s|<span class="bp-heat__cl bp-heat__cl--sum">Σ</span>|
    assert html =~ ~s|<span class="bp-heat__rl">Σ</span>|
    assert html =~ ~s|<span class="bp-heat__sum">64</span>|
    assert html =~ ~s|<span class="bp-heat__sum">25</span>|
    assert html =~ ~s|<span class="bp-heat__sum bp-heat__sum--grand">166</span>|
    assert html =~ ~s|<span class="bp-heat__rl">Ada</span>|
  end

  test "heatmap marginals without values keeps shade cells and still sums" do
    html =
      DataViz.heatmap_html(%{
        "type" => "heatmap",
        "marginals" => true,
        "rowLabels" => ["Q1", "Q2", "Q3"],
        "colLabels" => ["Web", "API", "CLI", "TUI"],
        "cells" => [[3, 9, 0, 14], [7, 2, 11, 1], [0, 5, 4, 20]]
      })

    # cells stay pure shade (no --v, no text) — the bin marker is the 2nd channel
    assert html =~ ~s|<i class="bp-heat__c bp-heat__c--b3" title="20"></i>|
    refute html =~ "bp-heat__c--v"
    assert html =~ ~s|<span class="bp-heat__sum">26</span>|
    assert html =~ ~s|<span class="bp-heat__sum">35</span>|
    assert html =~ ~s|<span class="bp-heat__sum bp-heat__sum--grand">76</span>|
  end

  # ── slate-2: byte-stability of the untouched paths ───────────────────────────

  test "heatmap without mode/flags renders the legacy grid byte-for-byte (pinned)" do
    assert DataViz.heatmap_html(%{"type" => "heatmap", "cells" => [[1, 0]]}) ==
             ~s|<div class="bp-heat"><div class="bp-heat__grid" style="grid-template-columns:repeat(2,minmax(10px,28px))">| <>
               ~s|<i class="bp-heat__c" style="--i:1.000" title="1"></i>| <>
               ~s|<i class="bp-heat__c" style="--i:0.000" title="0"></i>| <>
               ~s|</div><div class="bp-heat__legend">less | <>
               ~s|<i class="bp-heat__c" style="--i:0.150"></i>| <>
               ~s|<i class="bp-heat__c" style="--i:0.350"></i>| <>
               ~s|<i class="bp-heat__c" style="--i:0.550"></i>| <>
               ~s|<i class="bp-heat__c" style="--i:0.750"></i>| <>
               ~s|<i class="bp-heat__c" style="--i:1.000"></i>| <>
               " more</div></div>"
  end

  test "explicit false flags and unknown modes stay on the legacy grid" do
    for block <- [
          %{"type" => "heatmap", "cells" => [[2, 4]], "marginals" => false, "values" => false},
          %{"type" => "heatmap", "cells" => [[2, 4]], "mode" => "grid"}
        ] do
      html = DataViz.heatmap_html(block)
      assert html =~ "--i:"
      refute html =~ "bp-heat--cal"
      refute html =~ "bp-heat__c--b"
    end
  end

  # ── slate-2: compact chart ticks ─────────────────────────────────────────────

  test "chart y-ticks compact to k/M/B at abs >= 10000, trailing .0 trimmed, sign preserved" do
    forty_k =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [0, 40_000]}],
        "axes" => %{"min" => 0, "max" => 40_000}
      })

    assert forty_k =~ ">40k</text>"
    assert forty_k =~ ">26.7k</text>"
    assert forty_k =~ ">13.3k</text>"
    assert forty_k =~ ">0</text>"

    millions =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [0, 45_500_000]}],
        "axes" => %{"min" => 0, "max" => 45_500_000}
      })

    assert millions =~ ">45.5M</text>"
    assert millions =~ ">30.3M</text>"

    billions =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [0, 2_000_000_000]}],
        "axes" => %{"min" => 0, "max" => 2_000_000_000}
      })

    assert billions =~ ">2B</text>"

    negative =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [-45_500_000, 0]}],
        "axes" => %{"min" => -45_500_000, "max" => 0}
      })

    assert negative =~ ">-45.5M</text>"
  end

  test "chart y-ticks below 10000 are byte-identical to before and series keep the web 4-ceiling" do
    below =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [%{"points" => [0, 9_999]}],
        "axes" => %{"min" => 0, "max" => 9_999}
      })

    assert below =~ ">9999</text>"
    refute below =~ "k</text>"

    # web keeps up-to-4 series — the TUI's 2-cap is a terminal-legibility
    # ceiling, never a block contract (charter D4, ratified divergence)
    four =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => [
          %{"points" => [1, 2]},
          %{"points" => [2, 3]},
          %{"points" => [3, 4]},
          %{"points" => [4, 5]}
        ]
      })

    assert 4 == four |> String.split("<polyline") |> length() |> Kernel.-(1)
    assert four =~ "bp-chart__s3"
  end

  test "chart excludes a fifth series from the plot, legend, and autoscale" do
    first_four = [
      %{"label" => "one", "points" => [0, 3]},
      %{"label" => "two", "points" => [0, 6]},
      %{"label" => "three", "points" => [0, 9]},
      %{"label" => "four", "points" => [0, 12]}
    ]

    four = DataViz.chart_html(%{"type" => "chart", "series" => first_four})

    five =
      DataViz.chart_html(%{
        "type" => "chart",
        "series" => first_four ++ [%{"label" => "dropped", "points" => [0, 999_999]}]
      })

    assert five == four
    assert 4 == five |> String.split("<polyline") |> length() |> Kernel.-(1)

    assert 4 ==
             five
             |> String.split(~s|<span class="bp-chart__key">|)
             |> length()
             |> Kernel.-(1)

    refute five =~ "dropped"
  end

  # ── compose dispatch + escaping ──────────────────────────────────────────────

  test "compose_block routes all four slate types to DataViz as _raw" do
    for {block, marker} <- [
          {%{"type" => "stat", "value" => "1"}, "bp-stat"},
          {%{"type" => "heatmap", "cells" => [[1]]}, "bp-heat"},
          {%{"type" => "chart", "series" => [%{"points" => [1, 2]}]}, "bp-chart"}
        ] do
      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :article)
      assert html =~ marker
      refute html =~ "Unsupported block"
    end
  end

  test "email style takes the inline-styled variants — no classed SVG blobs" do
    for {block, marker} <- [
          {%{"type" => "stat", "value" => "14/14", "label" => "parity", "spark" => [1, 2]},
           "font-size:24px"},
          {%{"type" => "stats", "items" => [%{"value" => "6"}]}, "font-size:24px"},
          {%{"type" => "heatmap", "cells" => [[1.0, 0.5]]}, "<table"},
          {%{"type" => "chart", "series" => [%{"label" => "a", "points" => [1, 5, 3]}]},
           "1 → 5 · now 3"}
        ] do
      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :email)
      assert html =~ marker
      refute html =~ "<svg"
      refute html =~ ~s(class="bp-)
    end

    # heatmap intensity is baked into bgcolor in Elixir: 1.0 → the accent.
    %{"kind" => "_raw", "html" => heat} =
      Compose.compose_block(%{"type" => "heatmap", "cells" => [[1.0, 0.0]]}, :email)

    assert heat =~ "background:#1e5347"
    assert heat =~ "background:#eaf1ee"
  end

  test "author strings are escaped" do
    html =
      DataViz.stat_html(%{"type" => "stat", "value" => "<b>x</b>", "label" => "<script>"})

    refute html =~ "<b>x</b>"
    refute html =~ "<script>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end

  # ── gauge-list ───────────────────────────────────────────────────────────────

  test "gauge-list share mode: author order, value/max proportion, percent readout, note" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "mode" => "share",
        "title" => "judge votes",
        "max" => 12,
        "rows" => [
          %{"label" => "regular", "value" => 11, "note" => "won 3 duels"},
          %{"label" => "optical", "value" => 1}
        ]
      })

    assert html =~ ~s|class="bp-gauge"|
    assert html =~ "judge votes"
    # author order preserved: regular before optical
    assert :binary.match(html, "regular") < :binary.match(html, "optical")
    # meter = value/max: 11/12 → 92%, 1/12 → 8%
    assert html =~ ~s|style="width:91.7%"|
    assert html =~ ">92%</span>"
    assert html =~ ">8%</span>"
    assert html =~ "won 3 duels"
  end

  test "gauge-list share mode without max divides by the sum; clamps negatives" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "rows" => [
          %{"label" => "a", "value" => 3},
          %{"label" => "b", "value" => 1},
          %{"label" => "neg", "value" => -5}
        ]
      })

    # bare rows + no snapshot infers share mode; denom = Σ = 4 (neg contributes -5 to sum
    # per pdrender attrFloat semantics? No: pdrender sums raw values; mirror = 3+1-5=-1 → guard 1)
    # our port mirrors: sum <= 0 → denom 1; a=3 clamps to 100%, neg clamps to 0%.
    assert html =~ ~s|class="bp-gauge"|
    assert html =~ ">100%</span>"
    assert html =~ ">0%</span>"
  end

  test "gauge-list count mode buckets a snapshot, sorts desc-count then label, (none) bucket" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "mode" => "count",
        "groupBy" => "status",
        "snapshot" => [
          %{"status" => "open"},
          %{"status" => "open"},
          %{"status" => "closed"},
          %{"title" => "no status"}
        ]
      })

    assert html =~ ~s|class="bp-gauge"|
    # open(2) first, then the count-1 buckets label-ASC: "(none)" < "closed"
    # (byte order — '(' sorts before 'c'), mirroring gaugelist.go exactly.
    assert :binary.match(html, "open") < :binary.match(html, "(none)")
    assert :binary.match(html, "(none)") < :binary.match(html, "closed")
    # counts as readout digits, meter = count/maxCount
    assert html =~ ">2</span>"
    assert html =~ ~s|style="width:100%"|
    assert html =~ ~s|style="width:50%"|
  end

  test "gauge-list count mode: priority buckets wear the P<n> label" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "mode" => "count",
        "groupBy" => "priority",
        "snapshot" => [%{"priority" => 1}, %{"priority" => 1}, %{"priority" => 0}]
      })

    assert html =~ "P1"
    assert html =~ "P0"
  end

  test "gauge-list groupBy epic renders the honest unbacked note, never fakes" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "mode" => "count",
        "groupBy" => "epic",
        "snapshot" => [%{"parent_id" => "t1", "status" => "open"}]
      })

    assert html =~ "unbacked"
    refute html =~ "bp-gauge__bar"
  end

  test "gauge-list absent data degrades to the honest empty box; query is never read" do
    for block <- [
          %{"type" => "gauge-list"},
          %{"type" => "gauge-list", "mode" => "share"},
          %{"type" => "gauge-list", "mode" => "count", "query" => %{"groupBy" => "status"}}
        ] do
      html = DataViz.gauge_list_html(block)
      assert html =~ "bp-dataviz--empty"
      assert html =~ "gauge-list"
    end
  end

  test "gauge-list email variant is inline-styled, classless, and table-based" do
    %{"kind" => "_raw", "html" => html} =
      Compose.compose_block(
        %{
          "type" => "gauge-list",
          "mode" => "share",
          "max" => 10,
          "rows" => [%{"label" => "a", "value" => 5, "note" => "half"}]
        },
        :email
      )

    assert html =~ "<table"
    assert html =~ "width:50%"
    assert html =~ ">50%</td>"
    assert html =~ "half"
    refute html =~ ~s(class="bp-)
  end

  test "gauge-list article dispatch rides the classed emitter" do
    %{"kind" => "_raw", "html" => html} =
      Compose.compose_block(
        %{"type" => "gauge-list", "rows" => [%{"label" => "a", "value" => 1}]},
        :article
      )

    assert html =~ ~s|class="bp-gauge"|
  end

  test "gauge-list author strings are escaped" do
    html =
      DataViz.gauge_list_html(%{
        "type" => "gauge-list",
        "title" => "<script>",
        "rows" => [%{"label" => "<b>x</b>", "value" => 1, "note" => "<i>n</i>"}]
      })

    refute html =~ "<script>"
    refute html =~ "<b>x</b>"
    refute html =~ "<i>n</i>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
