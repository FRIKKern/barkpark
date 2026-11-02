defmodule Barkpark.Content.Papers.BatchDuplicateIdsTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "production"

  defp paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp section(id, children),
    do: %{"id" => id, "type" => "section", "title" => id, "blocks" => children}

  defp seed!(blocks) do
    slug = "batch-dup-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

    slug
  end

  defp rev(slug), do: get_in(Content.get_paper(slug).content, ["rev"])

  defp write(slug, ops, opts \\ []),
    do: Content.apply_paper_block_ops(slug, ops, @dataset, [if_rev: rev(slug)] ++ opts)

  defp write_at(slug, ops, rev),
    do: Content.apply_paper_block_ops(slug, ops, @dataset, if_rev: rev)

  defp type(id, text),
    do: %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }

  defp move_up,
    do: [
      replace(
        "s-1",
        section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
      ),
      replace("s-2", section("s-2", [paragraph("p-b", "Beta.")]))
    ]

  defp replace(id, block), do: %{"op" => "replace-block", "id" => id, "block" => block}

  defp ids(blocks) do
    Enum.flat_map(blocks, fn block -> [block["id"] | ids(Map.get(block, "blocks", []))] end)
  end

  describe "a move between sections" do
    setup do
      %{
        up:
          seed!([
            section("s-1", [paragraph("p-a", "Alpha.")]),
            section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
          ])
      }
    end

    test "up into section 1 lands, then typing into the moved paragraph saves", %{up: slug} do
      assert {:ok, %{block_ids: ["s-1", "s-2"]}} =
               write(slug, [
                 replace(
                   "s-1",
                   section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
                 ),
                 replace("s-2", section("s-2", [paragraph("p-b", "Beta.")]))
               ])

      assert {:ok, _} =
               write(slug, [
                 %{
                   "op" => "patch-block",
                   "id" => "p-x",
                   "patch" => %{"content" => [%{"type" => "text", "value" => "Original X. more"}]}
                 }
               ])

      assert Content.paper_blocks(slug) == [
               section("s-1", [paragraph("p-x", "Original X. more"), paragraph("p-a", "Alpha.")]),
               section("s-2", [paragraph("p-b", "Beta.")])
             ]
    end

    test "the same move inside a document canvas run lands", %{up: slug} do
      context = %{container_kind: "document", container_run_ids: ["s-1", "s-2"]}

      assert {:ok, _} =
               write(
                 slug,
                 [
                   replace(
                     "s-1",
                     section("s-1", [paragraph("p-x", "Original X."), paragraph("p-a", "Alpha.")])
                   ),
                   replace("s-2", section("s-2", [paragraph("p-b", "Beta.")]))
                 ],
                 canvas_run_context: context
               )

      assert ids(Content.paper_blocks(slug)) == ["s-1", "p-x", "p-a", "s-2", "p-b"]
    end

    test "the same move through the generic document batch lands; a copy left in both is refused",
         %{up: slug} do
      assert {:error, {:duplicate_id, "p-x", "replace-block"}} =
               Content.apply_document_block_ops(slug, "paper", [hd(move_up())], @dataset)

      assert {:ok, %{written_doc_id: written}} =
               Content.apply_document_block_ops(slug, "paper", move_up(), @dataset)

      {:ok, doc} = Content.get_document(written, "paper", @dataset)
      assert ids(doc.content["blocks"]) == ["s-1", "p-x", "p-a", "s-2", "p-b"]
    end

    test "a batch that leaves the paragraph in both sections is refused and writes nothing", %{
      up: slug
    } do
      before = Content.get_paper(slug).content

      assert {:error, {:duplicate_id, "p-x", "replace-block"}} =
               write(slug, [
                 replace(
                   "s-1",
                   section("s-1", [paragraph("p-x", "Copy."), paragraph("p-a", "Alpha.")])
                 )
               ])

      assert Content.get_paper(slug).content == before
    end
  end

  describe "two writers on one revision" do
    setup do
      %{
        slug:
          seed!([
            section("s-1", [paragraph("p-a", "Alpha.")]),
            section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
          ])
      }
    end

    test "the second loses the fence, rebases, and its typing lands on the moved paragraph", %{
      slug: slug
    } do
      rev = rev(slug)
      assert {:ok, _} = write_at(slug, move_up(), rev)
      assert {:error, :precondition_failed} = write_at(slug, [type("p-x", "Original X. B")], rev)
      assert {:ok, _} = write(slug, [type("p-x", "Original X. B")])

      assert Content.paper_blocks(slug) == [
               section("s-1", [paragraph("p-x", "Original X. B"), paragraph("p-a", "Alpha.")]),
               section("s-2", [paragraph("p-b", "Beta.")])
             ]
    end

    test "a second writer that adds an id the first already placed is refused", %{
      slug: slug
    } do
      assert {:ok, _} =
               write(slug, [
                 %{"op" => "insert-after", "afterId" => "p-a", "block" => paragraph("p-z", "A.")}
               ])

      before = Content.get_paper(slug).content

      assert {:error, {:duplicate_id, "p-z", "insert-after"}} =
               write(slug, [
                 %{"op" => "insert-after", "afterId" => "p-b", "block" => paragraph("p-z", "B.")}
               ])

      assert Content.get_paper(slug).content == before
    end

    test "a delete that lands before the move: the move's replace puts the paragraph back once",
         %{slug: slug} do
      rev = rev(slug)
      assert {:ok, _} = write_at(slug, [%{"op" => "remove-block", "id" => "p-x"}], rev)
      assert {:error, :precondition_failed} = write_at(slug, move_up(), rev)
      assert {:ok, _} = write(slug, move_up())
      assert ids(Content.paper_blocks(slug)) == ["s-1", "p-x", "p-a", "s-2", "p-b"]
    end

    test "a delete that lands after the move removes the moved paragraph", %{slug: slug} do
      rev = rev(slug)
      assert {:ok, _} = write_at(slug, move_up(), rev)

      assert {:error, :precondition_failed} =
               write_at(slug, [%{"op" => "remove-block", "id" => "p-x"}], rev)

      assert {:ok, _} = write(slug, [%{"op" => "remove-block", "id" => "p-x"}])
      assert ids(Content.paper_blocks(slug)) == ["s-1", "p-a", "s-2", "p-b"]
    end

    test "unfenced, a delete between the two writes still leaves one copy", %{slug: slug} do
      assert {:ok, _} =
               Content.apply_paper_block_ops(
                 slug,
                 [%{"op" => "remove-block", "id" => "p-x"}],
                 @dataset
               )

      assert {:ok, _} = Content.apply_paper_block_ops(slug, move_up(), @dataset)
      assert ids(Content.paper_blocks(slug)) == ["s-1", "p-x", "p-a", "s-2", "p-b"]
    end
  end

  test "an old editor's nested Enter is refused and writes nothing" do
    slug = seed!([section("s-day", [paragraph("p-day", "Left the car park at six.")])])
    before = Content.get_paper(slug).content

    assert {:error, {:duplicate_id, "p-day", "replace-block"}} =
             write(slug, [
               replace(
                 "s-day",
                 section("s-day", [
                   paragraph("p-day", "Left the car park at six."),
                   paragraph("p-day", "Fog by eight.")
                 ])
               )
             ])

    assert Content.get_paper(slug).content == before
  end

  describe "an op naming an id the batch has made repeated" do
    setup do
      %{
        down:
          seed!([
            section("s-1", [paragraph("p-a", "Alpha."), paragraph("p-x", "Original X.")]),
            section("s-2", [paragraph("p-b", "Beta.")])
          ]),
        up:
          seed!([
            section("s-1", [paragraph("p-a", "Alpha.")]),
            section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
          ])
      }
    end

    test "an edit between a move's two replaces is refused, fenced or not, and writes nothing", %{
      down: slug
    } do
      before = Content.get_paper(slug).content

      ops = [
        replace(
          "s-2",
          section("s-2", [paragraph("p-b", "Beta."), paragraph("p-x", "Original X.")])
        ),
        type("p-x", "Original X. Edited."),
        replace("s-1", section("s-1", [paragraph("p-a", "Alpha.")]))
      ]

      assert {:error, {:duplicate_id, "p-x", "patch-block"}} = write(slug, ops)

      assert {:error, {:duplicate_id, "p-x", "patch-block"}} =
               Content.apply_paper_block_ops(slug, ops, @dataset)

      assert Content.get_paper(slug).content == before
    end

    test "a remove of the old copy after a move up is refused", %{up: slug} do
      ops = [
        replace(
          "s-1",
          section("s-1", [
            paragraph("p-x", "Original X. Moved and edited."),
            paragraph("p-a", "Alpha.")
          ])
        ),
        %{"op" => "remove-block", "id" => "p-x"}
      ]

      assert {:error, {:duplicate_id, "p-x", "remove-block"}} = write(slug, ops)

      assert {:error, {:duplicate_id, "p-x", "remove-block"}} =
               Content.apply_document_block_ops(slug, "paper", ops, @dataset)
    end
  end

  describe "a stored legacy duplicate" do
    setup do
      %{
        slug:
          seed!([
            paragraph("p-dup", "Top copy."),
            section("s-1", [paragraph("p-dup", "Nested copy."), paragraph("p-a", "Alpha.")]),
            paragraph("p-b", "Beta.")
          ])
      }
    end

    test "a fenced batch that does not touch it applies and leaves both copies", %{slug: slug} do
      assert {:ok, %{block_ids: ["p-b"]}} = write(slug, [type("p-b", "Beta!")])

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top copy."),
               section("s-1", [paragraph("p-dup", "Nested copy."), paragraph("p-a", "Alpha.")]),
               paragraph("p-b", "Beta!")
             ]
    end

    test "an edit of the repeated id goes to the first copy, fenced or not", %{slug: slug} do
      assert {:ok, _} = write(slug, [type("p-dup", "Top!")])
      assert {:ok, _} = Content.apply_paper_block_ops(slug, [type("p-dup", "Top!!")], @dataset)

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top!!"),
               section("s-1", [paragraph("p-dup", "Nested copy."), paragraph("p-a", "Alpha.")]),
               paragraph("p-b", "Beta.")
             ]
    end

    test "a third copy is refused", %{slug: slug} do
      assert {:error, {:duplicate_id, "p-dup", "insert-after"}} =
               write(slug, [
                 %{
                   "op" => "insert-after",
                   "afterId" => "p-b",
                   "block" => paragraph("p-dup", "Third.")
                 }
               ])
    end
  end
end
