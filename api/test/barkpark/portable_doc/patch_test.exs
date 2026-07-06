defmodule Barkpark.PortableDoc.PatchTest do
  # Conformance suite for the standalone Elixir patch engine — pure, no DB.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  # The golden fixtures under `api/test/support/fixtures/doc-patch-op/` ARE the
  # source of truth for the block-tree op semantics — the same fixtures the
  # `Barkpark.PortableDoc.Patch` @moduledoc pins the engine to. This suite is
  # self-contained: it reads only that in-tree dir (no cross-repo absolute path,
  # so it never breaks in CI / fresh clones).
  @fixtures_dir Path.join(__DIR__, "../../support/fixtures/doc-patch-op")

  describe "conformance — golden fixtures reproduce `after` from `before` + `op`" do
    # One generated test per fixture file. The op contract's conformance rule:
    # apply_patch(before, op) == after.
    for path <- Path.wildcard(Path.join(@fixtures_dir, "*.json")) do
      name = Path.basename(path, ".json")

      test "#{name}.json" do
        %{"before" => before, "op" => op, "after" => expected} =
          unquote(path) |> File.read!() |> Jason.decode!()

        assert {:ok, after_doc} = Patch.apply_patch(before, op)
        assert after_doc == expected
      end
    end

    test "all five ops are covered by a fixture" do
      ops =
        @fixtures_dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.map(fn path ->
          path |> File.read!() |> Jason.decode!() |> get_in(["op", "op"])
        end)
        |> Enum.sort()

      assert ops ==
               ["append-block", "insert-after", "patch-block", "remove-block", "replace-block"]
    end
  end

  describe "purity / immutability" do
    test "the input document is returned untouched on success" do
      before = %{
        "version" => 1,
        "blocks" => [%{"id" => "a", "type" => "divider"}]
      }

      {:ok, after_doc} = Patch.apply_patch(before, append("b", "divider"))

      # original still has one block; result has two — input was not mutated
      assert length(before["blocks"]) == 1
      assert length(after_doc["blocks"]) == 2
    end

    test "operates on a bare block list and returns a bare block list" do
      blocks = [%{"id" => "a", "type" => "divider"}]

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
               Patch.apply_patch(blocks, append("b", "divider"))
    end
  end

  describe "append-block — top-level only" do
    test "appends to the end of the top-level blocks" do
      doc = doc_with([%{"id" => "a", "type" => "divider"}])
      {:ok, %{"blocks" => blocks}} = Patch.apply_patch(doc, append("z", "divider"))
      assert Enum.map(blocks, & &1["id"]) == ["a", "z"]
    end

    test "rejects an id that already exists anywhere in the tree" do
      doc =
        doc_with([
          %{
            "id" => "sec",
            "type" => "section",
            "blocks" => [%{"id" => "nested", "type" => "divider"}]
          }
        ])

      assert {:error, {:duplicate_id, "nested", "append-block"}} =
               Patch.apply_patch(doc, append("nested", "divider"))
    end
  end

  describe "insert-after — recurses into sections" do
    test "lands a sibling inside the same section as the anchor" do
      doc =
        doc_with([
          %{
            "id" => "sec",
            "type" => "section",
            "blocks" => [%{"id" => "anchor", "type" => "divider"}]
          }
        ])

      {:ok, %{"blocks" => [section]}} =
        Patch.apply_patch(doc, %{
          "op" => "insert-after",
          "afterId" => "anchor",
          "block" => %{"id" => "new", "type" => "divider"}
        })

      assert Enum.map(section["blocks"], & &1["id"]) == ["anchor", "new"]
    end

    test "block-not-found when afterId exists nowhere" do
      doc = doc_with([%{"id" => "a", "type" => "divider"}])

      assert {:error, {:block_not_found, "ghost", "insert-after"}} =
               Patch.apply_patch(doc, %{
                 "op" => "insert-after",
                 "afterId" => "ghost",
                 "block" => %{"id" => "new", "type" => "divider"}
               })
    end

    test "duplicate-id when the inserted block collides" do
      doc = doc_with([%{"id" => "a", "type" => "divider"}])

      assert {:error, {:duplicate_id, "a", "insert-after"}} =
               Patch.apply_patch(doc, %{
                 "op" => "insert-after",
                 "afterId" => "a",
                 "block" => %{"id" => "a", "type" => "divider"}
               })
    end
  end

  describe "patch-block — shallow merge, immutable id+type" do
    test "shallow-merges and re-pins id+type, replacing arrays wholesale" do
      doc =
        doc_with([
          %{
            "id" => "p",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "old"}]
          }
        ])

      {:ok, %{"blocks" => [block]}} =
        Patch.apply_patch(doc, %{
          "op" => "patch-block",
          "id" => "p",
          "patch" => %{"content" => [%{"type" => "text", "value" => "new"}]}
        })

      assert block["id"] == "p"
      assert block["type"] == "paragraph"
      # array replaced wholesale, not concatenated
      assert block["content"] == [%{"type" => "text", "value" => "new"}]
    end

    test "a patch cannot mutate id or type" do
      doc = doc_with([%{"id" => "p", "type" => "paragraph", "content" => []}])

      {:ok, %{"blocks" => [block]}} =
        Patch.apply_patch(doc, %{
          "op" => "patch-block",
          "id" => "p",
          "patch" => %{"id" => "evil", "content" => []}
        })

      assert block["id"] == "p"
    end

    test "type-mismatch when patch.type differs from the target's type" do
      doc = doc_with([%{"id" => "p", "type" => "paragraph", "content" => []}])

      assert {:error, {:type_mismatch, "p", "patch-block"}} =
               Patch.apply_patch(doc, %{
                 "op" => "patch-block",
                 "id" => "p",
                 "patch" => %{"type" => "heading"}
               })
    end

    test "block-not-found when the id exists nowhere" do
      doc = doc_with([%{"id" => "p", "type" => "paragraph", "content" => []}])

      assert {:error, {:block_not_found, "ghost", "patch-block"}} =
               Patch.apply_patch(doc, %{"op" => "patch-block", "id" => "ghost", "patch" => %{}})
    end
  end

  describe "replace-block — wholesale, may change type and id" do
    test "replaces inside a section and may change type + id" do
      doc =
        doc_with([
          %{
            "id" => "sec",
            "type" => "section",
            "blocks" => [%{"id" => "old", "type" => "paragraph", "content" => []}]
          }
        ])

      {:ok, %{"blocks" => [section]}} =
        Patch.apply_patch(doc, %{
          "op" => "replace-block",
          "id" => "old",
          "block" => %{"id" => "new", "type" => "divider"}
        })

      assert [%{"id" => "new", "type" => "divider"}] = section["blocks"]
    end

    test "block-not-found when the id exists nowhere" do
      doc = doc_with([%{"id" => "a", "type" => "divider"}])

      assert {:error, {:block_not_found, "ghost", "replace-block"}} =
               Patch.apply_patch(doc, %{
                 "op" => "replace-block",
                 "id" => "ghost",
                 "block" => %{"id" => "x", "type" => "divider"}
               })
    end
  end

  describe "remove-block — recurses, removes whole section subtrees" do
    test "removes a nested block from its parent section" do
      doc =
        doc_with([
          %{
            "id" => "sec",
            "type" => "section",
            "blocks" => [
              %{"id" => "keep", "type" => "divider"},
              %{"id" => "drop", "type" => "divider"}
            ]
          }
        ])

      {:ok, %{"blocks" => [section]}} =
        Patch.apply_patch(doc, %{"op" => "remove-block", "id" => "drop"})

      assert Enum.map(section["blocks"], & &1["id"]) == ["keep"]
    end

    test "removing a section removes everything nested inside it" do
      doc =
        doc_with([
          %{
            "id" => "sec",
            "type" => "section",
            "blocks" => [%{"id" => "nested", "type" => "divider"}]
          },
          %{"id" => "tail", "type" => "divider"}
        ])

      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(doc, %{"op" => "remove-block", "id" => "sec"})

      assert Enum.map(blocks, & &1["id"]) == ["tail"]
    end

    test "removing an absent id is an idempotent no-op (not an error)" do
      # Bug #1b fix: removing an already-absent block is a NO-OP, not
      # {:block_not_found}. The desired end-state (id gone) is already true, so a
      # stale/duplicate remove-block must NOT halt an atomic batch and discard the
      # user's co-batched edits. (This test previously asserted the
      # {:block_not_found, "ghost", "remove-block"} error — that encoded the bug.)
      doc = doc_with([%{"id" => "a", "type" => "divider"}])

      assert {:ok, %{"blocks" => blocks}} =
               Patch.apply_patch(doc, %{"op" => "remove-block", "id" => "ghost"})

      assert Enum.map(blocks, & &1["id"]) == ["a"]
    end
  end

  describe "move-block — top-level reorder, pure permutation" do
    defp abc_doc do
      doc_with([
        %{"id" => "a", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "A"}]},
        %{"id" => "b", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]},
        %{"id" => "c", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "C"}]}
      ])
    end

    test "moves a block to just after the named anchor" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "c", "after" => "a"})

      assert Enum.map(blocks, & &1["id"]) == ["a", "c", "b"]
    end

    test "after: null moves the block to the front" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "c", "after" => nil})

      assert Enum.map(blocks, & &1["id"]) == ["c", "a", "b"]
    end

    test "an absent after key also moves the block to the front" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "b"})

      assert Enum.map(blocks, & &1["id"]) == ["b", "a", "c"]
    end

    test "moving to the tail (after the last block)" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "a", "after" => "c"})

      assert Enum.map(blocks, & &1["id"]) == ["b", "c", "a"]
    end

    test "the moved block keeps its full content (no duplication)" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "c", "after" => nil})

      moved = Enum.find(blocks, &(&1["id"] == "c"))
      assert moved["content"] == [%{"type" => "text", "value" => "C"}]
      # Exactly one copy of each id survives — a permutation, not a duplication.
      assert length(blocks) == 3
      assert Enum.uniq(Enum.map(blocks, & &1["id"])) == Enum.map(blocks, & &1["id"])
    end

    test "moving a block after itself is an idempotent no-op" do
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "b", "after" => "b"})

      assert Enum.map(blocks, & &1["id"]) == ["a", "b", "c"]
    end

    test "moving an absent id is an idempotent no-op (not an error)" do
      # Bug #1b fix: moving an already-absent block is a NO-OP, not
      # {:block_not_found} — same idempotent re-send safety as remove-block. A stale
      # move of a block that a leading-block delete already removed must NOT halt the
      # atomic batch. (Previously asserted {:block_not_found, "ghost", "move-block"} —
      # that encoded the bug.) The anchor-missing case below STILL errors, since a
      # present block with an undefined destination is a real failure.
      {:ok, %{"blocks" => blocks}} =
        Patch.apply_patch(abc_doc(), %{"op" => "move-block", "id" => "ghost"})

      assert Enum.map(blocks, & &1["id"]) == ["a", "b", "c"]
    end

    test "block-not-found when the anchor id does not exist" do
      assert {:error, {:block_not_found, "ghost", "move-block"}} =
               Patch.apply_patch(abc_doc(), %{
                 "op" => "move-block",
                 "id" => "a",
                 "after" => "ghost"
               })
    end
  end

  describe "malformed input" do
    test "an unknown op discriminator returns :invalid_op" do
      doc = doc_with([])
      assert {:error, {:invalid_op, _}} = Patch.apply_patch(doc, %{"op" => "frobnicate"})
    end
  end

  # ── the constraint-vocabulary op-layer backstop (pdd-t20) ──────────────────
  #
  # The `:constraints` opt threads a `Barkpark.PortableDoc.Constraints`
  # declaration list; an op whose RESULT breaks a cardinality / relative-order
  # rule is rejected `{:constraint, message, op}` — the calm sibling of
  # `{:locked_block, …}`. These docs use UNLOCKED role-carrying blocks so the
  # constraint path is what fires (a locked block would be caught first by the
  # placement check). D12: the veto is guarded on the doc being VALID before the
  # op; with no declarations the engine is byte-identical.
  describe "constraint backstop — cardinality + relative order (fail-before)" do
    # title required exactly-1 @0; featured optional max-1 after title.
    defp title_featured_decls do
      [
        %{kind: "title", presence: :required, count: {:exactly, 1}, position: {:index, 0}},
        %{kind: "featured", presence: :optional, count: {:max, 1}, position: {:after, "title"}}
      ]
    end

    defp title_featured_doc do
      doc_with([
        %{"id" => "t", "type" => "heading", "role" => "title", "text" => "T"},
        %{"id" => "f", "type" => "image", "role" => "featured"}
      ])
    end

    test "move-block putting featured before title is vetoed calmly" do
      # move featured to the head → featured@0, title@1: title leaves index 0 and
      # featured no longer sits after title. Valid before, invalid after ⇒ reject.
      assert {:error, {:constraint, msg, "move-block"}} =
               Patch.apply_patch(
                 title_featured_doc(),
                 %{"op" => "move-block", "id" => "f", "after" => nil},
                 constraints: title_featured_decls()
               )

      assert is_binary(msg)
    end

    test "insert-after adding a SECOND role:featured breaks max-1 ⇒ rejected" do
      assert {:error, {:constraint, _msg, "insert-after"}} =
               Patch.apply_patch(
                 title_featured_doc(),
                 %{
                   "op" => "insert-after",
                   "afterId" => "t",
                   "block" => %{"id" => "f2", "type" => "image", "role" => "featured"}
                 },
                 constraints: title_featured_decls()
               )
    end

    test "remove-block dropping below a synthetic min-2 is vetoed like a locked op" do
      # The wish's exact case: a remove breaking min-N is rejected calmly.
      doc =
        doc_with([
          %{"id" => "x1", "type" => "paragraph", "role" => "x"},
          %{"id" => "x2", "type" => "paragraph", "role" => "x"}
        ])

      assert {:error, {:constraint, _msg, "remove-block"}} =
               Patch.apply_patch(
                 doc,
                 %{"op" => "remove-block", "id" => "x2"},
                 constraints: [%{kind: "x", count: {:min, 2}}]
               )
    end

    test "a valid op on a valid doc still succeeds with declarations present" do
      # Positive control: patching the title's text keeps the shape valid.
      assert {:ok, %{"blocks" => [title | _]}} =
               Patch.apply_patch(
                 title_featured_doc(),
                 %{"op" => "patch-block", "id" => "t", "patch" => %{"text" => "T2"}},
                 constraints: title_featured_decls()
               )

      assert title["text"] == "T2"
    end

    test "an ALREADY-invalid doc + an unrelated op is ACCEPTED (D12 before-valid guard)" do
      # A legacy paper with a featured but no title violates the declarations
      # BEFORE the op. An unrelated patch must NOT be punished for that.
      legacy =
        doc_with([%{"id" => "f", "type" => "image", "role" => "featured", "alt" => "old"}])

      assert {:ok, %{"blocks" => [block]}} =
               Patch.apply_patch(
                 legacy,
                 %{"op" => "patch-block", "id" => "f", "patch" => %{"alt" => "new"}},
                 constraints: title_featured_decls()
               )

      assert block["alt"] == "new"
    end

    test "with NO declarations, a would-be-violating op is byte-identical to today" do
      # Same move that the constraint path vetoes above — with no declarations it
      # applies exactly as the pre-vocabulary engine did.
      op = %{"op" => "move-block", "id" => "f", "after" => nil}

      assert Patch.apply_patch(title_featured_doc(), op) ==
               Patch.apply_patch(title_featured_doc(), op, constraints: [])

      assert {:ok, %{"blocks" => blocks}} = Patch.apply_patch(title_featured_doc(), op)
      assert Enum.map(blocks, & &1["id"]) == ["f", "t"]
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp doc_with(blocks), do: %{"version" => 1, "blocks" => blocks}

  defp append(id, type),
    do: %{"op" => "append-block", "block" => %{"id" => id, "type" => type}}
end
