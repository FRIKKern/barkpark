defmodule Barkpark.Content.Papers.ColumnsIdentityTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps

  test "projects map children inside list columns without inventing column-row identities" do
    opaque_row = %{"title" => "not a column list", "unknown" => true}
    opaque_alias = [%{"type" => "paragraph", "text" => "opaque"}]

    blocks = [
      %{"id" => "grid-column-0-0", "type" => "divider"},
      %{
        "id" => "grid",
        "type" => "columns",
        "gap" => "wide",
        "unknown" => %{"keep" => true},
        "children" => opaque_alias,
        "blocks" => opaque_alias,
        "columns" => [
          [%{"type" => "paragraph", "text" => "First"}, "legacy", nil],
          opaque_row,
          [
            %{
              "type" => "section",
              "blocks" => [%{"type" => "paragraph", "text" => "Nested"}]
            }
          ]
        ]
      }
    ]

    [outside, projected] = BlockOps.ensure_block_ids(blocks)
    [first_column, preserved_row, third_column] = projected["columns"]

    assert outside == hd(blocks)
    assert hd(first_column)["id"] == "grid-column-0-0-1"
    assert Enum.slice(first_column, 1, 2) == ["legacy", nil]
    assert preserved_row == opaque_row
    assert hd(third_column)["id"] == "grid-column-2-0"
    assert hd(hd(third_column)["blocks"])["id"] == "grid-column-2-0-0"
    assert projected["children"] == opaque_alias
    assert projected["blocks"] == opaque_alias
    assert projected["gap"] == "wide"
    assert projected["unknown"] == %{"keep" => true}
    assert BlockOps.ensure_block_ids([outside, projected]) == [outside, projected]

    reordered = Map.put(projected, "columns", Enum.reverse(projected["columns"]))
    assert BlockOps.ensure_block_ids([outside, reordered]) == [outside, reordered]
  end

  test "global reservation and safe projection include valid column descendants" do
    duplicate = [
      %{"id" => "same", "type" => "divider"},
      %{
        "id" => "grid",
        "type" => "columns",
        "columns" => [[%{"id" => "same", "type" => "paragraph"}]]
      }
    ]

    assert {:error, {:duplicate_id, "same"}} = BlockOps.project_block_ids_safely(duplicate)

    opaque_row_duplicate = [
      %{"id" => "same", "type" => "divider"},
      %{"id" => "grid", "type" => "columns", "columns" => [%{"id" => "same"}]}
    ]

    assert {:ok, ^opaque_row_duplicate} =
             BlockOps.project_block_ids_safely(opaque_row_duplicate)
  end

  test "malformed columns remain byte-identical and ignore compatibility aliases" do
    for columns <- [:missing, nil, "legacy", %{}, 7] do
      block = %{
        "id" => "grid",
        "type" => "columns",
        "unknown" => %{"keep" => true},
        "blocks" => [%{"id" => "opaque", "type" => "paragraph"}],
        "children" => [%{"type" => "paragraph"}]
      }

      block = if columns == :missing, do: block, else: Map.put(block, "columns", columns)
      assert BlockOps.ensure_block_ids([block]) == [block]

      with_duplicate = [%{"id" => "opaque", "type" => "divider"}, block]
      assert {:ok, ^with_duplicate} = BlockOps.project_block_ids_safely(with_duplicate)
    end
  end

  test "an accepted descendant patch resolves the affected column block for its receipt" do
    slug = "columns-affected-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "grid",
        "type" => "columns",
        "columns" => [[%{"id" => "child", "type" => "paragraph", "text" => "Before"}], []]
      }
    ]

    attrs = Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
    assert {:ok, paper} = Content.upsert_paper(attrs)

    assert {:ok, receipt} =
             Content.apply_paper_block_op(
               slug,
               %{"op" => "patch-block", "id" => "child", "patch" => %{"text" => "After"}},
               "production",
               if_rev: paper.content["rev"]
             )

    assert receipt.block_id == "child"
    assert receipt.block["text"] == "After"
    assert receipt.position == nil
    stored = Content.get_paper(slug).content["blocks"] |> hd()
    assert hd(hd(stored["columns"]))["text"] == "After"
    assert Enum.at(stored["columns"], 1) == []
  end
end
