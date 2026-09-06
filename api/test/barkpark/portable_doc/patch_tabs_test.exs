defmodule Barkpark.PortableDoc.PatchTabsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp paragraph(id, text, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "text" => text}, extra)
  end

  test "patches canonical tab blocks while preserving parent, row, opaque metadata, and siblings" do
    opaque = [paragraph("opaque", "Hidden")]
    first = %{"id" => "row-a", "title" => "A", "blocks" => [paragraph("a", "A")]}

    second = %{
      "id" => "row-b",
      "title" => "B",
      "row-meta" => [1, 2],
      "blocks" => [paragraph("b", "Before", %{"child-meta" => true})],
      "children" => opaque,
      "content" => opaque
    }

    tabs = %{
      "id" => "tabs",
      "type" => "tabs",
      "parent-meta" => %{"keep" => true},
      "tabs" => [first, second]
    }

    assert {:ok, [changed]} =
             Patch.apply_patch([tabs], %{
               "op" => "patch-block",
               "id" => "b",
               "patch" => %{"text" => "After"}
             })

    [same_first, changed_second] = changed["tabs"]
    assert same_first == first
    assert changed_second["blocks"] == [paragraph("b", "After", %{"child-meta" => true})]
    assert changed_second["children"] == opaque
    assert changed_second["content"] == opaque
    assert changed_second["row-meta"] == [1, 2]
    assert changed["parent-meta"] == %{"keep" => true}

    assert {:ok, [inserted]} =
             Patch.apply_patch([changed], %{
               "op" => "insert-after",
               "afterId" => "b",
               "block" => paragraph("new", "New")
             })

    assert hd(inserted["tabs"]) == first
    assert Enum.map(Enum.at(inserted["tabs"], 1)["blocks"], & &1["id"]) == ["b", "new"]

    assert {:ok, [reordered]} =
             Patch.apply_patch([changed], %{
               "op" => "patch-block",
               "id" => "tabs",
               "patch" => %{"tabs" => [changed_second, same_first]}
             })

    assert Enum.map(reordered["tabs"], & &1["id"]) == ["row-b", "row-a"]
    assert reordered["parent-meta"] == %{"keep" => true}
  end

  test "ordinary and flagged transforms recurse through tabs with sections and expandables" do
    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{
            "id" => "row",
            "blocks" => [
              %{
                "id" => "details",
                "type" => "expandable",
                "children" => [
                  %{
                    "id" => "nested-tabs",
                    "type" => "tabs",
                    "tabs" => [
                      %{
                        "id" => "nested-row",
                        "blocks" => [
                          %{
                            "id" => "section",
                            "type" => "section",
                            "blocks" => [
                              paragraph("deep", "Before"),
                              paragraph("sibling", "Keep")
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert {:error, {:type_mismatch, "deep", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "deep",
               "patch" => %{"type" => "code", "text" => "No"}
             })

    assert {:ok, [replaced]} =
             Patch.apply_patch(blocks, %{
               "op" => "replace-block",
               "id" => "deep",
               "block" => %{"id" => "deep", "type" => "code", "value" => "After"}
             })

    section = deep_section(replaced)

    assert section["blocks"] == [
             %{"id" => "deep", "type" => "code", "value" => "After"},
             paragraph("sibling", "Keep")
           ]

    assert {:ok, [removed]} =
             Patch.apply_patch([replaced], %{"op" => "remove-block", "id" => "deep"})

    assert deep_section(removed)["blocks"] == [paragraph("sibling", "Keep")]
  end

  test "tab rows are not block targets and noncanonical children, content, malformed tabs, and code-tabs stay opaque" do
    hidden = paragraph("hidden", "Hidden")

    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{"id" => "row", "blocks" => [], "children" => [hidden], "content" => [hidden]}
        ]
      },
      %{"id" => "bad-tabs", "type" => "tabs", "tabs" => %{"blocks" => [hidden]}},
      %{"id" => "code-tabs", "type" => "code-tabs", "tabs" => [%{"blocks" => [hidden]}]}
    ]

    for id <- ["row", "hidden"] do
      assert {:error, {:block_not_found, ^id, "patch-block"}} =
               Patch.apply_patch(blocks, %{
                 "op" => "patch-block",
                 "id" => id,
                 "patch" => %{"text" => "Exposed"}
               })
    end

    scalar_body = [
      %{
        "id" => "scalar-tabs",
        "type" => "tabs",
        "tabs" => [%{"id" => "scalar-row", "blocks" => ["legacy", nil, 7]}]
      }
    ]

    assert {:error, {:block_not_found, "missing", "patch-block"}} =
             Patch.apply_patch(scalar_body, %{
               "op" => "patch-block",
               "id" => "missing",
               "patch" => %{"text" => "No crash"}
             })
  end

  test "locks, duplicate discovery, and duplicate ratchet include canonical tab descendants and rows" do
    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{
            "id" => "row",
            "blocks" => [paragraph("anchor", "A"), paragraph("locked", "L", %{"locked" => true})]
          }
        ]
      }
    ]

    assert {:error, {:duplicate_id, "locked", "insert-after"}} =
             Patch.apply_patch(blocks, %{
               "op" => "insert-after",
               "afterId" => "anchor",
               "block" => paragraph("locked", "Duplicate")
             })

    assert {:error, {:locked_block, "locked", "remove-block"}} =
             Patch.apply_patch(blocks, %{"op" => "remove-block", "id" => "locked"})

    assert {:error, {:locked_block, "locked", "replace-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "replace-block",
               "id" => "locked",
               "block" => paragraph("locked", "Replacement")
             })

    for op <- [
          %{"op" => "append-block", "block" => paragraph("row", "Duplicate row")},
          %{
            "op" => "insert-after",
            "afterId" => "anchor",
            "block" => paragraph("row", "Duplicate row")
          }
        ] do
      assert {:error, {:duplicate_id, "row", op_kind}} = Patch.apply_patch(blocks, op)
      assert op_kind == op["op"]
    end

    duplicate_row = %{
      "tabs" => [
        %{"id" => "row", "blocks" => []},
        %{"id" => "row", "blocks" => []}
      ]
    }

    assert {:error, {:duplicate_id, "row", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "tabs",
               "patch" => duplicate_row
             })

    duplicate_child = %{
      "tabs" => [
        %{"id" => "row", "blocks" => [paragraph("anchor", "A"), paragraph("anchor", "B")]}
      ]
    }

    assert {:error, {:duplicate_id, "anchor", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "tabs",
               "patch" => duplicate_child
             })
  end

  test "pre-existing tab duplicates may survive an unrelated patch when their count does not increase" do
    blocks = [
      paragraph("outside", "Before"),
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{"id" => "legacy", "blocks" => [paragraph("same", "A")]},
          %{"id" => "legacy", "blocks" => [paragraph("same", "B")]}
        ]
      }
    ]

    assert {:ok, [changed, same_tabs]} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "outside",
               "patch" => %{"text" => "After"}
             })

    assert changed == paragraph("outside", "After")
    assert same_tabs == Enum.at(blocks, 1)
  end

  defp deep_section(outer_tabs) do
    outer_tabs["tabs"]
    |> hd()
    |> Map.fetch!("blocks")
    |> hd()
    |> Map.fetch!("children")
    |> hd()
    |> Map.fetch!("tabs")
    |> hd()
    |> Map.fetch!("blocks")
    |> hd()
  end
end
