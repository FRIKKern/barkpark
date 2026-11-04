defmodule Barkpark.PortableDoc.Render.TableArticleIndexCostTest do
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{Palettes, Walk}

  @samples 5

  test "article table preserves typed, aligned, spanned and sized cell HTML" do
    block = %{
      "type" => "table",
      "headCol" => true,
      "head" => [
        cell("Name"),
        cell("Count", "right"),
        cell("Trend"),
        cell("Delta", "center")
      ],
      "cols" => [
        %{"type" => "text", "width" => 100},
        %{"type" => "num"},
        %{"type" => "spark", "width" => 120},
        %{"type" => "delta", "width" => 140}
      ],
      "rows" => [
        [cell("Alpha", "center"), cell("10", "right"), cell("covered"), cell("2", "right")],
        [cell("Beta"), cell("20"), cell("steady"), cell("-3", "center")]
      ],
      "spans" => [%{"row" => 0, "col" => 1, "colspan" => 2, "rowspan" => 1}]
    }

    expected =
      [
        ~s(<table role="presentation" class="bp-table">),
        ~s(<colgroup><col style="width:100px"><col><col style="width:120px"><col style="width:140px"></colgroup>),
        ~s(<thead><tr>),
        ~s(<th class="bp-table__th"><span>Name</span></th>),
        ~s(<th class="bp-table__th bp-table__th--num" style="text-align:right"><span>Count</span></th>),
        ~s(<th class="bp-table__th bp-table__th--spark"><span>Trend</span></th>),
        ~s(<th class="bp-table__th bp-table__th--num" style="text-align:center"><span>Delta</span></th>),
        ~s(</tr></thead><tbody><tr>),
        ~s(<th scope="row" class="bp-table__th bp-table__th--col" style="text-align:center"><span>Alpha</span></th>),
        ~s(<td class="bp-table__td bp-table__td--num" colspan="2" style="text-align:right"><span>10</span></td>),
        ~s(<td class="bp-table__td bp-table__td--num" style="text-align:right"><span>2</span></td>),
        ~s(</tr><tr>),
        ~s(<th scope="row" class="bp-table__th bp-table__th--col"><span>Beta</span></th>),
        ~s(<td class="bp-table__td bp-table__td--num"><span>20</span></td>),
        ~s(<td class="bp-table__td bp-table__td--spark"><span>steady</span></td>),
        ~s(<td class="bp-table__td bp-table__td--num" style="text-align:center"><span>-3</span></td>),
        ~s(</tr></tbody></table>)
      ]
      |> IO.iodata_to_binary()

    assert render(block) == expected

    absent = %{"type" => "table", "rows" => [["x"]]}

    for invalid_cols <- [nil, %{}, "num", 1] do
      assert render(Map.put(absent, "cols", invalid_cols)) == render(absent)
    end
  end

  test "article table work grows near-linearly with width" do
    assert_near_linear("width", wide_table(1_000), wide_table(2_000))
  end

  test "article table work grows near-linearly with height" do
    assert_near_linear("height", tall_table(2_000), tall_table(4_000))
  end

  test "an invalid unused alignment row keeps the legacy lazy fallback" do
    node = %{
      "kind" => "PdTable",
      "rows" => [[[%{"kind" => "PdText", "children" => ["x"]}]]],
      "aligns" => %{"rows" => [["right"], ["center" | :invalid_tail]]}
    }

    assert Walk.walk(node, 640, Palettes.article_palette()) ==
             ~s(<table role="presentation" class="bp-table"><tbody><tr><td class="bp-table__td" style="text-align:right"><span>x</span></td></tr></tbody></table>)
  end

  defp assert_near_linear(label, small, large) do
    render(small)
    render(large)

    ratios =
      for sample <- 1..@samples do
        {small_reductions, large_reductions} = measured_pair(small, large, sample)
        large_reductions / small_reductions
      end

    median_ratio = ratios |> Enum.sort() |> Enum.at(div(@samples, 2))

    assert median_ratio < 3.25,
           "doubling article table #{label} had a median reduction ratio of #{Float.round(median_ratio, 3)}x"
  end

  defp wide_table(width) do
    cells = List.duplicate(cell("x", "right"), width)

    %{
      "type" => "table",
      "head" => cells,
      "cols" => List.duplicate(%{"type" => "num"}, width),
      "rows" => [cells]
    }
  end

  defp tall_table(height) do
    %{
      "type" => "table",
      "cols" => [%{"type" => "num"}],
      "rows" => List.duplicate([cell("x", "right")], height)
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

  defp render_reductions(table) do
    :erlang.garbage_collect()
    {:reductions, before_count} = Process.info(self(), :reductions)
    render(table)
    {:reductions, after_count} = Process.info(self(), :reductions)

    after_count - before_count
  end

  defp render(table), do: Render.render_block(table, %{style: :article, doctype: false})

  defp cell(value, align \\ nil) do
    %{"content" => [%{"type" => "text", "value" => value}], "align" => align}
  end
end
