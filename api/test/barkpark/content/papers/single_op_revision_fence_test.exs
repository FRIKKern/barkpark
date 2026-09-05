defmodule Barkpark.Content.Papers.SingleOpRevisionFenceTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  defp seed_paper(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [
            %{"type" => "paragraph", "text" => "one", "id" => "b1"},
            %{"type" => "paragraph", "text" => "two", "id" => "b2"}
          ],
          style: "article"
        })
      )

    paper
  end

  defp paper_rev(slug), do: get_in(Content.get_paper(slug).content, ["rev"])

  defp patch_text(id, text) do
    %{"op" => "patch-block", "id" => id, "patch" => %{"text" => text}}
  end

  defp block_text(slug, id) do
    slug
    |> Content.paper_blocks()
    |> Enum.find(&(Map.get(&1, "id") == id))
    |> Map.fetch!("text")
  end

  defp subscribe(slug) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))
  end

  describe "apply_paper_block_op/4 revision fence" do
    test "matching if_rev applies once and broadcasts the new revision" do
      slug = "single-ifrev-match-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = paper_rev(slug)
      subscribe(slug)

      assert {:ok, %{rev: rev1, block_id: "b1"}} =
               Content.apply_paper_block_op(
                 slug,
                 patch_text("b1", "accepted"),
                 "production",
                 if_rev: rev0
               )

      assert rev1 == rev0 + 1
      assert paper_rev(slug) == rev1
      assert block_text(slug, "b1") == "accepted"
      assert_receive {:paper_block, %{block_id: "b1", rev: ^rev1}}
    end

    test "stale if_rev refuses the op without a write or broadcast" do
      slug = "single-ifrev-stale-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = paper_rev(slug)
      blocks0 = Content.paper_blocks(slug)
      subscribe(slug)

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_op(
                 slug,
                 patch_text("b1", "refused"),
                 "production",
                 if_rev: rev0 - 1
               )

      assert paper_rev(slug) == rev0
      assert Content.paper_blocks(slug) == blocks0
      refute_receive {:paper_block, _}, 50
    end

    test "malformed if_rev fails closed without a write or broadcast" do
      slug = "single-ifrev-malformed-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = paper_rev(slug)
      blocks0 = Content.paper_blocks(slug)
      subscribe(slug)

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_op(
                 slug,
                 patch_text("b1", "refused"),
                 "production",
                 if_rev: "not-a-revision"
               )

      assert paper_rev(slug) == rev0
      assert Content.paper_blocks(slug) == blocks0
      refute_receive {:paper_block, _}, 50
    end

    test "atomic fence rejects a writer that loses the check-to-update race" do
      slug = "single-ifrev-race-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = paper_rev(slug)
      subscribe(slug)

      competitor = fn ->
        assert {:ok, %{rev: rev1}} =
                 Content.apply_paper_block_op(
                   slug,
                   patch_text("b2", "winner"),
                   "production",
                   if_rev: rev0
                 )

        assert rev1 == rev0 + 1
      end

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_op(
                 slug,
                 patch_text("b1", "loser"),
                 "production",
                 if_rev: rev0,
                 before_fenced_write: competitor
               )

      assert paper_rev(slug) == rev0 + 1
      assert block_text(slug, "b1") == "one"
      assert block_text(slug, "b2") == "winner"
      assert_receive {:paper_block, %{block_id: "b2", rev: rev1}}
      assert rev1 == rev0 + 1
      refute_receive {:paper_block, _}, 50
    end

    test "omitting if_rev preserves the existing last-write-wins contract" do
      slug = "single-ifrev-absent-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = paper_rev(slug)

      assert {:ok, %{rev: rev1}} =
               Content.apply_paper_block_op(slug, patch_text("b1", "first"))

      assert {:ok, %{rev: rev2}} =
               Content.apply_paper_block_op(slug, patch_text("b1", "second"))

      assert rev1 == rev0 + 1
      assert rev2 == rev1 + 1
      assert block_text(slug, "b1") == "second"
      assert block_text(slug, "b2") == "two"
    end
  end
end
