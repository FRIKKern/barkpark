defmodule Barkpark.PortableDoc.PatchStepsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp paragraph(id, text, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "text" => text}, extra)
  end

  test "patches each renderer-visible row body alias without rewriting rows or shadows" do
    visible = paragraph("visible", "Before", %{"child-meta" => 1})
    legacy = paragraph("legacy", "Before")
    hidden = paragraph("hidden", "Shadow")

    blocks = [
      %{
        "id" => "steps",
        "type" => "steps",
        "parent-meta" => %{"keep" => true},
        "steps" => [
          %{
            "id" => "row-a",
            "title" => "A",
            "row-meta" => [1, 2],
            "children" => [visible],
            "blocks" => [hidden]
          },
          %{"id" => "row-b", "title" => "B", "blocks" => [legacy]}
        ]
      }
    ]

    assert {:ok, [after_visible]} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "visible",
               "patch" => %{"text" => "After"}
             })

    [row_a, row_b] = after_visible["steps"]
    assert row_a["children"] == [paragraph("visible", "After", %{"child-meta" => 1})]
    assert row_a["blocks"] == [hidden]
    assert row_a["row-meta"] == [1, 2]
    assert row_b == Enum.at(hd(blocks)["steps"], 1)
    assert after_visible["parent-meta"] == %{"keep" => true}

    assert {:ok, [after_legacy]} =
             Patch.apply_patch([after_visible], %{
               "op" => "patch-block",
               "id" => "legacy",
               "patch" => %{"text" => "Legacy after"}
             })

    assert Enum.at(after_legacy["steps"], 1)["blocks"] ==
             [paragraph("legacy", "Legacy after")]
  end

  test "truthy children is authoritative even when empty or malformed, while nil and false fall back" do
    hidden = paragraph("hidden", "Shadow")

    for authoritative <- [[], %{"malformed" => true}, "malformed"] do
      blocks = [
        %{
          "id" => "steps",
          "type" => "steps",
          "steps" => [%{"children" => authoritative, "blocks" => [hidden]}]
        }
      ]

      assert {:error, {:block_not_found, "hidden", "patch-block"}} =
               Patch.apply_patch(blocks, %{
                 "op" => "patch-block",
                 "id" => "hidden",
                 "patch" => %{"text" => "Exposed"}
               })
    end

    for absent <- [nil, false] do
      blocks = [
        %{
          "id" => "steps",
          "type" => "steps",
          "steps" => [%{"children" => absent, "blocks" => [hidden]}]
        }
      ]

      assert {:ok, [%{"steps" => [row]}]} =
               Patch.apply_patch(blocks, %{
                 "op" => "patch-block",
                 "id" => "hidden",
                 "patch" => %{"text" => "Visible"}
               })

      assert row["children"] == absent
      assert row["blocks"] == [paragraph("hidden", "Visible")]
    end
  end

  test "rows are isolated, row ids are not block targets, and outer items is not an alias" do
    first = %{"id" => "row-a", "children" => [paragraph("a", "A")]}
    second = %{"id" => "row-b", "children" => [paragraph("b", "B")]}
    steps = %{"id" => "steps", "type" => "steps", "steps" => [first, second]}

    assert {:ok, [changed]} =
             Patch.apply_patch([steps], %{
               "op" => "insert-after",
               "afterId" => "b",
               "block" => paragraph("new", "New")
             })

    assert hd(changed["steps"]) == first
    assert Enum.map(Enum.at(changed["steps"], 1)["children"], & &1["id"]) == ["b", "new"]

    assert {:error, {:block_not_found, "row-a", "patch-block"}} =
             Patch.apply_patch([steps], %{
               "op" => "patch-block",
               "id" => "row-a",
               "patch" => %{"title" => "Not a block"}
             })

    assert {:error, {:block_not_found, "item-child", "patch-block"}} =
             Patch.apply_patch(
               [
                 %{
                   "id" => "not-steps",
                   "type" => "steps",
                   "items" => [%{"children" => [paragraph("item-child", "Hidden")]}]
                 }
               ],
               %{
                 "op" => "patch-block",
                 "id" => "item-child",
                 "patch" => %{"text" => "Exposed"}
               }
             )
  end

  test "duplicate discovery and locks include visible row descendants only" do
    blocks = [
      %{
        "id" => "outer",
        "type" => "section",
        "blocks" => [
          %{
            "id" => "steps",
            "type" => "steps",
            "steps" => [
              %{"id" => "row-a", "children" => [paragraph("anchor", "A")]},
              %{
                "id" => "row-b",
                "blocks" => [paragraph("locked", "L", %{"locked" => true})]
              }
            ]
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
  end

  test "ordinary and flagged transforms recurse through steps, expandable and section" do
    blocks = [
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "row",
            "children" => [
              %{
                "id" => "details",
                "type" => "expandable",
                "children" => [
                  %{
                    "id" => "nested-steps",
                    "type" => "steps",
                    "steps" => [
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

    section = deep_section(removed)

    assert section["blocks"] == [paragraph("sibling", "Keep")]
  end

  defp deep_section(outer_steps) do
    outer_steps["steps"]
    |> hd()
    |> Map.fetch!("children")
    |> hd()
    |> Map.fetch!("children")
    |> hd()
    |> Map.fetch!("steps")
    |> hd()
    |> Map.fetch!("blocks")
    |> hd()
  end
end
