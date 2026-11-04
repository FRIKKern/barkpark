defmodule Barkpark.PortableDoc.Render.TableTypedColsCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render.Compose

  @small_width 4_000
  @large_width 8_000
  @samples 5

  test "typed table composition work grows near-linearly with its width" do
    small = table(@small_width)
    large = table(@large_width)

    # Warm the renderer before comparing medians so module loading and the first
    # garbage collection do not decide the scaling result.
    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 3.25,
           "doubling typed table width had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
  end

  defp table(width) do
    %{
      "type" => "table",
      "cols" => List.duplicate(%{"type" => "text"}, width),
      "rows" => [List.duplicate("x", width)]
    }
  end

  defp measured_pair(small, large, sample) do
    # Alternate order so neither width consistently benefits from running
    # second. Reductions count BEAM work in this process without wall-clock
    # scheduler noise.
    if rem(sample, 2) == 0 do
      large_reductions = compose_reductions(large)
      {compose_reductions(small), large_reductions}
    else
      small_reductions = compose_reductions(small)
      {small_reductions, compose_reductions(large)}
    end
  end

  defp compose_reductions(table) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(table)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(table), do: Compose.compose_block(table, :article)
end
