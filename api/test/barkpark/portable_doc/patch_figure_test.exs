defmodule Barkpark.PortableDoc.PatchFigureTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  @shape_message "figure must contain exactly one child"

  defp figure(child) do
    %{
      "version" => 1,
      "blocks" => [
        %{
          "id" => "figure",
          "type" => "figure",
          "caption" => "Kept",
          "unknown" => %{"keep" => true},
          "child" => child
        }
      ]
    }
  end

  test "patch-block and map replace-block target the singular child without losing metadata" do
    before = figure(%{"id" => "child", "type" => "paragraph", "text" => "Before", "x" => 1})

    assert {:ok, patched} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "child",
               "patch" => %{"id" => "evil", "text" => "After"}
             })

    assert get_in(patched, ["blocks", Access.at(0), "child"]) == %{
             "id" => "child",
             "type" => "paragraph",
             "text" => "After",
             "x" => 1
           }

    assert get_in(patched, ["blocks", Access.at(0), "caption"]) == "Kept"
    assert get_in(patched, ["blocks", Access.at(0), "unknown"]) == %{"keep" => true}

    assert before ==
             figure(%{"id" => "child", "type" => "paragraph", "text" => "Before", "x" => 1})

    replacement = %{"id" => "replacement", "type" => "divider", "meta" => 9}

    assert {:ok, replaced} =
             Patch.apply_patch(before, %{
               "op" => "replace-block",
               "id" => "child",
               "block" => replacement
             })

    assert get_in(replaced, ["blocks", Access.at(0), "child"]) == replacement
    assert get_in(replaced, ["blocks", Access.at(0), "caption"]) == "Kept"
  end

  test "direct insert, remove, and non-map replacement cannot break the singular-child shape" do
    before = figure(%{"id" => "child", "type" => "divider"})

    assert {:error, {:constraint, @shape_message, "insert-after"}} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "child",
               "block" => %{"id" => "new", "type" => "divider"}
             })

    assert {:error, {:constraint, @shape_message, "remove-block"}} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "child"})

    assert {:error, {:constraint, @shape_message, "replace-block"}} =
             Patch.apply_patch(before, %{
               "op" => "replace-block",
               "id" => "child",
               "block" => "not a block"
             })

    assert before == figure(%{"id" => "child", "type" => "divider"})
  end

  test "duplicate and lock errors retain precedence over the figure shape constraint" do
    child = %{"id" => "child", "type" => "divider", "locked" => true}
    before = figure(child)

    assert {:error, {:duplicate_id, "child", "insert-after"}} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "child",
               "block" => %{"id" => "child", "type" => "divider"}
             })

    assert {:error, {:locked_block, "child", "remove-block"}} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "child"})

    assert {:error, {:locked_block, "child", "replace-block"}} =
             Patch.apply_patch(before, %{
               "op" => "replace-block",
               "id" => "child",
               "block" => "not a block"
             })

    locked_descendant =
      figure(%{
        "id" => "section",
        "type" => "section",
        "blocks" => [%{"id" => "deep", "type" => "divider", "locked" => true}]
      })

    assert {:error, {:locked_block, "deep", "remove-block"}} =
             Patch.apply_patch(locked_descendant, %{"op" => "remove-block", "id" => "deep"})
  end

  test "duplicate reservation includes the figure child and its visible descendants" do
    nested = %{
      "id" => "section",
      "type" => "section",
      "blocks" => [%{"id" => "deep", "type" => "divider"}]
    }

    before = figure(nested)

    assert {:error, {:duplicate_id, "deep", "append-block"}} =
             Patch.apply_patch(before, %{
               "op" => "append-block",
               "block" => %{"id" => "deep", "type" => "divider"}
             })

    with_outside =
      update_in(before["blocks"], fn blocks ->
        blocks ++ [%{"id" => "taken", "type" => "divider"}]
      end)

    assert {:error, {:duplicate_id, "taken", "replace-block"}} =
             Patch.apply_patch(with_outside, %{
               "op" => "replace-block",
               "id" => "section",
               "block" => %{"id" => "taken", "type" => "divider"}
             })
  end

  test "insert and remove remain available inside a container used as the figure child" do
    before =
      figure(%{
        "id" => "section",
        "type" => "section",
        "blocks" => [%{"id" => "first", "type" => "divider"}]
      })

    assert {:ok, inserted} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "first",
               "block" => %{"id" => "second", "type" => "divider"}
             })

    assert get_in(inserted, ["blocks", Access.at(0), "child", "blocks"]) == [
             %{"id" => "first", "type" => "divider"},
             %{"id" => "second", "type" => "divider"}
           ]

    assert {:ok, removed} =
             Patch.apply_patch(inserted, %{"op" => "remove-block", "id" => "first"})

    assert get_in(removed, ["blocks", Access.at(0), "child", "blocks"]) == [
             %{"id" => "second", "type" => "divider"}
           ]
  end

  test "nested figures expose only their singular child and retain its shape constraint" do
    before = %{
      "version" => 1,
      "blocks" => [
        %{
          "id" => "outer",
          "type" => "section",
          "blocks" => [
            %{
              "id" => "figure",
              "type" => "figure",
              "child" => %{"id" => "child", "type" => "paragraph", "text" => "Before"}
            }
          ]
        }
      ]
    }

    assert {:ok, patched} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "child",
               "patch" => %{"text" => "After"}
             })

    assert get_in(patched, ["blocks", Access.at(0), "blocks", Access.at(0), "child", "text"]) ==
             "After"

    assert {:error, {:constraint, @shape_message, "remove-block"}} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "child"})

    assert {:error, {:constraint, @shape_message, "insert-after"}} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "child",
               "block" => %{"id" => "new", "type" => "divider"}
             })
  end

  test "move-block cannot use the singular child as a source or top-level anchor" do
    before =
      %{
        "version" => 1,
        "blocks" => [
          hd(figure(%{"id" => "child", "type" => "divider"})["blocks"]),
          %{"id" => "tail", "type" => "divider"}
        ]
      }

    assert {:ok, ^before} =
             Patch.apply_patch(before, %{"op" => "move-block", "id" => "child", "after" => nil})

    assert {:error, {:block_not_found, "child", "move-block"}} =
             Patch.apply_patch(before, %{"op" => "move-block", "id" => "tail", "after" => "child"})
  end

  test "malformed figure children stay opaque and byte-identical" do
    for child_shape <- [:missing, nil, "legacy", []] do
      block = %{"id" => "figure", "type" => "figure", "unknown" => %{"keep" => true}}
      block = if child_shape == :missing, do: block, else: Map.put(block, "child", child_shape)
      before = %{"version" => 1, "blocks" => [block]}

      assert {:ok, ^before} =
               Patch.apply_patch(before, %{"op" => "remove-block", "id" => "ghost"})

      assert {:error, {:block_not_found, "ghost", "patch-block"}} =
               Patch.apply_patch(before, %{"op" => "patch-block", "id" => "ghost", "patch" => %{}})
    end
  end

  test "figure compatibility aliases are opaque and never become child arrays" do
    child = %{"id" => "child", "type" => "paragraph", "text" => "Visible"}

    block =
      figure(child)
      |> get_in(["blocks", Access.at(0)])
      |> Map.put("children", [%{"id" => "opaque-children", "type" => "divider"}])
      |> Map.put("blocks", [%{"id" => "opaque-blocks", "type" => "divider"}])

    before = %{"version" => 1, "blocks" => [block]}

    for id <- ["opaque-children", "opaque-blocks"] do
      assert {:error, {:block_not_found, ^id, "patch-block"}} =
               Patch.apply_patch(before, %{"op" => "patch-block", "id" => id, "patch" => %{}})
    end

    assert {:ok, patched} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "child",
               "patch" => %{"text" => "After"}
             })

    figure_after = get_in(patched, ["blocks", Access.at(0)])
    assert is_map(figure_after["child"])
    assert figure_after["children"] == block["children"]
    assert figure_after["blocks"] == block["blocks"]
  end
end
