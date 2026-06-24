defmodule Barkpark.PortableDoc.Render.ComposeTest do
  # Pure, in-process — no DB, no plugins needed.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  describe "compose_block/1 (email/default style)" do
    test "heading emits a bold PdText span (email mode)" do
      b = %{"type" => "heading", "text" => "Hello", "level" => 1}
      assert Compose.compose_block(b) == %{"kind" => "PdText", "weight" => "bold", "children" => ["Hello"]}
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
      b = %{"type" => "action", "href" => "https://example.com", "label" => "Go", "priority" => "primary"}
      result = Compose.compose_block(b)
      assert result == %{"kind" => "PdButton", "href" => "https://example.com", "label" => "Go", "priority" => "primary"}
    end

    test "action missing keys defaults to empty strings" do
      b = %{"type" => "action"}
      result = Compose.compose_block(b)
      assert result["href"] == ""
      assert result["label"] == ""
      assert result["priority"] == nil
    end

    test "image emits PdImage with optional dimensions" do
      b = %{"type" => "image", "src" => "https://example.com/img.png", "alt" => "A pic", "width" => 400, "height" => 300}
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
      b = %{"type" => "field-reference", "label" => "Ref", "value" => "doc-123", "_ref_title" => "My Doc"}
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

    test "unhandled block type raises ArgumentError" do
      assert_raise ArgumentError, ~r/unhandled block type/, fn ->
        Compose.compose_block(%{"type" => "nonexistent-type"})
      end
    end
  end
end
