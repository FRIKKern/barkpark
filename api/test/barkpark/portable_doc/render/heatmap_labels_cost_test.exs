defmodule Barkpark.PortableDoc.Render.HeatmapLabelsCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.DataViz

  @small_size 2_000
  @large_size 4_000
  @samples 5

  test "heatmap label work grows near-linearly with its width" do
    assert_near_linear(&wide_heatmap/1, "width")
  end

  test "heatmap label work grows near-linearly with its height" do
    assert_near_linear(&tall_heatmap/1, "height")
  end

  defp assert_near_linear(heatmap, dimension) do
    small = heatmap.(@small_size)
    large = heatmap.(@large_size)

    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 2.3,
           "doubling heatmap #{dimension} had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp wide_heatmap(size) do
    %{
      "type" => "heatmap",
      "cells" => [List.duplicate(1, size)],
      "rowLabels" => ["row"],
      "colLabels" => List.duplicate("column", size)
    }
  end

  defp tall_heatmap(size) do
    %{
      "type" => "heatmap",
      "cells" => List.duplicate([1], size),
      "rowLabels" => List.duplicate("row", size),
      "colLabels" => ["column"]
    }
  end

  defp measured_pair(small, large, sample) do
    if rem(sample, 2) == 0 do
      large_reductions = render_reductions(large)
      {render_reductions(small), large_reductions}
    else
      small_reductions = render_reductions(small)
      {small_reductions, render_reductions(large)}
    end
  end

  defp render_reductions(heatmap) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(heatmap)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(heatmap) do
    DataViz.heatmap_html(heatmap)
    DataViz.heatmap_html(Map.put(heatmap, "mode", "calendar"))
    DataViz.heatmap_html(Map.put(heatmap, "marginals", true))
    DataViz.heatmap_email_html(heatmap)
  end
end
