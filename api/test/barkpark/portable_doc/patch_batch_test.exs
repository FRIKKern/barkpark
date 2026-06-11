defmodule Barkpark.PortableDoc.PatchBatchTest do
  # Pure, in-process tests for `apply_patches/2` — the all-or-nothing batch
  # fold over the single-op `apply_patch/2`. No DB.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp doc do
    %{
      "version" => 1,
      "title" => "T",
      "blocks" => [
        %{"id" => "a", "type" => "paragraph", "text" => "A"},
        %{"id" => "b", "type" => "paragraph", "text" => "B"}
      ]
    }
  end

  describe "apply_patches/2 — all ops succeed" do
    test "applies every op in order and returns {:ok, doc}" do
      ops = [
        %{
          "op" => "append-block",
          "block" => %{"id" => "c", "type" => "paragraph", "text" => "C"}
        },
        %{"op" => "patch-block", "id" => "a", "patch" => %{"text" => "A2"}},
        %{"op" => "remove-block", "id" => "b"}
      ]

      assert {:ok, result} = Patch.apply_patches(doc(), ops)

      ids = Enum.map(result["blocks"], & &1["id"])
      assert ids == ["a", "c"]
      assert Enum.find(result["blocks"], &(&1["id"] == "a"))["text"] == "A2"
    end

    test "empty op list is an {:ok, doc} no-op returning the input unchanged" do
      assert {:ok, result} = Patch.apply_patches(doc(), [])
      assert result == doc()
    end

    test "works on a bare block list too" do
      blocks = doc()["blocks"]
      ops = [%{"op" => "remove-block", "id" => "a"}]
      assert {:ok, result} = Patch.apply_patches(blocks, ops)
      assert Enum.map(result, & &1["id"]) == ["b"]
    end
  end

  describe "apply_patches/2 — middle op fails ⇒ rolls back (all-or-nothing)" do
    test "halts on the first error and returns the ORIGINAL doc unchanged" do
      original = doc()

      ops = [
        # op 1 — fine
        %{"op" => "patch-block", "id" => "a", "patch" => %{"text" => "A2"}},
        # op 2 — FAILS: target id does not exist
        %{"op" => "remove-block", "id" => "does-not-exist"},
        # op 3 — would succeed, but must never run
        %{"op" => "append-block", "block" => %{"id" => "z", "type" => "paragraph", "text" => "Z"}}
      ]

      assert {:error, {:block_not_found, "does-not-exist", "remove-block"}} =
               Patch.apply_patches(original, ops)

      # The caller still holds the original, untouched (Patch is pure — the
      # partial result from op 1 was discarded on halt, op 3 never ran).
      assert original == doc()
      assert Enum.find(original["blocks"], &(&1["id"] == "a"))["text"] == "A"
      refute Enum.any?(original["blocks"], &(&1["id"] == "z"))
    end

    test "first-op failure returns the error and the original doc" do
      original = doc()
      ops = [%{"op" => "patch-block", "id" => "nope", "patch" => %{"text" => "x"}}]

      assert {:error, {:block_not_found, "nope", "patch-block"}} =
               Patch.apply_patches(original, ops)

      assert original == doc()
    end

    test "an invalid op halts the batch" do
      original = doc()

      ops = [
        %{"op" => "append-block", "block" => %{"id" => "c", "type" => "paragraph"}},
        %{"op" => "bogus-op", "id" => "a"}
      ]

      assert {:error, {:invalid_op, %{"op" => "bogus-op"}}} =
               Patch.apply_patches(original, ops)

      assert original == doc()
    end
  end
end
