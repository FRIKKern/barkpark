defmodule Barkpark.Content.Papers.FigureIdentityTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps

  test "projects the singular figure child and its visible descendants collision-safely" do
    blocks = [
      %{"id" => "figure-child-0", "type" => "paragraph", "text" => "reserved"},
      %{
        "id" => "figure",
        "type" => "figure",
        "caption" => "Kept",
        "unknown" => %{"keep" => true},
        "children" => [%{"type" => "paragraph", "text" => "Opaque alias"}],
        "blocks" => [%{"type" => "paragraph", "text" => "Opaque alias"}],
        "child" => %{
          "type" => "section",
          "unknown-child" => 7,
          "blocks" => [%{"type" => "paragraph", "text" => "Visible"}]
        }
      }
    ]

    [outside, projected] = BlockOps.ensure_block_ids(blocks)
    child = projected["child"]

    assert outside == hd(blocks)
    assert child["id"] == "figure-child-0-1"
    assert child["unknown-child"] == 7
    assert hd(child["blocks"])["id"] == "figure-child-0-1-0"
    assert projected["caption"] == "Kept"
    assert projected["unknown"] == %{"keep" => true}
    assert projected["children"] == Enum.at(blocks, 1)["children"]
    assert projected["blocks"] == Enum.at(blocks, 1)["blocks"]
    assert BlockOps.ensure_block_ids([outside, projected]) == [outside, projected]

    reordered = [projected, outside]
    assert BlockOps.ensure_block_ids(reordered) == reordered
  end

  test "an id-less figure gives its id-less child the deterministic singular-child prefix" do
    [projected] =
      BlockOps.ensure_block_ids([
        %{"type" => "figure", "child" => %{"type" => "paragraph", "text" => "Body"}}
      ])

    assert projected["id"] == "block-0"
    assert projected["child"]["id"] == "block-0-child-0"
    refute is_list(projected["child"])
  end

  test "preserves existing figure-child identity and rejects duplicates in its visible tree" do
    figure = %{
      "id" => "figure",
      "type" => "figure",
      "child" => %{"id" => "authored", "type" => "paragraph", "text" => "Kept"}
    }

    assert BlockOps.ensure_block_ids([figure]) == [figure]

    duplicate = [%{"id" => "authored", "type" => "divider"}, figure]
    assert {:error, {:duplicate_id, "authored"}} = BlockOps.project_block_ids_safely(duplicate)
  end

  test "missing, nil, scalar, and array children remain byte-identical and opaque" do
    for child_shape <- [:missing, nil, "legacy", 7, []] do
      figure = %{
        "id" => "figure",
        "type" => "figure",
        "unknown" => %{"keep" => true},
        "blocks" => [%{"id" => "opaque", "type" => "paragraph"}],
        "children" => [%{"type" => "paragraph"}]
      }

      figure =
        if child_shape == :missing,
          do: figure,
          else: Map.put(figure, "child", child_shape)

      assert BlockOps.ensure_block_ids([figure]) == [figure]
      assert {:ok, [^figure]} = BlockOps.project_block_ids_safely([figure])

      outside_duplicate = [%{"id" => "opaque", "type" => "divider"}, figure]
      assert {:ok, ^outside_duplicate} = BlockOps.project_block_ids_safely(outside_duplicate)
    end
  end

  test "an accepted child patch resolves the affected figure child for the receipt" do
    slug = "figure-affected-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "figure",
        "type" => "figure",
        "caption" => "Kept",
        "child" => %{"id" => "child", "type" => "paragraph", "text" => "Before"}
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
    assert receipt.block["id"] == "child"
    assert receipt.block["text"] == "After"
    assert receipt.position == nil

    stored_figure = Content.get_paper(slug).content["blocks"] |> hd()
    assert stored_figure["caption"] == "Kept"
    assert stored_figure["child"]["text"] == "After"
  end
end
