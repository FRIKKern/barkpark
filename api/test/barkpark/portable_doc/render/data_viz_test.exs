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

  test "author strings are escaped" do
    html =
      DataViz.stat_html(%{"type" => "stat", "value" => "<b>x</b>", "label" => "<script>"})

    refute html =~ "<b>x</b>"
    refute html =~ "<script>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
