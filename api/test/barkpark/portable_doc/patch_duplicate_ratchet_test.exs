defmodule Barkpark.PortableDoc.PatchDuplicateRatchetTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}

  test "patch-block rejects a steps row id newly colliding outside the patched parent" do
    blocks = [
      paragraph("taken"),
      %{
        "id" => "procedure",
        "type" => "steps",
        "steps" => [%{"id" => "row-a", "title" => "First", "children" => []}]
      }
    ]

    assert {:error, {:duplicate_id, "taken", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "procedure",
               "patch" => %{
                 "steps" => [%{"id" => "taken", "title" => "First", "children" => []}]
               }
             })
  end

  test "patch-block rejects a steps child id newly colliding outside the patched parent" do
    blocks = [
      paragraph("taken-child"),
      %{
        "id" => "procedure",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "row-a",
            "title" => "First",
            "children" => [],
            "blocks" => [paragraph("shadow-child")]
          }
        ]
      }
    ]

    assert {:error, {:duplicate_id, "taken-child", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "procedure",
               "patch" => %{
                 "steps" => [
                   %{
                     "id" => "row-a",
                     "title" => "First",
                     "children" => [],
                     "blocks" => [paragraph("taken-child")]
                   }
                 ]
               }
             })
  end

  test "patch-block permits unique nested steps rows and children" do
    steps = %{"id" => "procedure", "type" => "steps", "steps" => []}

    patch = %{
      "steps" => [
        %{
          "id" => "row-a",
          "title" => "First",
          "analytics" => %{"id" => "nested-child"},
          "children" => [
            %{
              "id" => "details",
              "type" => "expandable",
              "children" => [paragraph("nested-child")],
              "blocks" => [paragraph("shadow-child")]
            }
          ]
        }
      ]
    }

    assert {:ok, [%{"steps" => [row]}]} =
             Patch.apply_patch([steps], %{
               "op" => "patch-block",
               "id" => "procedure",
               "patch" => patch
             })

    assert row == hd(patch["steps"])
  end

  test "patch-block permits an unchanged legacy duplicate but rejects increasing it" do
    blocks = [
      paragraph("legacy-duplicate"),
      %{
        "id" => "procedure",
        "type" => "steps",
        "caption" => "Before",
        "steps" => [
          %{
            "id" => "row-a",
            "children" => [paragraph("legacy-duplicate")]
          }
        ]
      }
    ]

    assert {:ok, [_outside, %{"caption" => "After"}]} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "procedure",
               "patch" => %{"caption" => "After"}
             })

    assert {:error, {:duplicate_id, "legacy-duplicate", "patch-block"}} =
             Patch.apply_patch(blocks, %{
               "op" => "patch-block",
               "id" => "procedure",
               "patch" => %{
                 "steps" => [
                   %{
                     "id" => "row-a",
                     "children" => [
                       paragraph("legacy-duplicate"),
                       paragraph("legacy-duplicate")
                     ]
                   }
                 ]
               }
             })
  end
end
