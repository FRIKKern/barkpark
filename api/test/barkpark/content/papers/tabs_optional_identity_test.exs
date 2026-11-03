defmodule Barkpark.Content.Papers.TabsOptionalIdentityTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Repo

  @dataset "production"

  test "whole-paper ingest preserves optional missing tab ids and explicit ids" do
    slug = "tabs-optional-ingest-#{System.unique_integer([:positive])}"
    blocks = fixture_blocks()

    assert {:ok, paper} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 slug: slug,
                 dataset: @dataset,
                 blocks: blocks
               })
             )

    assert paper.content["blocks"] == blocks
  end

  test "an unrelated revision-fenced edit does not materialize an optional tab id" do
    slug = "tabs-optional-op-#{System.unique_integer([:positive])}"
    blocks = fixture_blocks()

    assert {:ok, paper} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 slug: slug,
                 dataset: @dataset,
                 blocks: blocks
               })
             )

    # Model the valid legacy shape directly until every ingest door preserves it.
    paper =
      paper
      |> Ecto.Changeset.change(content: Map.put(paper.content, "blocks", blocks))
      |> Repo.update!()

    assert {:ok, _receipt} =
             Content.apply_paper_block_op(
               slug,
               %{"op" => "patch-block", "id" => "root", "patch" => %{"text" => "After"}},
               @dataset,
               if_rev: paper.content["rev"]
             )

    [root, tabs] = Content.get_paper(slug, @dataset).content["blocks"]
    [optional, explicit] = tabs["tabs"]

    assert root["text"] == "After"
    refute Map.has_key?(optional, "id")
    assert explicit["id"] == "switcher-tab-0"

    projected = BlockOps.ensure_block_ids([root, tabs])
    [_, projected_tabs] = projected
    [projected_optional, _] = projected_tabs["tabs"]
    projected_child = hd(projected_optional["blocks"])

    context = %{
      container_kind: "tabs",
      container_id: "switcher",
      container_row_id: projected_optional["id"],
      container_run_ids: [projected_child["id"]]
    }

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(
               slug,
               [
                 %{
                   "op" => "patch-block",
                   "id" => projected_child["id"],
                   "patch" => %{"text" => "Next revision"}
                 }
               ],
               @dataset,
               if_rev: Content.get_paper(slug, @dataset).content["rev"],
               canvas_run_context: context
             )

    [_, saved_tabs] = Content.get_paper(slug, @dataset).content["blocks"]
    [saved_optional, saved_explicit] = saved_tabs["tabs"]
    refute Map.has_key?(saved_optional, "id")
    assert hd(saved_optional["blocks"])["text"] == "Next revision"
    assert saved_explicit["id"] == "switcher-tab-0"
  end

  test "a batch replacement may explicitly author the prior projected id" do
    slug = "tabs-optional-replacement-#{System.unique_integer([:positive])}"
    blocks = fixture_blocks()

    assert {:ok, paper} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 slug: slug,
                 dataset: @dataset,
                 blocks: blocks
               })
             )

    replacement = %{
      "id" => "switcher-tab-0-1",
      "label" => "Authored replacement",
      "blocks" => [%{"id" => "replacement-child", "type" => "paragraph", "text" => "New"}]
    }

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(
               slug,
               [
                 %{
                   "op" => "patch-block",
                   "id" => "switcher",
                   "patch" => %{"tabs" => [replacement]}
                 }
               ],
               @dataset,
               if_rev: paper.content["rev"]
             )

    [_, saved_tabs] = Content.get_paper(slug, @dataset).content["blocks"]
    assert saved_tabs["tabs"] == [replacement]
  end

  test "restoration ignores tabs-shaped opaque payloads and hidden aliases" do
    [root, tabs] = fixture_blocks()
    projected_id = "switcher-tab-0-1"

    root =
      Map.put(root, "opaque", %{
        "type" => "tabs",
        "tabs" => [%{"id" => projected_id, "label" => "Opaque"}]
      })

    [optional, explicit] = tabs["tabs"]

    optional =
      Map.put(optional, "children", [
        %{"type" => "tabs", "tabs" => [%{"id" => projected_id, "label" => "Hidden"}]}
      ])

    authored = [root, Map.put(tabs, "tabs", [optional, explicit])]
    assert {:ok, projected} = BlockOps.project_block_ids_for_edit_safely(authored)
    restored = BlockOps.restore_optional_tab_id_omissions(projected, authored)

    [restored_root, restored_tabs] = restored
    [restored_optional, _] = restored_tabs["tabs"]
    refute Map.has_key?(restored_optional, "id")
    assert get_in(restored_root, ["opaque", "tabs", Access.at(0), "id"]) == projected_id

    assert get_in(restored_optional, ["children", Access.at(0), "tabs", Access.at(0), "id"]) ==
             projected_id
  end

  defp fixture_blocks do
    [
      %{"id" => "root", "type" => "paragraph", "text" => "Before"},
      %{
        "id" => "switcher",
        "type" => "tabs",
        "tabs" => [
          %{
            "label" => "Optional",
            "blocks" => [%{"id" => "inside", "type" => "paragraph", "text" => "Kept"}]
          },
          %{"id" => "switcher-tab-0", "label" => "Explicit", "blocks" => []}
        ]
      }
    ]
  end
end
