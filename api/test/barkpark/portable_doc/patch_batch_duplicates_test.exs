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

  describe "a repeat inside one incoming block is re-minted" do
    test "old-client nested Enter: the first copy keeps the id, the second gets a fresh one" do
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

      expected = [
        section("s-day", [
          paragraph("p-day", "Left the car park at six."),
          paragraph("s-day-1", "Fog by eight.")
        ])
      ]

      assert {:ok, expected} == Patch.apply_patch(blocks, op)
      assert {:ok, expected} == Patch.apply_patches(blocks, [op])
    end

    test "the fresh id never takes an id the document already holds" do
      blocks = [paragraph("s-day-1", "Taken."), section("s-day", [paragraph("p-day", "A.")])]

      op = %{
        "op" => "replace-block",
        "id" => "s-day",
        "block" => section("s-day", [paragraph("p-day", "A."), paragraph("p-day", "B.")])
      }

      assert {:ok,
              [
                paragraph("s-day-1", "Taken."),
                section("s-day", [paragraph("p-day", "A."), paragraph("s-day-1-1", "B.")])
              ]} == Patch.apply_patch(blocks, op)
    end

    test "an insert carrying a repeat inside itself is re-minted, top level and nested" do
      block =
        section("s-new", [
          paragraph("p-n", "One."),
          paragraph("p-n", "Two."),
          paragraph("p-n", "Three.")
        ])

      assert {:ok, [_, %{"id" => "s-new", "blocks" => children}]} =
               Patch.apply_patch([paragraph("p-a", "A.")], %{
                 "op" => "append-block",
                 "block" => block
               })

      assert Enum.map(children, & &1["id"]) == ["p-n", "s-new-1", "s-new-2"]
    end

    test "a repeat of an id held elsewhere is not re-minted: that is a real duplicate" do
      op = %{
        "op" => "replace-block",
        "id" => "s-1",
        "block" => section("s-1", [paragraph("p-a", "Alpha."), paragraph("p-b", "Stolen.")])
      }

      assert {:error, {:duplicate_id, "p-b", "replace-block"}} =
               Patch.apply_patch(two_sections(), op)
    end

    test "a copy in a hidden alias is not walked, so the repeat is refused" do
      blocks = [paragraph("p-a", "A.")]

      block = %{
        "id" => "exp",
        "type" => "expandable",
        "children" => [paragraph("p-h", "Visible.")],
        "blocks" => [paragraph("p-h", "Hidden.")]
      }

      assert {:error, {:duplicate_id, "p-h", "append-block"}} =
               Patch.apply_patch(blocks, %{"op" => "append-block", "block" => block})
    end
  end
end
