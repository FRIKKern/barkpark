defmodule Barkpark.PortableDoc.Render.InlineTest do
  # Pure, in-process inline composer — no DB.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Inline

  describe "compose_inline_children/1" do
    test "maps text nodes to their string values" do
      nodes = [
        %{"type" => "text", "value" => "hello"},
        %{"type" => "text", "value" => " world"}
      ]

      assert Inline.compose_inline_children(nodes) == ["hello", " world"]
    end

    test "tolerates a bare binary (table cell scalar)" do
      assert Inline.compose_inline_children("plain text") == ["plain text"]
    end

    test "tolerates a number scalar" do
      assert Inline.compose_inline_children(42) == ["42"]
    end

    test "returns empty list for other scalars" do
      assert Inline.compose_inline_children(nil) == []
      assert Inline.compose_inline_children(%{}) == []
    end
  end

  describe "compose_inline/2 — text node" do
    test "returns the value string for a plain text node" do
      node = %{"type" => "text", "value" => "hello"}
      assert Inline.compose_inline(node, false) == "hello"
    end

    test "returns empty string when value is missing" do
      node = %{"type" => "text"}
      assert Inline.compose_inline(node, false) == ""
    end

    test "wraps with bold mark" do
      node = %{"type" => "text", "value" => "bold", "marks" => [%{"type" => "bold"}]}
      result = Inline.compose_inline(node, false)

      assert %{"kind" => "PdText", "weight" => "bold", "children" => ["bold"]} = result
    end

    test "wraps with italic mark" do
      node = %{"type" => "text", "value" => "italic", "marks" => [%{"type" => "em"}]}
      result = Inline.compose_inline(node, false)

      assert %{"kind" => "PdText", "italic" => true, "children" => ["italic"]} = result
    end

    test "empty marks list returns plain value" do
      node = %{"type" => "text", "value" => "plain", "marks" => []}
      assert Inline.compose_inline(node, false) == "plain"
    end
  end

  describe "compose_inline/2 — typed nodes" do
    test "strong node emits bold PdText" do
      node = %{"type" => "strong", "children" => [%{"type" => "text", "value" => "hi"}]}
      result = Inline.compose_inline(node, false)

      assert %{"kind" => "PdText", "weight" => "bold", "children" => ["hi"]} = result
    end

    test "em node emits italic PdText" do
      node = %{"type" => "em", "children" => [%{"type" => "text", "value" => "slant"}]}
      result = Inline.compose_inline(node, false)

      assert %{"kind" => "PdText", "italic" => true, "children" => ["slant"]} = result
    end

    test "code node emits PdInlineCode with value" do
      node = %{"type" => "code", "value" => "IO.puts"}

      assert Inline.compose_inline(node, false) == %{
               "kind" => "PdInlineCode",
               "value" => "IO.puts"
             }
    end

    test "code node defaults value to empty string" do
      node = %{"type" => "code"}
      assert Inline.compose_inline(node, false) == %{"kind" => "PdInlineCode", "value" => ""}
    end

    test "link node emits PdLink with href and children" do
      node = %{
        "type" => "link",
        "href" => "https://example.com",
        "children" => [%{"type" => "text", "value" => "click"}]
      }

      result = Inline.compose_inline(node, false)

      assert %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["click"]} =
               result
    end

    test "nested link (inside_link: true) flattens to PdText" do
      node = %{
        "type" => "link",
        "href" => "https://example.com",
        "children" => [%{"type" => "text", "value" => "inner"}]
      }

      result = Inline.compose_inline(node, true)
      assert %{"kind" => "PdText", "children" => ["inner"]} = result
      refute Map.has_key?(result, "href")
    end

    test "tag node emits PdTag with name" do
      node = %{"type" => "tag", "name" => "elixir"}
      assert Inline.compose_inline(node, false) == %{"kind" => "PdTag", "name" => "elixir"}
    end

    test "chip node emits PdChip with tone, strong, text and note" do
      node = %{
        "type" => "chip",
        "tone" => "danger",
        "strong" => true,
        "text" => "Grusomt",
        "note" => "kun SaaS"
      }

      assert Inline.compose_inline(node, false) == %{
               "kind" => "PdChip",
               "tone" => "danger",
               "strong" => true,
               "text" => "Grusomt",
               "note" => "kun SaaS"
             }
    end

    test "chip node degrades non-string fields to empty and non-true strong to false" do
      node = %{"type" => "chip", "tone" => 7, "strong" => "yes", "text" => nil}

      assert Inline.compose_inline(node, false) == %{
               "kind" => "PdChip",
               "tone" => "",
               "strong" => false,
               "text" => "",
               "note" => ""
             }
    end

    test "wikilink node emits PdWikilink without alias when absent" do
      node = %{"type" => "wikilink", "target" => "SomePage", "children" => []}
      result = Inline.compose_inline(node, false)

      assert result["kind"] == "PdWikilink"
      assert result["target"] == "SomePage"
      refute Map.has_key?(result, "alias")
    end

    test "wikilink node includes alias when present" do
      node = %{
        "type" => "wikilink",
        "target" => "SomePage",
        "alias" => "Nice Label",
        "children" => []
      }

      result = Inline.compose_inline(node, false)

      assert result["alias"] == "Nice Label"
    end

    test "wikilink node carries the id-pinned docId through as doc_id" do
      # The JS picker stamps the chosen paper's id under "docId" (camelCase);
      # compose must carry it onto the render node so the walker can id-pin.
      node = %{
        "type" => "wikilink",
        "target" => "Setup",
        "docId" => "p-pinned-99",
        "children" => []
      }

      result = Inline.compose_inline(node, false)

      assert result["doc_id"] == "p-pinned-99"
    end

    test "wikilink node omits doc_id when no id is pinned (byte-stable)" do
      node = %{"type" => "wikilink", "target" => "SomePage", "children" => []}
      result = Inline.compose_inline(node, false)

      refute Map.has_key?(result, "doc_id")
    end

    test "unknown type DEGRADES, never raises (wire §6, lvw-t1)" do
      # Childless → the empty string (matches Go pdrender). The historical
      # `raise ArgumentError` 500ed saves/body_html/deltas/Studio the moment one
      # forward-compat inline node reached the renderer.
      assert Inline.compose_inline(%{"type" => "mystery"}, false) == ""

      # A D6-style node dual-writes its visible fallback as a text child —
      # children still render through a plain PdText wrapper.
      node = %{
        "type" => "mystery",
        "children" => [%{"type" => "text", "value" => "dual-written fallback"}]
      }

      assert Inline.compose_inline(node, false) == %{
               "kind" => "PdText",
               "children" => ["dual-written fallback"]
             }
    end

    test "bare binary scalar passthrough" do
      assert Inline.compose_inline("raw", false) == "raw"
    end

    test "bare number scalar becomes string" do
      assert Inline.compose_inline(99, false) == "99"
    end
  end

  describe "to_pd_node_from_inline_child/1" do
    test "wraps a binary in PdText" do
      result = Inline.to_pd_node_from_inline_child("hello")
      assert result == %{"kind" => "PdText", "children" => ["hello"]}
    end

    test "passes through non-binary nodes unchanged" do
      node = %{"kind" => "PdInlineCode", "value" => "x"}
      assert Inline.to_pd_node_from_inline_child(node) == node
    end
  end
end
