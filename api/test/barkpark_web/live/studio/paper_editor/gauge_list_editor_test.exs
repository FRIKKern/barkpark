defmodule BarkparkWeb.Studio.PaperEditor.GaugeListEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "gauge lists are available in the add block menu" do
    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [])
    tree = LazyHTML.from_fragment(html)
    assert tree |> LazyHTML.query("option[value='gauge-list']") |> LazyHTML.text() == "Gauge list"
  end

  test "share gauges retain their preview and expose ordered authored row controls" do
    block = %{
      "id" => "gauge",
      "type" => "gauge-list",
      "title" => "Coverage",
      "rows" => [%{"label" => "Passing", "value" => 8, "note" => "Verified"}]
    }

    for canvas <- [false, true] do
      html =
        render_component(&PaperEditor.paper_block_fields/1, block: block, canvas_enabled: canvas)

      tree = LazyHTML.from_fragment(html)
      assert html =~ "paper-gauge-list-preview"
      assert html =~ "Configure gauge list"
      assert html =~ "Passing"

      refute Enum.empty?(
               LazyHTML.query(
                 tree,
                 "details.bp-paper-contextual-controls--gauge-list:not([open])"
               )
             )

      assert tree |> LazyHTML.query("input[name='gauge-count']") |> LazyHTML.attribute("value") ==
               ["1"]

      assert tree |> LazyHTML.query("input[name='gauge-0-note']") |> LazyHTML.attribute("value") ==
               ["Verified"]

      assert tree |> LazyHTML.query("button[name='gauge-action']") |> LazyHTML.attribute("value") ==
               ["up:0", "down:0", "remove:0", "add"]

      refute html =~ "blocks are not editable yet"
    end
  end

  test "count gauges expose grouping without an editable snapshot payload" do
    block = %{
      "id" => "gauge",
      "type" => "gauge-list",
      "mode" => "count",
      "groupBy" => " status ",
      "snapshot" => [%{"status" => "done"}]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)

    assert tree |> LazyHTML.query("input[name='groupBy']") |> LazyHTML.attribute("value") == [
             "status"
           ]

    assert html =~ "Snapshot data is preserved"
    assert Enum.empty?(LazyHTML.query(tree, "[name='snapshot']"))
    assert Enum.empty?(LazyHTML.query(tree, "[name='gauge-count']"))
  end

  test "malformed share rows keep scalar controls without offering rejected row actions" do
    for rows <- ["legacy", [%{"label" => "Valid", "value" => 1}, "legacy"]] do
      html =
        render_component(&PaperEditor.paper_block_fields/1,
          block: %{"id" => "gauge", "type" => "gauge-list", "mode" => "share", "rows" => rows}
        )

      tree = LazyHTML.from_fragment(html)
      assert html =~ "Original rows are preserved"
      refute Enum.empty?(LazyHTML.query(tree, "[name='title']"))
      refute Enum.empty?(LazyHTML.query(tree, "[name='mode']"))
      refute Enum.empty?(LazyHTML.query(tree, "[name='max']"))
      assert Enum.empty?(LazyHTML.query(tree, "[name='gauge-count']"))
      assert Enum.empty?(LazyHTML.query(tree, "[name='gauge-action']"))
      assert Enum.empty?(LazyHTML.query(tree, "[name^='gauge-']"))
    end
  end
end
