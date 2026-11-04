defmodule Barkpark.PortableDoc.Render.SheetWidthCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render

  @small_width 1_000
  @large_width 2_000
  @samples 5

  for {label, opts} <- [email: %{doctype: false}, article: %{doctype: false, style: :article}] do
    @tag style_path: label
    test "#{label} sheet width rendering grows near-linearly" do
      opts = unquote(Macro.escape(opts))
      small = sheet(@small_width)
      large = sheet(@large_width)

      Render.render_html(small, opts)
      Render.render_html(large, opts)

      ratios =
        for sample <- 1..@samples do
          {small_reductions, large_reductions} = measured_pair(small, large, opts, sample)
          large_reductions / small_reductions
        end

      median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

      assert median_ratio < 3.25,
             "doubling #{unquote(label)} sheet width had a median reduction ratio of #{Float.round(median_ratio, 2)}x"
    end
  end

  defp sheet(width) do
    cells = List.duplicate("x", width)

    %{
      "kind" => "PdSheet",
      "head" => cells,
      "rows" => [cells],
      "col_widths" => List.duplicate(80, width)
    }
  end

  defp measured_pair(small, large, opts, sample) do
    if rem(sample, 2) == 0 do
      large_reductions = render_reductions(large, opts)
      {render_reductions(small, opts), large_reductions}
    else
      small_reductions = render_reductions(small, opts)
      {small_reductions, render_reductions(large, opts)}
    end
  end

  defp render_reductions(sheet, opts) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    Render.render_html(sheet, opts)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end
end
