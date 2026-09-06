defmodule Barkpark.PortableDoc.PatchColumnsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp doc(columns) do
    %{
      "version" => 1,
      "blocks" => [
        %{
          "id" => "grid",
          "type" => "columns",
          "gap" => "wide",
          "unknown" => %{"keep" => true},
          "columns" => columns
        }
      ]
    }
  end

  test "patch, insert, replace, and remove target one column without disturbing siblings" do
    before =
      doc([
        [%{"id" => "first", "type" => "paragraph", "text" => "Before"}],
        [%{"id" => "other", "type" => "divider", "meta" => 9}]
      ])

    assert {:ok, patched} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "first",
               "patch" => %{"id" => "evil", "text" => "After"}
             })

    assert get_in(patched, ["blocks", Access.at(0), "columns", Access.at(0), Access.at(0)]) ==
             %{"id" => "first", "type" => "paragraph", "text" => "After"}

    assert {:ok, inserted} =
             Patch.apply_patch(patched, %{
               "op" => "insert-after",
               "afterId" => "first",
               "block" => %{"id" => "second", "type" => "divider"}
             })

    assert Enum.map(
             get_in(inserted, ["blocks", Access.at(0), "columns", Access.at(0)]),
             & &1["id"]
           ) ==
             ["first", "second"]

    assert {:ok, replaced} =
             Patch.apply_patch(inserted, %{
               "op" => "replace-block",
               "id" => "second",
               "block" => %{"id" => "replacement", "type" => "paragraph", "text" => "R"}
             })

    assert {:ok, removed} =
             Patch.apply_patch(replaced, %{"op" => "remove-block", "id" => "first"})

    grid = hd(removed["blocks"])
    assert hd(grid["columns"]) == [%{"id" => "replacement", "type" => "paragraph", "text" => "R"}]
    assert Enum.at(grid["columns"], 1) == [%{"id" => "other", "type" => "divider", "meta" => 9}]
    assert grid["gap"] == "wide"
    assert grid["unknown"] == %{"keep" => true}

    assert before ==
             doc([
               [%{"id" => "first", "type" => "paragraph", "text" => "Before"}],
               [%{"id" => "other", "type" => "divider", "meta" => 9}]
             ])
  end

  test "removing the last child retains an empty column list" do
    before = doc([[%{"id" => "only", "type" => "divider"}], []])

    assert {:ok, removed} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "only"})

    assert get_in(removed, ["blocks", Access.at(0), "columns"]) == [[], []]
  end

  test "nested columns recurse through sections and figures" do
    inner =
      doc([[%{"id" => "deep", "type" => "paragraph", "text" => "Before"}]])
      |> get_in(["blocks", Access.at(0)])

    nested = %{
      "id" => "outer-grid",
      "type" => "columns",
      "columns" => [[inner], []]
    }

    before = %{
      "version" => 1,
      "blocks" => [
        %{
          "id" => "outer",
          "type" => "section",
          "blocks" => [
            %{"id" => "figure", "type" => "figure", "child" => nested, "caption" => "Kept"}
          ]
        }
      ]
    }

    assert {:ok, patched} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "deep",
               "patch" => %{"text" => "After"}
             })

    assert get_in(patched, [
             "blocks",
             Access.at(0),
             "blocks",
             Access.at(0),
             "child",
             "columns",
             Access.at(0),
             Access.at(0),
             "columns",
             Access.at(0),
             Access.at(0),
             "text"
           ]) == "After"
  end

  test "duplicate census and locks include valid column descendants" do
    before =
      doc([
        [
          %{"id" => "locked", "type" => "divider", "locked" => true},
          %{"id" => "replaceable", "type" => "divider"}
        ]
      ])

    assert {:error, {:duplicate_id, "locked", "append-block"}} =
             Patch.apply_patch(before, %{
               "op" => "append-block",
               "block" => %{"id" => "locked", "type" => "divider"}
             })

    assert {:error, {:locked_block, "locked", "remove-block"}} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "locked"})

    figure_collision = %{
      "version" => 1,
      "blocks" => [
        hd(before["blocks"]),
        %{
          "id" => "figure",
          "type" => "figure",
          "child" => %{"id" => "figure-child", "type" => "divider"}
        }
      ]
    }

    assert {:error, {:duplicate_id, "figure-child", "replace-block"}} =
             Patch.apply_patch(figure_collision, %{
               "op" => "replace-block",
               "id" => "replaceable",
               "block" => %{"id" => "figure-child", "type" => "divider"}
             })
  end

  test "scalar rows and elements plus malformed columns and aliases stay opaque" do
    opaque_alias = [%{"id" => "opaque-alias", "type" => "divider"}]

    for columns <- [
          :missing,
          nil,
          "legacy",
          %{},
          7,
          [%{"id" => "opaque-row"}],
          ["scalar"],
          [["scalar"]]
        ] do
      grid = %{
        "id" => "grid",
        "type" => "columns",
        "children" => opaque_alias,
        "blocks" => opaque_alias,
        "unknown" => %{"keep" => true}
      }

      grid = if columns == :missing, do: grid, else: Map.put(grid, "columns", columns)
      before = %{"version" => 1, "blocks" => [grid]}

      for id <- ["opaque-row", "opaque-alias"] do
        assert {:error, {:block_not_found, ^id, "patch-block"}} =
                 Patch.apply_patch(before, %{"op" => "patch-block", "id" => id, "patch" => %{}})
      end

      assert {:ok, ^before} =
               Patch.apply_patch(before, %{"op" => "remove-block", "id" => "ghost"})
    end
  end

  test "move-block remains top-level only for column descendants and anchors" do
    before =
      %{
        "version" => 1,
        "blocks" => [
          hd(doc([[%{"id" => "child", "type" => "divider"}]])["blocks"]),
          %{"id" => "tail", "type" => "divider"}
        ]
      }

    assert {:ok, ^before} =
             Patch.apply_patch(before, %{"op" => "move-block", "id" => "child", "after" => nil})

    assert {:error, {:block_not_found, "child", "move-block"}} =
             Patch.apply_patch(before, %{"op" => "move-block", "id" => "tail", "after" => "child"})
  end
end
