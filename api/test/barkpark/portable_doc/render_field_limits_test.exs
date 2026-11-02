defmodule Barkpark.PortableDoc.RenderFieldLimitsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Render, Spec, Validate}
  alias Barkpark.PortableDoc.Render.DataViz

  import Barkpark.PortableDoc.LimitDocs

  @time_us 1_000_000

  def text_cell(value), do: [%{"type" => "text", "value" => value}]

  defp article(block), do: Render.render_block(block, %{style: :article})

  describe "a doc at a field's limit renders in under 1 s and 100 MB" do
    for name <- ~w(toc sheet table heatmap route), style <- [:article, :email] do
      @name name
      @style style
      test "#{name}, #{style}" do
        {_name, block} = List.keyfind(limit_docs(), @name, 0)
        {us, html} = bounded(fn -> Render.render_block(block, %{style: @style}) end)
        assert is_binary(html)
        assert us < @time_us, "#{@name} took #{div(us, 1000)} ms"
      end
    end
  end

  describe "toc depth" do
    test "shows at most six levels" do
      items = Enum.map(1..8, &toc_item/1)
      toc = fn depth -> article(%{"type" => "toc", "depth" => depth, "items" => items}) end

      assert toc.(7) == toc.(6)
      assert toc.(10_000_000) == toc.(6)
      refute toc.(6) == toc.(5)
    end
  end

  describe "sheet merges" do
    defp sheet(merges),
      do:
        article(%{
          "type" => "sheet",
          "snapshot" => %{"rows" => [["a", "b"], ["c", "d"]], "merges" => merges}
        })

    test "merges that together cover every cell all render" do
      html = sheet([[0, 0, 1, 2], [1, 0, 1, 2]])
      assert length(String.split(html, ~s( colspan="2"))) == 3
      assert length(String.split(html, "<td")) == 3
    end

    test "a merge past the cells left to cover is dropped" do
      html = sheet([[0, 0, 2, 2], [0, 0, 1, 2]])
      assert html =~ ~s(<td colspan="2" rowspan="2")
      assert length(String.split(html, "<td")) == 2
    end
  end

  describe "table spans" do
    defp table(rows, spans), do: article(%{"type" => "table", "rows" => rows, "spans" => spans})

    defp grid, do: [[text_cell("a"), text_cell("b")], [text_cell("c"), text_cell("d")]]

    defp span(row, col, rowspan, colspan),
      do: %{"row" => row, "col" => col, "rowspan" => rowspan, "colspan" => colspan}

    test "spans that together cover every cell all render" do
      html = table(grid(), [span(0, 0, 1, 2), span(1, 0, 1, 2)])
      assert length(String.split(html, ~s( colspan="2"))) == 3
      assert length(String.split(html, "<td")) == 3
    end

    test "the first span at an origin gives the origin its attributes" do
      html = table(grid(), [span(0, 0, 1, 2), span(0, 0, 2, 1)])
      assert html =~ ~s( colspan="2")
      refute html =~ "rowspan"
    end

    test "a span past the cells left to cover is dropped" do
      html =
        table([[text_cell("a"), text_cell("b"), text_cell("c")]], [
          span(0, 0, 1, 2),
          span(0, 1, 1, 2)
        ])

      assert length(String.split(html, "<td")) == 3
      assert html =~ ">c<"
    end
  end

  describe "heatmap padding" do
    defp columns(cells) do
      [_, n] = Regex.run(~r/repeat\((\d+),/, article(%{"type" => "heatmap", "cells" => cells}))
      String.to_integer(n)
    end

    test "short rows pad to the widest row while padding stays within the cells" do
      assert columns([[1, 2, 3, 4, 5, 6], [1]]) == 6
    end

    test "past that, the widest columns drop" do
      assert columns([[1, 2, 3, 4, 5, 6], [1], [1]]) == 5
    end
  end

  describe "route polyline" do
    test "a value of seven five-bit groups decodes" do
      assert DataViz.decode_polyline("~~~~~~" <> "??") == [{-5368.70912, 0.0}]
    end

    test "an eighth group makes the value malformed and the tail drops" do
      assert DataViz.decode_polyline("??" <> "~~~~~~~" <> "??") == [{0.0, 0.0}]
    end
  end

  describe "the schema" do
    defp codes(blocks) do
      case Validate.validate(blocks) do
        :ok -> []
        {:error, errors} -> Enum.map(errors, &{&1.code, &1.path})
      end
    end

    test "toc depth is 1 to 6" do
      assert codes([%{"type" => "toc", "depth" => 6}]) == []
      assert codes([%{"type" => "toc", "depth" => 1}]) == []
      assert codes([%{"type" => "toc", "depth" => 7}]) == [{:value_not_allowed, "/0/depth"}]
      assert codes([%{"type" => "toc", "depth" => 0}]) == [{:value_not_allowed, "/0/depth"}]
    end

    test "a sheet merge number is 0 to the snapshot position cap" do
      cap = Barkpark.Plugins.Sheets.Core.position_cap()
      sheet = fn merge -> [%{"type" => "sheet", "snapshot" => %{"merges" => [merge]}}] end

      assert codes(sheet.([0, 0, cap, 1])) == []

      assert codes(sheet.([0, 0, cap + 1, 1])) == [
               {:value_not_allowed, "/0/snapshot/merges/0/2"}
             ]

      assert codes(sheet.([-1, 0, 1, 2])) == [{:value_not_allowed, "/0/snapshot/merges/0/0"}]
    end

    test "every limit doc but the toc passes it" do
      refused = for {name, block} <- limit_docs(), codes([block]) != [], do: name
      assert refused == ["toc"]
    end

    test "the committed spec carries both maximums" do
      blocks = Spec.path() |> File.read!() |> Jason.decode!() |> get_in(["definitions", "blocks"])
      assert blocks["toc"]["properties"]["depth"]["maximum"] == 6

      assert blocks["sheet"]["properties"]["snapshot"]["properties"]["merges"]["items"]["items"][
               "maximum"
             ] == Barkpark.Plugins.Sheets.Core.position_cap()
    end
  end
end
