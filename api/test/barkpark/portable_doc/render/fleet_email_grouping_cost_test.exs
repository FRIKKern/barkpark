defmodule Barkpark.PortableDoc.Render.FleetEmailGroupingCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.FleetEmail

  @small_size 8_000
  @large_size 16_000
  @samples 5

  test "one email task phase grows near-linearly" do
    assert_near_linear(&tasks_block(&1, fn _ -> "one" end), &FleetEmail.tasks_email_html/1)
  end

  test "unique email task phases grow near-linearly" do
    assert_near_linear(
      fn size -> tasks_block(size, fn index -> "phase-#{index}" end) end,
      &FleetEmail.tasks_email_html/1
    )
  end

  test "an all-unplaced email roadmap fallback grows near-linearly" do
    assert_near_linear(
      fn size ->
        size
        |> tasks_block(fn index -> "phase-#{index}" end)
        |> Map.put("type", "roadmap")
      end,
      &FleetEmail.roadmap_email_html/1
    )
  end

  defp assert_near_linear(input, render) do
    small = input.(@small_size)
    large = input.(@large_size)

    render.(small)
    render.(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(render, small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 2.2,
           "doubling email rows had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp tasks_block(size, phase) do
    %{
      "type" => "tasks",
      "snapshot" =>
        for index <- 1..size do
          %{"title" => "task-#{index}", "status" => "open", "phase" => phase.(index)}
        end
    }
  end

  defp measured_pair(render, small, large, sample) do
    if rem(sample, 2) == 0 do
      large_reductions = render_reductions(render, large)
      {render_reductions(render, small), large_reductions}
    else
      small_reductions = render_reductions(render, small)
      {small_reductions, render_reductions(render, large)}
    end
  end

  defp render_reductions(render, block) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render.(block)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end
end
