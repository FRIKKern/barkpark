defmodule Barkpark.Content.Papers.BatchDuplicateIdsTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

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

  test "an old client's nested Enter saves; the second copy gets a fresh id the echo carries" do
    slug =
      seed!([
        section("s-day", [paragraph("p-day", "Left the car park at six.")]),
        paragraph("p-after", "Home.")
      ])

    assert {:ok, %{block_ids: ["s-day"]}} =
             write(slug, [
               replace(
                 "s-day",
                 section("s-day", [
                   paragraph("p-day", "Left the car park at six."),
                   paragraph("p-day", "Fog by eight.")
                 ])
               )
             ])

    assert Content.paper_blocks(slug) == [
             section("s-day", [
               paragraph("p-day", "Left the car park at six."),
               paragraph("s-day-1", "Fog by eight.")
             ]),
             paragraph("p-after", "Home.")
           ]
  end

  test "inside a canvas run, the fresh id avoids ids outside the run" do
    slug =
      seed!([
        section("s-day", [paragraph("p-day", "Left the car park at six.")]),
        paragraph("s-day-1", "Elsewhere.")
      ])

    assert {:ok, _} =
             write(
               slug,
               [
                 replace(
                   "s-day",
                   section("s-day", [
                     paragraph("p-day", "Left the car park at six."),
                     paragraph("p-day", "Fog by eight.")
                   ])
                 )
               ],
               canvas_run_context: %{container_kind: "document", container_run_ids: ["s-day"]}
             )

    assert ids(Content.paper_blocks(slug)) == ["s-day", "p-day", "s-day-1-1", "s-day-1"]
  end

  test "an old client typing on after its nested Enter: each patch on the kept id finds its copy until it names the fresh id" do
    slug =
      seed!([
        section("s-day", [paragraph("p-day", "Left the car park at six.")]),
        paragraph("p-after", "Home.")
      ])

    {:ok, _} =
      write(slug, [
        replace(
          "s-day",
          section("s-day", [
            paragraph("p-day", "Left the car park at six."),
            paragraph("p-day", "Fog by eight.")
          ])
        )
      ])

    assert %{"p-day" => %{"fresh" => ["s-day-1"]}} = Content.get_paper(slug).content["id_remints"]

    assert {:ok, %{block_ids: ["s-day-1"]}} = write(slug, [type("p-day", "Fog by eight. Clear.")])

    assert {:ok, %{block_ids: ["p-day"]}} =
             write(slug, [type("p-day", "Left the car park at six sharp.")])

    assert {:ok, _} = write(slug, [type("s-day-1", "Fog by eight. Clear!")])
    refute Map.has_key?(Content.get_paper(slug).content, "id_remints")

    assert Content.paper_blocks(slug) == [
             section("s-day", [
               paragraph("p-day", "Left the car park at six sharp."),
               paragraph("s-day-1", "Fog by eight. Clear!")
             ]),
             paragraph("p-after", "Home.")
           ]
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

    test "a second writer that adds an id the first already placed is refused, not re-minted", %{
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

  test "a Paper row with no content still takes a batch, and stores no ledger" do
    slug = seed!([paragraph("p-old", "Old.")])

    Barkpark.Repo.update_all(
      from(d in Barkpark.Content.Document, where: d.doc_id == ^slug and d.type == "paper"),
      set: [content: nil]
    )

    assert {:ok, _} =
             Content.apply_paper_block_ops(
               slug,
               [%{"op" => "append-block", "block" => paragraph("p-a", "Alpha.")}],
               @dataset
             )

    assert Content.paper_blocks(slug) == [paragraph("p-a", "Alpha.")]
    refute Map.has_key?(Content.get_paper(slug).content, "id_remints")
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

    test "an unrelated batch applies and heals it: the first copy keeps the id", %{slug: slug} do
      assert {:ok, %{block_ids: ["s-1-0", "p-b"]}} =
               write(slug, [
                 %{
                   "op" => "patch-block",
                   "id" => "p-b",
                   "patch" => %{"content" => [%{"type" => "text", "value" => "Beta!"}]}
                 }
               ])

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top copy."),
               section("s-1", [paragraph("s-1-0", "Nested copy."), paragraph("p-a", "Alpha.")]),
               paragraph("p-b", "Beta!")
             ]
    end

    test "an old client's patch on the repeated id goes to the copy its text continues", %{
      slug: slug
    } do
      assert {:ok, %{block_ids: ["s-1-0"]}} =
               write(slug, [
                 %{
                   "op" => "patch-block",
                   "id" => "p-dup",
                   "patch" => %{
                     "content" => [%{"type" => "text", "value" => "Nested copy. More."}]
                   }
                 }
               ])

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top copy."),
               section("s-1", [
                 paragraph("s-1-0", "Nested copy. More."),
                 paragraph("p-a", "Alpha.")
               ]),
               paragraph("p-b", "Beta.")
             ]

      assert %{"p-dup" => %{"fresh" => ["s-1-0"]}} = Content.get_paper(slug).content["id_remints"]
    end

    test "a patch on the repeated id that continues neither copy lands as a new block", %{
      slug: slug
    } do
      log =
        capture_log(fn ->
          assert {:ok, _} =
                   write(slug, [
                     %{
                       "op" => "patch-block",
                       "id" => "p-dup",
                       "patch" => %{"content" => [%{"type" => "text", "value" => "Third."}]}
                     }
                   ])
        end)

      assert log =~ ~s(patch-block on repeated id "p-dup")
      refute log =~ "Third."

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top copy."),
               paragraph("p-dup-1", "Third."),
               section("s-1", [paragraph("s-1-0", "Nested copy."), paragraph("p-a", "Alpha.")]),
               paragraph("p-b", "Beta.")
             ]
    end

    test "a remove on the repeated id removes neither copy", %{slug: slug} do
      log =
        capture_log(fn ->
          assert {:ok, _} = write(slug, [%{"op" => "remove-block", "id" => "p-dup"}])
        end)

      assert log =~ ~s(remove-block on repeated id "p-dup")

      assert Content.paper_blocks(slug) == [
               paragraph("p-dup", "Top copy."),
               section("s-1", [paragraph("s-1-0", "Nested copy."), paragraph("p-a", "Alpha.")]),
               paragraph("p-b", "Beta.")
             ]
    end

    test "without a revision fence the batch keeps today's path: no heal", %{slug: slug} do
      assert {:ok, _} =
               Content.apply_paper_block_ops(
                 slug,
                 [%{"op" => "patch-block", "id" => "p-b", "patch" => %{"content" => []}}],
                 @dataset
               )

      assert ids(Content.paper_blocks(slug)) == ["p-dup", "s-1", "p-dup", "p-a", "p-b"]
    end
  end
end
