defmodule Barkpark.PortableDoc.RenderFieldLimitsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Render, Spec, Validate}
  alias Barkpark.PortableDoc.Render.DataViz

  import Barkpark.PortableDoc.LimitDocs
  import Phoenix.LiveViewTest, only: [render_component: 2]

  @time_us 1_000_000

  def text_cell(value), do: [%{"type" => "text", "value" => value}]

  defp article(block), do: Render.render_block(block, %{style: :article})

  describe "a doc at a field's limit renders in under 1 s and 100 MB" do
    for name <-
          ["toc", "sheet", "table", "heatmap", "route", "record table", "tool diff"] ++
            ["multi edit", "nested columns", "nested section", "big number"],
        style <- [:article, :email] do
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

    test "a merge whose origin is not a stored cell is dropped" do
      html =
        article(%{
          "type" => "sheet",
          "snapshot" => %{
            "rows" => [~w(a b), ~w(c), ~w(d e), ~w(f g)],
            "merges" => [[1, 1, 3, 1]]
          }
        })

      refute html =~ "rowspan"
      assert length(String.split(html, "<td")) == 8
      assert html =~ ">g<"
    end

    test "on a ragged sheet a merge counts only the cells it covers, so it renders" do
      html =
        article(%{
          "type" => "sheet",
          "snapshot" => %{"rows" => [["a", "b", "c"], ["d"]], "merges" => [[0, 0, 2, 3]]}
        })

      assert html =~ ~s(<td colspan="3" rowspan="2")
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

    test "on a ragged table a span counts only the cells it covers, so it renders" do
      html =
        table([[text_cell("a"), text_cell("b"), text_cell("c")], [text_cell("d")]], [
          span(0, 0, 2, 3)
        ])

      assert html =~ ~s( colspan="3" rowspan="2")
      assert length(String.split(html, "<td")) == 2
    end

    test "a span whose origin is not a stored cell is dropped" do
      rows =
        [~w(a b), ~w(c), ~w(d e), ~w(f g)] |> Enum.map(fn row -> Enum.map(row, &text_cell/1) end)

      html = table(rows, [span(1, 1, 3, 1)])
      refute html =~ "rowspan"
      assert length(String.split(html, "<td")) == 8
      assert html =~ ">g<"
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

  describe "table size" do
    @notice "Table too large to show"

    defp records(rows, keys),
      do:
        article(%{
          "type" => "table",
          "columns" => Enum.map(1..keys, &%{"key" => "k#{&1}"}),
          "rows" => List.duplicate(%{}, rows)
        })

    defp plain(cells), do: article(%{"type" => "table", "rows" => [List.duplicate([], cells)]})

    test "an empty 3 by 4 record table renders as a table" do
      html = records(3, 4)
      assert html =~ "<table"
      assert length(String.split(html, "<td")) == 13
    end

    test "a record table of 10 000 cells renders; one row more shows the notice" do
      assert records(100, 100) =~ "<table"
      refute records(100, 100) =~ @notice
      html = records(101, 100)
      assert html =~ @notice
      refute html =~ "<table"
    end

    test "a table of 10 000 stored cells renders; one more shows the notice" do
      assert plain(10_000) =~ "<table"
      assert plain(10_001) =~ @notice
    end

    test "the notice is in the reader's language" do
      html =
        Render.render_block(
          %{"type" => "table", "rows" => [List.duplicate([], 10_001)]},
          %{style: :article, locale: "nb-NO"}
        )

      assert html =~ "Tabellen er for stor til å vises"
    end
  end

  describe "heatmap padding" do
    defp heat(cells, extra \\ %{}, style \\ :article),
      do:
        Render.render_block(Map.merge(%{"type" => "heatmap", "cells" => cells}, extra), %{
          style: style
        })

    defp titles(html), do: ~r/title="([^"]*)"/ |> Regex.scan(html) |> Enum.map(&List.last/1)

    test "short rows pad to the widest row while padding stays within the stored cells" do
      html = heat([[1, 2, 3, 4, 5, 6], [7]])
      assert html =~ "repeat(6,"
      assert titles(html) == ~w(1 2 3 4 5 6 7 0 0 0 0 0)
      refute html =~ "grid-column:span"
    end

    for {mode, extra, style, gap} <- [
          {"grid", %{}, :article, ~s(<i style="grid-column:span 5"></i>)},
          {"calendar", %{"mode" => "calendar"}, :article, ~s(<i style="grid-column:span 5"></i>)},
          {"matrix", %{"values" => true}, :article, ~s(<i style="grid-column:span 5"></i>)},
          {"email", %{}, :email, ~s(<td colspan="5"></td>)}
        ] do
      @extra extra
      @style style
      @gap gap
      test "past that, every stored value still renders and a short row ends in one gap: #{mode}" do
        html = heat([[1, 2, 3, 4, 5, 6], [7], [8]], @extra, @style)
        values = ~w(1 2 3 4 5 6 7 8)
        assert Enum.filter(titles(html), &(&1 in values)) == values
        assert length(String.split(html, @gap)) == 2
      end
    end
  end

  describe "a number past what a chart can draw" do
    test "is left out and the rest of the heatmap renders" do
      html = heat([[Integer.pow(10, 400), 2]])
      assert "2" in titles(html)
    end

    test "never raises in any block of the golden pack, in either style" do
      extremes = [Integer.pow(10, 400), -1.7e308, 1.7e308, 5.0e-324]

      raised =
        for file <- Path.wildcard("priv/portable_doc/goldens/blocks/*.golden.json"),
            block = file |> File.read!() |> Jason.decode!() |> Map.fetch!("input"),
            path <- number_paths(block, []),
            value <- extremes,
            style <- [:article, :email],
            doc = put_path(block, path, value),
            raises?(fn -> Render.render_block(doc, %{style: style}) end),
            uniq: true,
            do: {block["type"], style}

      assert raised == []
    end

    defp number_paths(m, p) when is_map(m),
      do: Enum.flat_map(m, fn {k, v} -> number_paths(v, p ++ [k]) end)

    defp number_paths(l, p) when is_list(l),
      do: l |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> number_paths(v, p ++ [i]) end)

    defp number_paths(n, p) when is_number(n), do: [p]
    defp number_paths(_, _), do: []

    defp put_path(_, [], value), do: value

    defp put_path(m, [k | p], value) when is_map(m),
      do: Map.update!(m, k, &put_path(&1, p, value))

    defp put_path(l, [i | p], value) when is_list(l),
      do: List.update_at(l, i, &put_path(&1, p, value))

    defp raises?(fun) do
      fun.()
      false
    rescue
      _ -> true
    end
  end

  describe "nesting depth" do
    @too_deep "Nested too deep to show"

    defp wrapper("section"), do: &%{"type" => "section", "blocks" => [&1]}
    defp wrapper("columns"), do: &%{"type" => "columns", "columns" => [[&1]]}
    defp wrapper("terminal"), do: &%{"type" => "terminal", "blocks" => [&1]}

    defp wrapper("tabs"),
      do: &%{"type" => "tabs", "tabs" => [%{"label" => "t", "blocks" => [&1]}]}

    defp wrapper("figure"), do: &%{"type" => "figure", "child" => &1}
    defp wrapper("card"), do: &%{"type" => "card", "slots" => %{"body" => [&1]}}
    defp wrapper("expandable"), do: &%{"type" => "expandable", "blocks" => [&1]}

    defp wrapper("steps"),
      do: &%{"type" => "steps", "steps" => [%{"title" => "s", "blocks" => [&1]}]}

    for type <- ~w(section columns terminal tabs figure card expandable steps) do
      @type_name type
      test "#{type}: a block at the validator's depth shows the notice, one above it renders" do
        wrap = wrapper(@type_name)
        max = Validate.max_depth()
        deepest = nest(wrap, max)
        fits = nest(wrap, max - 1)

        for style <- [:article, :email] do
          html = Render.render_block(fits, %{style: style})
          assert html =~ "leaf"
          refute html =~ @too_deep

          html = Render.render_block(deepest, %{style: style})
          assert html =~ @too_deep
          refute html =~ "leaf"
        end

        refute :too_deep in validate_codes(fits)
        assert :too_deep in validate_codes(deepest)
      end
    end

    test "the notice is in the reader's language" do
      doc = nest(&%{"type" => "section", "blocks" => [&1]}, Validate.max_depth())
      html = Render.render_block(doc, %{style: :article, locale: "nb-NO"})
      assert html =~ "For dypt nestet til å vises"
    end

    test "the renderer follows every place the schema holds a block" do
      schema = Spec.path() |> File.read!() |> Jason.decode!()

      from_schema =
        for {_group, defs} <- Map.take(schema["definitions"], ["blocks", "aliases"]),
            {type, def} <- defs,
            path <- block_refs(def, []),
            into: MapSet.new(),
            do: {type, path}

      from_render =
        for {type, paths} <- Render.block_slots(),
            path <- paths,
            into: MapSet.new(),
            do: {type, path}

      assert from_render == from_schema
    end

    defp validate_codes(block) do
      case Validate.validate([block]) do
        :ok -> []
        {:error, errors} -> Enum.map(errors, & &1.code)
      end
    end

    defp block_refs(%{"$ref" => "#"}, path), do: [Enum.reverse(path)]

    defp block_refs(%{} = node, path) do
      Enum.flat_map(node, fn
        {"properties", props} -> Enum.flat_map(props, fn {k, v} -> block_refs(v, [k | path]) end)
        {"items", items} -> block_refs(items, [:each | path])
        {"anyOf", branches} -> Enum.flat_map(branches, &block_refs(&1, path))
        _ -> []
      end)
    end

    defp block_refs(_, _), do: []
  end

  describe "multi edit diffs" do
    test "share one cell budget: an edit past it shows the plain before and after" do
      text = String.duplicate("c\n", 1500)
      [first, second] = Barkpark.PortableDoc.TextDiff.diff_many([{text, text}, {text, text}])

      assert Enum.all?(first, &(&1.op == "="))
      assert Enum.map(second, & &1.op) == List.duplicate("-", 1500) ++ List.duplicate("+", 1500)
    end

    test "the reader and Studio both show an edit past it as before and after" do
      text = String.duplicate("c\n", 1500)
      edit = %{"old_string" => text, "new_string" => text}
      input = %{"file_path" => "f", "edits" => [edit, edit]}

      assert article(%{"type" => "chat-tool-diff", "input" => input}) =~ "+1500"

      studio =
        render_component(&BarkparkWeb.Studio.ChatToolRenderer.tool_diff/1,
          input: input
        )

      assert studio =~ "+1500"
    end

    test "edits within the budget each get the line diff" do
      pairs = [{"a\nb\n", "a\nc\n"}, {"x\ny\n", "y\n"}]

      assert Barkpark.PortableDoc.TextDiff.diff_many(pairs) ==
               Enum.map(pairs, fn {old, new} ->
                 Barkpark.PortableDoc.TextDiff.diff_lines(old, new)
               end)
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

    test "every limit doc but the toc and the nested ones passes it" do
      refused = for {name, block} <- limit_docs(), codes([block]) != [], do: name
      assert refused == ["toc", "nested columns", "nested section"]
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
