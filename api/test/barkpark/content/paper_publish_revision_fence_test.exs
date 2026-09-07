defmodule Barkpark.Content.PaperPublishRevisionFenceTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  defp seed do
    slug = "publish-editor-fence-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [
            %{
              "id" => "quote",
              "type" => "blockquote",
              "text" => "Preserve this quotation.",
              "cite" => "Original author",
              "qa" => %{"keep" => true}
            },
            %{"id" => "tail", "type" => "paragraph", "text" => "The neighboring text remains."}
          ]
        })
      )

    {slug, paper}
  end

  defp fork_citation(slug, paper, cite) do
    blocks =
      Enum.map(paper.content["blocks"], fn
        %{"id" => "quote"} = block -> Map.put(block, "cite", cite)
        block -> block
      end)

    assert {:ok, _} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => slug,
                     "type" => "paper",
                     "ifRevisionID" => paper.rev,
                     "set" => %{"blocks" => blocks}
                   }
                 }
               ],
               "production"
             )
  end

  defp edit_citation(slug, rev, cite) do
    Content.apply_paper_block_op(
      slug,
      %{"op" => "patch-block", "id" => "quote", "patch" => %{"cite" => cite}},
      "production",
      if_rev: rev
    )
  end

  test "whole-document publish invalidates the focused editor's streaming revision" do
    {slug, original} = seed()
    rev = original.content["rev"]
    fork_citation(slug, original, "Published author")
    assert {:ok, published} = Content.publish_document(slug, "paper", "production")
    assert published.rev != original.rev
    assert published.content["rev"] == rev + 1
    assert {:error, :precondition_failed} = edit_citation(slug, rev, "Stale local author")

    assert Enum.find(Content.paper_blocks(slug), &(&1["id"] == "quote"))["cite"] ==
             "Published author"

    assert {:ok, %{rev: accepted}} =
             edit_citation(slug, published.content["rev"], "Explicitly kept author")

    assert accepted == published.content["rev"] + 1

    assert Enum.find(Content.paper_blocks(slug), &(&1["id"] == "quote"))["qa"] == %{
             "keep" => true
           }
  end

  test "publishing an older draft cannot recycle the current editor revision" do
    {slug, original} = seed()
    fork_citation(slug, original, "Older draft author")

    assert {:ok, %{rev: current}} =
             edit_citation(slug, original.content["rev"], "Newer editor author")

    assert {:ok, published} = Content.publish_document(slug, "paper", "production")
    assert published.content["rev"] == current + 1
    assert {:error, :precondition_failed} = edit_citation(slug, current, "Stale after publish")
  end
end
