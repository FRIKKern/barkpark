defmodule Barkpark.PortableDoc.PatchEnterAtTailTest do
  # spd-bl-enter-at-tail-block-drop — the SERVER-SIDE half of the verdict.
  #
  # The task's bar is "read the document back and say whether the removed block's CONTENT
  # survived". `Barkpark.PortableDoc.Patch` is pure (no Repo, no I/O) and IS the fold the
  # paper-ops channel runs (Content.Papers.BlockOps → Patch.apply_patches), so folding the
  # captured batch through it here IS the read-back, with no server to stand up.
  #
  # TWO batches are folded, both captured verbatim from the jsdom harness
  # (api/assets/paper-editor/src/canvas/__enter_tail.test.mjs):
  #
  #   1. WHAT MAIN ACTUALLY EMITS — insert-after(pp-001, new paragraph) + move-block x12.
  #      13 blocks in, 14 out, the tail block byte-identical. A NORMALISATION.
  #   2. THE FILED BATCH — remove-block(pp-013) + insert-after(pp-001) + move-block x11.
  #      13 blocks in, 13 out, the tail block's content GONE. Real loss — but the harness
  #      proves this batch is emitted only when the tail node was never in the live doc
  #      (an unregistered node type dropped by ProseMirror on setContent, e.g. from a stale
  #      committed bundle), NOT by Enter on current main.
  #
  # Keep the two op lists in lockstep with the harness's EXPECTED_BATCH / FILED_BATCH.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  @tail_id "pp-013"

  defp pad(n), do: "pp-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp para(n) do
    %{"id" => pad(n), "type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body #{n}."}]}
  end

  # The run the canvas mounted: 12 paragraphs + an opaque/atom node-view tail carrying
  # CONTENT the round trip must not lose.
  defp run do
    Enum.map(1..12, &para/1) ++
      [%{"id" => @tail_id, "type" => "code", "value" => "IO.puts(1)", "lang" => "elixir"}]
  end

  defp new_paragraph, do: %{"id" => "c-1-deadbeef", "type" => "paragraph", "content" => []}

  defp moves(count) do
    Enum.map(1..count, fn i -> %{"op" => "move-block", "id" => pad(i + 1), "after" => pad(i)} end)
  end

  # What Enter at the tail emits on current main (harness Part A).
  defp main_batch do
    [%{"op" => "insert-after", "afterId" => "pp-001", "block" => new_paragraph()}] ++ moves(12)
  end

  # The batch the task filed (harness Part B: only reachable when the tail never mounted).
  defp filed_batch do
    [
      %{"op" => "remove-block", "id" => @tail_id},
      %{"op" => "insert-after", "afterId" => "pp-001", "block" => new_paragraph()}
    ] ++ moves(11)
  end

  describe "the batch main actually emits (no remove-block)" do
    test "folds to 14 blocks in run order with the new paragraph LAST" do
      assert {:ok, blocks} = Patch.apply_patches(run(), main_batch())

      assert length(blocks) == 14
      assert Enum.map(blocks, & &1["id"]) == Enum.map(1..13, &pad/1) ++ ["c-1-deadbeef"]
      assert List.last(blocks) == new_paragraph()
    end

    test "the tail block's CONTENT survives BYTE-IDENTICALLY — this is a normalisation, not loss" do
      assert {:ok, blocks} = Patch.apply_patches(run(), main_batch())

      tail = Enum.find(blocks, &(&1["id"] == @tail_id))
      assert tail == List.last(run())
      assert tail["value"] == "IO.puts(1)"
      assert tail["lang"] == "elixir"
    end

    test "every ORIGINAL block survives — the fold is purely additive" do
      assert {:ok, blocks} = Patch.apply_patches(run(), main_batch())

      for original <- run() do
        assert original in blocks, "block #{original["id"]} did not survive the fold"
      end
    end
  end

  describe "the FILED batch (remove-block present) — what it would have cost" do
    test "folds to 13 blocks and the tail block's content is GONE" do
      assert {:ok, blocks} = Patch.apply_patches(run(), filed_batch())

      # The count stays 13, which is exactly why the filing says "nothing looked
      # obviously wrong" — the new paragraph backfills the removed block's slot.
      assert length(blocks) == 13
      assert Enum.find(blocks, &(&1["id"] == @tail_id)) == nil
      refute Enum.any?(blocks, &(&1["value"] == "IO.puts(1)"))
      assert Enum.map(blocks, & &1["id"]) == Enum.map(1..12, &pad/1) ++ ["c-1-deadbeef"]
    end
  end

  test "remove-block is the ONLY structural difference between the two batches" do
    assert Enum.count(main_batch(), &(&1["op"] == "remove-block")) == 0
    assert Enum.count(filed_batch(), &(&1["op"] == "remove-block")) == 1

    # Both anchor the insert at block 1: "the paragraph landed after block 1" is how
    # runToOps expresses EVERY insert (no prepend/insert-before op exists), never a
    # symptom of loss on its own.
    assert Enum.find(main_batch(), &(&1["op"] == "insert-after"))["afterId"] == "pp-001"
    assert Enum.find(filed_batch(), &(&1["op"] == "insert-after"))["afterId"] == "pp-001"
  end
end
