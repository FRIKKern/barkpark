defmodule Barkpark.PortableDoc.Render.RoadmapCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.Components

  @placeable_small 4_000
  @placeable_large 8_000
  @unplaced_small 8_000
  @unplaced_large 16_000
  @samples 5

  test "placeable roadmap work grows near-linearly with rows and scale" do
    assert_near_linear(
      placeable(@placeable_small),
      placeable(@placeable_large),
      "placeable roadmap rows and scale"
    )
  end

  test "unplaced roadmap fallback grows near-linearly with unique task phases" do
    assert_near_linear(
      unplaced(@unplaced_small),
      unplaced(@unplaced_large),
      "unplaced roadmap rows and phases"
    )
  end

  defp assert_near_linear(small, large, shape) do
    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 2.2,
           "doubling #{shape} had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp placeable(size) do
    %{
      "scale" => Enum.map(1..size, &"month-#{&1}"),
      "snapshot" =>
        Enum.map(1..size, fn index ->
          %{
            "title" => "item-#{index}",
            "status" => "open",
            "left" => rem(index, 100),
            "width" => 1
          }
        end)
    }
  end

  defp unplaced(size) do
    %{
      "snapshot" =>
        Enum.map(1..size, fn index ->
          %{
            "title" => "item-#{index}",
            "status" => "open",
            "phase" => "phase-#{index}"
          }
        end)
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

  defp render_reductions(block) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(block)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(block), do: Components.roadmap_html(block)
end
