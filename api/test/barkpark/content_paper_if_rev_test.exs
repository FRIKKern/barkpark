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

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "added", "id" => "b2"}
        }
      ]

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

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "nope", "id" => "bx"}
        }
      ]

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

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "ok", "id" => "b2"}
        }
      ]

      assert {:ok, result} = Content.apply_paper_block_ops(slug, ops)
      assert result.rev == rev0 + 1
    end

    # ── CAS FENCE (unfenced check-then-write race) ─────────────────────────
    #
    # `check_paper_if_rev/2` validated the client's ifRev against the row it
    # READ; the persist USED to be a plain `Repo.update` (WHERE id = pk). Two
    # concurrent batches both holding the SAME base rev both pass that check,
    # and the second silently CLOBBERED the first (lost update) despite a
    # satisfied precondition. The write is now fenced on the row's opaque rev
    # read at load; a stale batch matches 0 rows → :precondition_failed.

    test "fenced batch losing a concurrent-rev race → :precondition_failed, stale write never lands" do
      slug = "ifrev-fence-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)
      blocks_before = Content.paper_blocks(slug)

      # The victim asserts ifRev = rev0 (matches at check time). The seam fires a
      # COMPETING batch at the SAME base rev0 in the window between the guard read
      # and the fenced UPDATE — it wins, bumping the row's opaque rev. Pre-fix the
      # victim's plain `Repo.update` would then clobber that winner despite both
      # having passed the ifRev check. Post-fix the fence rejects the stale write.
      competitor = fn ->
        {:ok, _} =
          Content.apply_paper_block_ops(
            slug,
            [
              %{
                "op" => "append-block",
                "block" => %{"type" => "paragraph", "text" => "WINNER", "id" => "b-win"}
              }
            ],
            "production",
            if_rev: rev0
          )
      end

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "CLOBBER", "id" => "b-lose"}
        }
      ]

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, ops, "production",
                 if_rev: rev0,
                 before_fenced_write: competitor
               )

      # The winner's write stands; the loser's block never landed. Exactly ONE
      # rev bump — no lost update.
      after_blocks = Content.paper_blocks(slug)
      ids = Enum.map(after_blocks, &Map.get(&1, "id"))
      assert "b-win" in ids
      refute "b-lose" in ids
      assert current_rev(slug) == rev0 + 1
      refute after_blocks == blocks_before
    end

    test "two sequential batches at the same base rev — the second is rejected, no clobber" do
      slug = "ifrev-cas-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)

      first = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "A", "id" => "bA"}
        }
      ]

      second = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "B", "id" => "bB"}
        }
      ]

      assert {:ok, %{rev: rev1}} =
               Content.apply_paper_block_ops(slug, first, "production", if_rev: rev0)

      assert rev1 == rev0 + 1

      # Second batch still asserts the STALE base rev0 → rejected, no clobber.
      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, second, "production", if_rev: rev0)

      ids = slug |> Content.paper_blocks() |> Enum.map(&Map.get(&1, "id"))
      assert "bA" in ids
      refute "bB" in ids
      assert current_rev(slug) == rev0 + 1
    end

    test "non-integer ifRev is rejected (precondition fails closed)" do
      slug = "ifrev-bad-#{System.unique_integer([:positive])}"
      seed_paper(slug)
      rev0 = current_rev(slug)

      ops = [
        %{
          "op" => "append-block",
          "block" => %{"type" => "paragraph", "text" => "x", "id" => "b2"}
        }
      ]

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, ops, "production", if_rev: "not-a-rev")

      assert current_rev(slug) == rev0
    end
  end
end
