defmodule Barkpark.PortableDoc.Render.CodeEmphasisCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.Figures

  @small_size 2_500
  @large_size 5_000
  @samples 5

  test "code emphasis work grows near-linearly with lines and authored ranges" do
    small = input(@small_size)
    large = input(@large_size)

    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 3.25,
           "doubling source lines and emphasis ranges had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp input(size) do
    source = 1..size |> Enum.map_join("\n", &"line-#{&1}")
    out_of_bounds = for index <- 1..(size - 1), do: {size + index, size + index, "comment"}

    {source, out_of_bounds ++ [{1, size, "fixed"}]}
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

  defp render_reductions(input) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(input)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render({source, ranges}), do: Figures.code_block_html(source, ranges)
end
