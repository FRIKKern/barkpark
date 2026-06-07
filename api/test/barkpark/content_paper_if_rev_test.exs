defmodule Barkpark.ContentPaperIfRevTest do
  @moduledoc """
  M3 optimistic-concurrency guard for the batch paper-ops path.

  `Content.apply_paper_block_ops/4` accepts an optional `:if_rev`. When present
  and != the paper's CURRENT rev, the batch is rejected with
  `{:error, :precondition_failed}` BEFORE any op applies — the paper is left
  untouched at its original rev (rollback). Absent `:if_rev` keeps the prior
  behaviour.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  defp seed_paper(slug) do
    {:ok, paper} =
      Content.upsert_paper(%{
        slug: slug,
        blocks: [%{"type" => "paragraph", "text" => "seed", "id" => "b1"}],
        style: "article"
      })

    paper
  end

  defp current_rev(slug) do
    get_in(Content.get_paper(slug).content, ["rev"])
  end

  describe "apply_paper_block_ops/4 — :if_rev guard" do
    test "matching ifRev applies the batch and bumps the rev" do
      slug = "ifrev-match-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)

      ops = [%{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "added", "id" => "b2"}}]

      assert {:ok, result} =
               Content.apply_paper_block_ops(slug, ops, "production", if_rev: rev0)

      assert result.rev == rev0 + 1
      assert current_rev(slug) == rev0 + 1
      # The op landed.
      assert length(Content.paper_blocks(slug)) == 2
    end

    test "stale ifRev is rejected with :precondition_failed and rolls back (no op applied)" do
      slug = "ifrev-stale-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)
      blocks_before = Content.paper_blocks(slug)

      stale = rev0 - 1

      ops = [%{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "nope", "id" => "bx"}}]

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, ops, "production", if_rev: stale)

      # Paper UNCHANGED: same rev, same block list — the rollback guarantee.
      assert current_rev(slug) == rev0
      assert Content.paper_blocks(slug) == blocks_before
    end

    test "absent ifRev keeps prior behaviour (applies)" do
      slug = "ifrev-absent-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)

      ops = [%{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "ok", "id" => "b2"}}]

      assert {:ok, result} = Content.apply_paper_block_ops(slug, ops)
      assert result.rev == rev0 + 1
    end

    test "non-integer ifRev is rejected (precondition fails closed)" do
      slug = "ifrev-bad-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)

      ops = [%{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "x", "id" => "b2"}}]

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, ops, "production", if_rev: "not-a-rev")

      assert current_rev(slug) == rev0
    end
  end
end
