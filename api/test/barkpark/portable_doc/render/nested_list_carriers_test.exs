defmodule Barkpark.PortableDoc.Render.NestedListCarriersTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  test "list markers belong to the immediate list, not any ancestor" do
    css = Render.Stylesheet.css()
    assert css =~ ".bp-paper-surface ul > li { list-style: disc; }"
    assert css =~ ".bp-paper-surface ol > li { list-style: decimal; }"
    refute css =~ ".bp-paper-surface ol li {"
    refute css =~ ".bp-paper-surface ul li {"

    for path <- [
          "../../../../assets/paper-editor/src/styles.css",
          "../../../../priv/static/assets/bp-paper-editor-shell.css"
        ] do
      editor_css = File.read!(Path.expand(path, __DIR__))
      assert editor_css =~ ".bp-paper-editor-body ul > li { list-style: disc; }"
      assert editor_css =~ ".bp-paper-editor-body ol > li { list-style: decimal; }"
      refute editor_css =~ ".bp-paper-editor-body ol li {"
      refute editor_css =~ ".bp-paper-editor-body ul li {"
    end
  end

  @fixture Path.expand("../../../support/fixtures/nested-list-carriers.json", __DIR__)

  test "shared nested fixture keeps words, mixed markers and semantic hierarchy" do
    blocks = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("blocks")

    for style <- [:article, :email] do
      html = Render.render_blocks(blocks, %{style: style})
      assert length(Regex.scan(~r/<ul(?:\s[^>]*)?>/, html)) == 2
      assert length(Regex.scan(~r/<ol(?:\s[^>]*)?>/, html)) == 2

      assert %{
               "children" => [
                 %{
                   "children" => [
                     _,
                     %{
                       "kind" => "PdList",
                       "ordered" => true,
                       "children" => [
                         %{"children" => [_, %{"kind" => "PdList", "ordered" => false}]},
                         _
                       ]
                     }
                   ]
                 },
                 _,
                 %{"children" => [_, %{"kind" => "PdList", "ordered" => true}]}
               ]
             } = Barkpark.PortableDoc.Render.Compose.compose_block(hd(blocks), style)

      for word <- [
            "Plan",
            "Build",
            "Verify",
            "Ship",
            "Flat sibling",
            "Fallback parent",
            "Alias child"
          ] do
        assert html =~ word
      end

      refute html =~ "Inactive parent fallback"
    end
  end

  test "invalid nested fields remain opaque and do not alter the flat reader" do
    for children <- [
          nil,
          "not a list",
          %{},
          [%{"type" => "paragraph", "text" => "opaque"}],
          [%{"type" => "list", "items" => "invalid"}]
        ] do
      item = %{"id" => "item", "text" => "Flat", "audit" => true}
      block = %{"type" => "list", "items" => [item]}
      with_children = Map.put(block, "items", [Map.put(item, "children", children)])

      for style <- [:article, :email] do
        assert Render.render_blocks([block], %{style: style}) ==
                 Render.render_blocks([with_children], %{style: style})
      end
    end
  end
end
