defmodule Barkpark.PortableDoc.PatchBatchDuplicatesTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp paragraph(id, text), do: %{"id" => id, "type" => "paragraph", "text" => text}
  defp section(id, children), do: %{"id" => id, "type" => "section", "blocks" => children}

  defp two_sections do
    [
      section("s-1", [paragraph("p-a", "Alpha.")]),
      section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
    ]
  end

  describe "a batch is judged for duplicates at its end" do
    test "a move up from section 2 into section 1 lands: replace s-1 before replace s-2" do
      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
        },
        %{
          "op" => "replace-block",
          "id" => "s-2",
          "block" => section("s-2", [paragraph("p-b", "Beta.")])
        }
      ]

      assert {:ok,
              [
                section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")]),
                section("s-2", [paragraph("p-b", "Beta.")])
              ]} == Patch.apply_patches(two_sections(), ops)
    end

    test "a move down from section 1 into section 2 lands" do
      blocks = [
        section("s-1", [paragraph("p-a", "Alpha."), paragraph("p-x", "Original X.")]),
        section("s-2", [paragraph("p-b", "Beta.")])
      ]

      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-a", "Alpha.")])
        },
        %{
          "op" => "replace-block",
          "id" => "s-2",
          "block" => section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
        }
      ]

      assert {:ok,
              [
                section("s-1", [paragraph("p-a", "Alpha.")]),
                section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
              ]} == Patch.apply_patches(blocks, ops)
    end

    test "the move's first op alone is a batch of one, so it still refuses" do
      first = %{
        "op" => "replace-block",
        "id" => "s-1",
        "block" => section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
      }

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} =
               Patch.apply_patch(two_sections(), first)

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} =
               Patch.apply_patches(two_sections(), [first])
    end

    test "a batch that ends with a copy in both sections is refused, naming the op that added it" do
      ops = [
        %{"op" => "patch-block", "id" => "p-a", "patch" => %{"text" => "Alpha!"}},
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Copy."), paragraph("p-a", "Alpha!")])
        },
        %{"op" => "patch-block", "id" => "p-b", "patch" => %{"text" => "Beta!"}}
      ]

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} =
               Patch.apply_patches(two_sections(), ops)
    end

    test "a copy added, removed and added again names the last op that added it" do
      copy = %{"op" => "insert-after", "afterId" => "p-a", "block" => paragraph("p-y", "Y.")}

      ops = [
        copy,
        %{"op" => "remove-block", "id" => "p-y"},
        %{
          "op" => "patch-block",
          "id" => "s-2",
          "patch" => %{
            "blocks" => [
              paragraph("p-b", "Beta."),
              paragraph("p-x", "X."),
              paragraph("p-y", "Y2.")
            ]
          }
        },
        copy
      ]

      assert {:error, {:duplicate_id, "p-y", "insert-after"}} =
               Patch.apply_patches(two_sections(), ops)
    end

    test "a legacy duplicate survives an unrelated batch untouched" do
      blocks = [paragraph("dup", "Top."), section("s-1", [paragraph("dup", "Nested.")])]
      ops = [%{"op" => "patch-block", "id" => "s-1", "patch" => %{"title" => "Day"}}]

      assert {:ok,
              [
                paragraph("dup", "Top."),
                Map.put(section("s-1", [paragraph("dup", "Nested.")]), "title", "Day")
              ]} ==
               Patch.apply_patches(blocks, ops)
    end

    test "a document map is judged the same way" do
      doc = %{"version" => 1, "blocks" => two_sections()}

      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Copy.")])
        }
      ]

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} = Patch.apply_patches(doc, ops)
    end
  end

  describe "only a repeat the batch adds is refused" do
    test "a legacy pair that grows to three is refused" do
      blocks = [paragraph("p-d", "Top."), section("s-1", [paragraph("p-d", "Nested.")])]

      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-d", "Nested."), paragraph("p-d", "Third.")])
        }
      ]

      assert {:error, {:duplicate_id, "p-d", "replace-block"}} = Patch.apply_patches(blocks, ops)
    end

    test "one id moved and another copied in the same batch: the copy is refused" do
      blocks = two_sections() ++ [section("s-3", [paragraph("p-c", "Gamma.")])]

      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
        },
        %{
          "op" => "replace-block",
          "id" => "s-2",
          "block" => section("s-2", [paragraph("p-b", "Beta.")])
        },
        %{
          "op" => "replace-block",
          "id" => "s-3",
          "block" => section("s-3", [paragraph("p-c", "Gamma."), paragraph("p-x", "Copy.")])
        }
      ]

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} = Patch.apply_patches(blocks, ops)
    end

    test "a legacy pair that shrinks does not pay for another id that doubles" do
      blocks = [
        paragraph("p-d", "Top."),
        section("s-1", [paragraph("p-d", "Nested."), paragraph("p-x", "X.")])
      ]

      ops = [
        %{"op" => "remove-block", "id" => "p-d"},
        %{"op" => "append-block", "block" => paragraph("p-x", "Copy.")}
      ]

      assert {:error, {:duplicate_id, "p-x", "append-block"}} = Patch.apply_patches(blocks, ops)
    end

    test "an old editor's nested Enter repeats the id inside one block, so it is refused" do
      blocks = [section("s-day", [paragraph("p-day", "Left the car park at six.")])]

      op = %{
        "op" => "replace-block",
        "id" => "s-day",
        "block" =>
          section("s-day", [
            paragraph("p-day", "Left the car park at six."),
            paragraph("p-day", "Fog by eight.")
          ])
      }

      assert {:error, {:duplicate_id, "p-day", "replace-block"}} = Patch.apply_patch(blocks, op)

      assert {:error, {:duplicate_id, "p-day", "replace-block"}} =
               Patch.apply_patches(blocks, [op])
    end

    test "a leftover copy and a later bad op answer the later op's error" do
      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Copy."), paragraph("p-a", "Alpha.")])
        },
        %{"op" => "patch-block", "id" => "p-missing", "patch" => %{"text" => "z"}}
      ]

      assert {:error, {:block_not_found, "p-missing", "patch-block"}} =
               Patch.apply_patches(two_sections(), ops)
    end
  end

  describe "an op that names an id the batch has made repeated is refused" do
    defp down do
      [
        section("s-1", [paragraph("p-a", "Alpha."), paragraph("p-x", "Original X.")]),
        section("s-2", [paragraph("p-b", "Beta.")])
      ]
    end

    test "a move down with an edit of the moved paragraph between its two replaces" do
      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-2",
          "block" => section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
        },
        %{"op" => "patch-block", "id" => "p-x", "patch" => %{"text" => "Original X. Edited."}},
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-a", "Alpha.")])
        }
      ]

      assert {:error, {:duplicate_id, "p-x", "patch-block"}} = Patch.apply_patches(down(), ops)
    end

    test "a move up, then a remove of the old copy by id" do
      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" =>
            section("s-1", [
              paragraph("p-x", "Original X. Moved and edited."),
              paragraph("p-a", "Alpha.")
            ])
        },
        %{"op" => "remove-block", "id" => "p-x"}
      ]

      assert {:error, {:duplicate_id, "p-x", "remove-block"}} =
               Patch.apply_patches(two_sections(), ops)
    end

    test "an insert after an id the batch has made repeated" do
      ops = [
        %{
          "op" => "replace-block",
          "id" => "s-1",
          "block" => section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
        },
        %{"op" => "insert-after", "afterId" => "p-x", "block" => paragraph("p-n", "New.")}
      ]

      assert {:error, {:duplicate_id, "p-x", "insert-after"}} =
               Patch.apply_patches(two_sections(), ops)
    end

    test "an op on a legacy duplicate the batch did not add keeps the first match" do
      blocks = [paragraph("dup", "Top."), section("s-1", [paragraph("dup", "Nested.")])]
      ops = [%{"op" => "patch-block", "id" => "dup", "patch" => %{"text" => "Top!"}}]

      assert {:ok, [paragraph("dup", "Top!"), section("s-1", [paragraph("dup", "Nested.")])]} ==
               Patch.apply_patches(blocks, ops)
    end
  end
end
