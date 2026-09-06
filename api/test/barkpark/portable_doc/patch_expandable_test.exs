defmodule Barkpark.PortableDoc.PatchExpandableTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  test "patches nested expandable children while preserving the children key and metadata" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "summary" => "Details",
        "children" => [
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Before"}],
            "unknown" => "kept"
          }
        ]
      }
    ]

    content = [
      %{
        "type" => "strong",
        "children" => [%{"type" => "text", "value" => "After"}]
      }
    ]

    assert {:ok, [expanded]} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "body",
               "patch" => %{"content" => content}
             })

    assert %{"children" => [%{"content" => ^content, "unknown" => "kept"}]} = expanded
    refute Map.has_key?(expanded, "blocks")
  end

  test "patches the compatible blocks alias without rewriting it to children" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "blocks" => [%{"id" => "body", "type" => "paragraph", "text" => "Before"}]
      }
    ]

    assert {:ok, [expanded]} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "body",
               "patch" => %{"text" => "After"}
             })

    assert expanded["blocks"] == [%{"id" => "body", "type" => "paragraph", "text" => "After"}]
    refute Map.has_key?(expanded, "children")
  end

  test "children wins when both aliases are present and duplicate ids see that visible tree" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "children" => [%{"id" => "visible", "type" => "paragraph", "text" => "Before"}],
        "blocks" => [%{"id" => "hidden", "type" => "paragraph", "text" => "Untouched"}]
      }
    ]

    assert {:ok, [expanded]} =
             Patch.apply_patch(blocks, %{
               "op" => "insert-after",
               "afterId" => "visible",
               "block" => %{"id" => "new", "type" => "paragraph", "text" => "New"}
             })

    assert Enum.map(expanded["children"], & &1["id"]) == ["visible", "new"]

    assert expanded["blocks"] == [
             %{"id" => "hidden", "type" => "paragraph", "text" => "Untouched"}
           ]

    assert {:error, {:duplicate_id, "new", "insert-after"}} =
             Patch.apply_patch([expanded], %{
               "op" => "insert-after",
               "afterId" => "visible",
               "block" => %{"id" => "new", "type" => "paragraph"}
             })
  end

  test "replace and remove work at nested depth while locked children remain protected" do
    for key <- ["children", "blocks"] do
      blocks = [
        %{
          "id" => "details",
          "type" => "expandable",
          key => [
            %{"id" => "open", "type" => "paragraph", "text" => "Before"},
            %{"id" => "locked", "type" => "paragraph", "locked" => true}
          ]
        }
      ]

      assert {:ok, [replaced]} =
               Patch.apply_patch(blocks, %{
                 "op" => "replace-block",
                 "id" => "open",
                 "block" => %{"id" => "open", "type" => "code", "value" => "after"}
               })

      assert Enum.at(replaced[key], 0) == %{"id" => "open", "type" => "code", "value" => "after"}

      assert {:ok, [removed]} =
               Patch.apply_patch([replaced], %{"op" => "remove-block", "id" => "open"})

      assert Enum.map(removed[key], & &1["id"]) == ["locked"]

      assert {:error, {:locked_block, "locked", "remove-block"}} =
               Patch.apply_patch(blocks, %{"op" => "remove-block", "id" => "locked"})

      assert {:error, {:locked_block, "locked", "replace-block"}} =
               Patch.apply_patch(blocks, %{
                 "op" => "replace-block",
                 "id" => "locked",
                 "block" => %{"id" => "locked", "type" => "paragraph"}
               })
    end
  end
end
