defmodule Barkpark.PortableDoc.Render.ChartPointAnnotationsCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.DataViz

  @small_size 1_000
  @large_size 2_000
  @samples 5

  test "chart point annotation work grows near-linearly with points and annotations" do
    small = chart(@small_size)
    large = chart(@large_size)

    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 2.3,
           "doubling chart points and annotations had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp chart(size) do
    %{
      "type" => "chart",
      "series" => [%{"points" => Enum.to_list(1..size)}],
      "annotations" => %{
        "points" =>
          for index <- 0..(size - 1) do
            %{"index" => index, "label" => "point"}
          end
      }
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

  defp render_reductions(chart) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(chart)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(chart), do: DataViz.chart_html(chart)
end
