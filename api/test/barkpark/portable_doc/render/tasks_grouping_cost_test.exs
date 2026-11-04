defmodule Barkpark.PortableDoc.Render.TasksGroupingCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.Components

  @small_size 8_000
  @large_size 16_000
  @samples 5

  test "task grouping work grows near-linearly for one large phase" do
    assert_near_linear(fn _ -> "one" end)
  end

  test "task grouping work grows near-linearly with the number of phases" do
    assert_near_linear(&"phase-#{&1}")
  end

  defp assert_near_linear(phase) do
    small = rows(@small_size, phase)
    large = rows(@large_size, phase)

    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 2.2,
           "doubling task rows had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp rows(size, phase) do
    for index <- 1..size do
      %{
        "title" => "task-#{index}",
        "status" => "open",
        "phase" => phase.(index)
      }
    end
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

  defp render_reductions(rows) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(rows)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(rows), do: Components.tasks_html(%{"snapshot" => rows})
end
