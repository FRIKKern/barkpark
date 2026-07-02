defmodule Barkpark.PortableDoc.Render.ComposeTest do
  # Pure, in-process — no DB, no plugins needed.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose

  describe "compose_block/1 (email/default style)" do
    test "heading emits a bold PdText span (email mode)" do
      b = %{"type" => "heading", "text" => "Hello", "level" => 1}

      assert Compose.compose_block(b) == %{
               "kind" => "PdText",
               "weight" => "bold",
               "children" => ["Hello"]
             }
    end

    test "heading level defaults to 2 for unknown level" do
      b = %{"type" => "heading", "text" => "X", "level" => 99}
      result = Compose.compose_block(b, :article)
      assert result == %{"kind" => "PdHeading", "level" => 2, "children" => ["X"]}
    end

    test "heading emits semantic PdHeading in article mode" do
      b = %{"type" => "heading", "text" => "Title", "level" => 1}
      result = Compose.compose_block(b, :article)
      assert result == %{"kind" => "PdHeading", "level" => 1, "children" => ["Title"]}
    end

    test "divider emits PdHr in email mode" do
      assert Compose.compose_block(%{"type" => "divider"}) == %{"kind" => "PdHr"}
    end

    test "divider emits _raw html in article mode" do
      result = Compose.compose_block(%{"type" => "divider"}, :article)
      assert result["kind"] == "_raw"
      assert is_binary(result["html"])
    end

    test "action emits PdButton with href and label" do
      b = %{
        "type" => "action",
        "href" => "https://example.com",
        "label" => "Go",
        "priority" => "primary"
      }

      result = Compose.compose_block(b)

      assert result == %{
               "kind" => "PdButton",
               "href" => "https://example.com",
               "label" => "Go",
               "priority" => "primary"
             }
    end

    test "action missing keys defaults to empty strings" do
      b = %{"type" => "action"}
      result = Compose.compose_block(b)
      assert result["href"] == ""
      assert result["label"] == ""
      assert result["priority"] == nil
    end

    test "image emits PdImage with optional dimensions" do
      b = %{
        "type" => "image",
        "src" => "https://example.com/img.png",
        "alt" => "A pic",
        "width" => 400,
        "height" => 300
      }

      result = Compose.compose_block(b)
      assert result["kind"] == "PdImage"
      assert result["src"] == "https://example.com/img.png"
      assert result["alt"] == "A pic"
      assert result["width"] == 400
      assert result["height"] == 300
    end

    test "image without optional dims omits width/height keys" do
      b = %{"type" => "image", "src" => "x.png", "alt" => ""}
      result = Compose.compose_block(b)
      refute Map.has_key?(result, "width")
      refute Map.has_key?(result, "height")
    end

    test "embed block composes to PdEmbed carrying the raw target" do
      b = %{"type" => "embed", "target" => "Note A"}
      assert Compose.compose_block(b) == %{"kind" => "PdEmbed", "target" => "Note A"}
    end

    test "embed with a missing/blank target still composes (renders unresolved)" do
      assert Compose.compose_block(%{"type" => "embed"}) ==
               %{"kind" => "PdEmbed", "target" => ""}

      assert Compose.compose_block(%{"type" => "embed", "target" => ""}) ==
               %{"kind" => "PdEmbed", "target" => ""}
    end

    test "list in email mode uses prefix-as-text scaffold" do
      b = %{"type" => "list", "ordered" => false, "items" => [["Apple"], ["Banana"]]}
      result = Compose.compose_block(b)
      assert result["kind"] == "PdBox"
      [first | _] = result["children"]
      assert first["kind"] == "PdBox"
      [prefix_node | _] = first["children"]
      assert prefix_node["children"] == ["• "]
    end

    test "list in article mode emits PdList with PdListItem children" do
      b = %{"type" => "list", "ordered" => true, "items" => [["First"], ["Second"]]}
      result = Compose.compose_block(b, :article)
      assert result["kind"] == "PdList"
      assert result["ordered"] == true
      assert length(result["children"]) == 2
      [item | _] = result["children"]
      assert item["kind"] == "PdListItem"
    end

    # RENDER BYTE-IDENTITY (obsidian list-item-crash normalize proof). A legacy
    # FLAT-STRING list item and its normalized inline-text-array form compose to
    # the BYTE-IDENTICAL PdNode tree — `compose_inline_children("x")` and
    # `compose_inline_children([%{"type"=>"text","value"=>"x"}])` both yield
    # ["x"]. So normalizing string→inline in the STORED data is provably
    # render-preserving (`body_html` is byte-identical before and after).
    test "string-item list composes IDENTICALLY to its normalized inline-array form (email mode)" do
      string_items = %{"type" => "list", "ordered" => false, "items" => ["one", "two"]}

      inline_items = %{
        "type" => "list",
        "ordered" => false,
        "items" => [
          [%{"type" => "text", "value" => "one"}],
          [%{"type" => "text", "value" => "two"}]
        ]
      }

      assert Compose.compose_block(string_items) == Compose.compose_block(inline_items)
    end

    test "string-item list composes IDENTICALLY to its normalized inline-array form (article mode)" do
      string_items = %{"type" => "list", "ordered" => true, "items" => ["a", "b"]}

      inline_items = %{
        "type" => "list",
        "ordered" => true,
        "items" => [
          [%{"type" => "text", "value" => "a"}],
          [%{"type" => "text", "value" => "b"}]
        ]
      }

      assert Compose.compose_block(string_items, :article) ==
               Compose.compose_block(inline_items, :article)
    end

    # The end-to-end proof the backfill relies on: a whole-paper render of a
    # string-item list yields BYTE-IDENTICAL body_html to the normalized form, in
    # the article palette (the live paper render). This is what makes the data
    # write provably render-preserving — body_html does not change.
    test "render_blocks: string-item list → BYTE-IDENTICAL body_html as the normalized form (article)" do
      opts = %{style: :article}

      string_blocks = [
        %{"id" => "l-1", "type" => "list", "ordered" => false, "items" => ["x", "y"]}
      ]

      inline_blocks = [
        %{
          "id" => "l-1",
          "type" => "list",
          "ordered" => false,
          "items" => [
            [%{"type" => "text", "value" => "x"}],
            [%{"type" => "text", "value" => "y"}]
          ]
        }
      ]

      assert Render.render_blocks(string_blocks, opts) ==
               Render.render_blocks(inline_blocks, opts)
    end

    test "byline with items joins with ·" do
      b = %{"type" => "byline", "items" => ["Alice", "Bob"]}
      result = Compose.compose_block(b, :email)
      assert result["children"] == ["Alice · Bob"]
    end

    test "byline in article mode emits PdParagraph" do
      b = %{"type" => "byline", "text" => "Alice"}
      result = Compose.compose_block(b, :article)
      assert result["kind"] == "PdParagraph"
      assert result["_role"] == "byline"
    end

    test "field-boolean true shows Yes" do
      b = %{"type" => "field-boolean", "label" => "Active", "value" => true}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["Yes"]
    end

    test "field-boolean false shows No" do
      b = %{"type" => "field-boolean", "label" => "Active", "value" => false}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["No"]
    end

    test "field-reference with no value shows em-dash" do
      b = %{"type" => "field-reference", "label" => "Ref", "value" => ""}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["—"]
    end

    test "field-reference falls back to raw id when no _ref_title" do
      b = %{"type" => "field-reference", "label" => "Ref", "value" => "doc-123"}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["doc-123"]
    end

    test "field-reference uses _ref_title when present" do
      b = %{
        "type" => "field-reference",
        "label" => "Ref",
        "value" => "doc-123",
        "_ref_title" => "My Doc"
      }

      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["My Doc"]
    end

    test "sheet block with no snapshot emits empty PdSheet" do
      b = %{"type" => "sheet"}
      result = Compose.compose_block(b)
      assert result["kind"] == "PdSheet"
      assert result["rows"] == []
    end

    test "sheet block with snapshot rows and head" do
      b = %{
        "type" => "sheet",
        "snapshot" => %{
          "head" => ["Name", "Age"],
          "rows" => [["Alice", 30], ["Bob", 25]]
        }
      }

      result = Compose.compose_block(b)
      assert result["kind"] == "PdSheet"
      assert result["head"] == ["Name", "Age"]
      assert result["rows"] == [["Alice", "30"], ["Bob", "25"]]
    end

    # PROCESS RULE: this test used to assert the old `raise ArgumentError` crash
    # contract. Papers are schemaless, so a raw API/SDK/CLI mutate can persist an
    # unknown block type; crashing there took down every render surface (Studio
    # crash-loop, ingest 500, body_html rebuild 500). The engine now degrades to
    # a visible placeholder — the Go twin (pdrender.go fallbackRenderer) already
    # did. Rewritten to assert the degrade node.
    test "unknown block type degrades to a visible bp-unknown-block node (no raise)" do
      result = Compose.compose_block(%{"type" => "nonexistent-type"})
      assert result["kind"] == "_raw"
      assert result["html"] =~ ~s(class="bp-unknown-block")
      assert result["html"] =~ "Unsupported block: nonexistent-type"
    end
  end

  # A schemaless paper can carry a block type this engine has no clause for, a
  # map with no `"type"` at all, or (inside a section / figure child, which call
  # compose_block directly) a non-map entry. Each USED to FunctionClauseError /
  # ArgumentError and 500 every render surface. They now degrade to a visible
  # `bp-unknown-block` placeholder so a poisoned sibling can't sink the render.
  describe "compose_block/2 graceful degrade for unknown / malformed blocks" do
    test "unknown block type HTML-escapes the type name (no markup injection)" do
      result = Compose.compose_block(%{"type" => "<script>", "text" => "x"}, :article)
      assert result["kind"] == "_raw"
      assert result["html"] =~ ~s(class="bp-unknown-block")
      assert result["html"] =~ "Unsupported block: &lt;script&gt;"
      refute result["html"] =~ "<script>"
    end

    test "unknown block type surfaces the type name for the reader" do
      result = Compose.compose_block(%{"type" => "future-widget", "text" => "x"})
      assert result["html"] =~ "Unsupported block: future-widget"
    end

    test "typeless map degrades to an 'invalid block' placeholder" do
      result = Compose.compose_block(%{"text" => "x"})
      assert result["kind"] == "_raw"
      assert result["html"] == ~s(<div class="bp-unknown-block">invalid block</div>)
    end

    test "non-map entry (string or number) degrades instead of FunctionClauseError" do
      for garbage <- ["garbage", 42] do
        result = Compose.compose_block(garbage, :email)
        assert result["kind"] == "_raw"
        assert result["html"] == ~s(<div class="bp-unknown-block">invalid block</div>)
      end
    end

    # End-to-end through the public render pipeline: a poisoned sibling block
    # must not take down its healthy neighbours. render_blocks over a valid
    # paragraph + an unknown-type block still produces the paragraph's HTML AND
    # the degrade placeholder.
    test "render_blocks: a poisoned unknown-type sibling degrades, healthy blocks still render" do
      blocks = [
        %{"id" => "p-1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]},
        %{"id" => "x-1", "type" => "future-widget", "text" => "boom"}
      ]

      html = Render.render_blocks(blocks, %{style: :article})
      assert html =~ "alive"
      assert html =~ ~s(class="bp-unknown-block")
      assert html =~ "Unsupported block: future-widget"
    end

    # A non-map / typeless child inside a SECTION reaches compose_block directly
    # (bypassing render_block's is_map guard). It too degrades through the public
    # render pipeline rather than crashing the whole section.
    test "render_blocks: a non-map child inside a section degrades in place" do
      blocks = [
        %{
          "id" => "s-1",
          "type" => "section",
          "title" => "Sec",
          "blocks" => ["garbage", %{"nope" => true}]
        }
      ]

      html = Render.render_blocks(blocks, %{style: :article})
      assert html =~ "Sec"
      assert html =~ ~s(class="bp-unknown-block")
      assert html =~ "invalid block"
    end
  end

  # A JSON object / array landing in an author-controlled leaf field (text /
  # caption / src / value / label / byline items / sheet cells) used to raise
  # Protocol.UndefinedError (map) or emit a garbled charlist (small-int list),
  # 500-ing the public /papers reader. `stringish/1` degrades them to "" while
  # keeping every working document byte-identical (binaries pass through,
  # numbers stringify unchanged).
  describe "compose_block/2 fail-soft coercion on author-controlled leaf fields" do
    test "eyebrow text as a map degrades to empty children (no 500)" do
      result = Compose.compose_block(%{"type" => "eyebrow", "text" => %{}}, :email)
      assert result["kind"] == "PdText"
      assert result["children"] == [""]
    end

    test "eyebrow text as a list degrades to empty children" do
      result = Compose.compose_block(%{"type" => "eyebrow", "text" => [1, 2]}, :email)
      assert result["children"] == [""]
    end

    test "byline text as a map degrades to empty children" do
      result = Compose.compose_block(%{"type" => "byline", "text" => %{}}, :email)
      assert result["children"] == [""]
    end

    test "embed target as a map degrades to an empty target" do
      assert Compose.compose_block(%{"type" => "embed", "target" => %{}}) ==
               %{"kind" => "PdEmbed", "target" => ""}
    end

    test "field-string value as a map or list degrades to an empty value node" do
      [_label, map_val] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => %{}})[
          "children"
        ]

      assert map_val["children"] == [""]

      [_label2, list_val] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => [1, 2]})[
          "children"
        ]

      assert list_val["children"] == [""]
    end

    test "field-image value as a map degrades to the No image placeholder (no 500)" do
      result = Compose.compose_block(%{"type" => "field-image", "label" => "Img", "value" => %{}})
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["No image"]
    end

    test "field-datetime value as a list degrades to an empty value node (no 500)" do
      result =
        Compose.compose_block(%{"type" => "field-datetime", "label" => "When", "value" => [1, 2]})

      [_label, value_node] = result["children"]
      assert value_node["children"] == [""]
    end

    test "diagram with map source and list caption composes to _raw html without raising" do
      result =
        Compose.compose_block(
          %{"type" => "diagram", "source" => %{}, "caption" => [1, 2]},
          :article
        )

      assert result["kind"] == "_raw"
      assert is_binary(result["html"])
    end

    test "sheet snapshot head and row cells that are maps/lists degrade to empty strings" do
      b = %{
        "type" => "sheet",
        "snapshot" => %{"head" => [%{}, "ok"], "rows" => [[[1, 2], %{}]]}
      }

      result = Compose.compose_block(b)
      assert result["head"] == ["", "ok"]
      assert result["rows"] == [["", ""]]
    end

    test "a plain-integer field value still renders as its decimal string" do
      [_label, value_node] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => 42})[
          "children"
        ]

      assert value_node["children"] == ["42"]
    end

    test "byline integer items still stringify to their decimals" do
      result = Compose.compose_block(%{"type" => "byline", "items" => [1, 2]}, :email)
      assert result["children"] == ["1 · 2"]
    end
  end
end
