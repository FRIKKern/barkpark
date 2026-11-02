defmodule Barkpark.Content.Papers.BatchDuplicateIdsTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Content

  @dataset "production"
  @lv "lv:canvas"
  @other "lv:other"

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

  defp canvas(slug, ops, writer \\ @lv), do: write(slug, ops, remint_writer: writer)

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

  test "a nested Enter from a client without a canvas session saves with a fresh id and leaves no ledger" do
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

    refute Map.has_key?(Content.get_paper(slug).content, "id_remints")
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
      canvas(slug, [
        replace(
          "s-day",
          section("s-day", [
            paragraph("p-day", "Left the car park at six."),
            paragraph("p-day", "Fog by eight.")
          ])
        )
      ])

    assert %{"p-day" => %{"fresh" => ["s-day-1"]}} = Content.get_paper(slug).content["id_remints"]

    assert {:ok, %{block_ids: ["s-day-1"]}} =
             canvas(slug, [type("p-day", "Fog by eight. Clear.")])

    assert {:ok, %{block_ids: ["p-day"]}} =
             canvas(slug, [type("p-day", "Left the car park at six sharp.")])

    assert {:ok, _} = canvas(slug, [type("s-day-1", "Fog by eight. Clear!")])
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
               canvas(slug, [
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
                   canvas(slug, [
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
          assert {:ok, _} = canvas(slug, [%{"op" => "remove-block", "id" => "p-dup"}])
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

  describe "an old editor after its nested Enter" do
    setup do
      %{
        slug:
          seed!([
            section("s-day", [paragraph("p-day", "Left the car park at six.")]),
            paragraph("p-after", "Home.")
          ])
      }
    end

    defp enter(slug, first, second) do
      {:ok, _} =
        canvas(slug, [
          replace(
            "s-day",
            section("s-day", [paragraph("p-day", first), paragraph("p-day", second)])
          )
        ])
    end

    defp day_blocks(slug), do: slug |> Content.paper_blocks() |> hd() |> Map.fetch!("blocks")

    test "another window typing in the fresh line: the old editor's next patch overwrites no line",
         %{slug: slug} do
      enter(slug, "Left the car park at six.", "Fog by eight.")
      assert {:ok, _} = canvas(slug, [type("s-day-1", "Fog by eight. Window B.")], @other)

      capture_log(fn ->
        assert {:ok, %{block_ids: ["p-day-1"]}} =
                 canvas(slug, [type("p-day", "Fog by eight. Clear.")])
      end)

      assert {:ok, %{block_ids: ["p-day-1"]}} =
               canvas(slug, [type("p-day", "Fog by eight. Clear. More.")])

      assert day_blocks(slug) == [
               paragraph("p-day", "Left the car park at six."),
               paragraph("s-day-1", "Fog by eight. Window B."),
               paragraph("p-day-1", "Fog by eight. Clear. More.")
             ]
    end

    test "Enter at the end of a line, then typing in the first line over several batches",
         %{slug: slug} do
      enter(slug, "Left the car park at six.", "")

      for suffix <- [" A", " Ab", " Abc", " Abcd"] do
        assert {:ok, %{block_ids: ["p-day"]}} =
                 canvas(slug, [type("p-day", "Left the car park at six." <> suffix)])
      end

      assert day_blocks(slug) == [
               paragraph("p-day", "Left the car park at six. Abcd"),
               paragraph("s-day-1", "")
             ]
    end

    test "Enter at the start of a line: typing on the moved text goes to it", %{slug: slug} do
      enter(slug, "", "Left the car park at six.")

      for suffix <- [" A", " Ab"] do
        assert {:ok, %{block_ids: ["s-day-1"]}} =
                 canvas(slug, [type("p-day", "Left the car park at six." <> suffix)])
      end

      assert day_blocks(slug) == [
               paragraph("p-day", ""),
               paragraph("s-day-1", "Left the car park at six. Ab")
             ]
    end

    test "a client without a canvas session writes as it always did", %{slug: slug} do
      enter(slug, "Left the car park at six.", "Fog by eight.")

      assert {:ok, %{block_ids: ["p-day"], op_count: 1}} =
               write(slug, [type("p-day", "We left at dawn.")])

      assert {:ok, %{op_count: 1}} = write(slug, [%{"op" => "remove-block", "id" => "p-day"}])
      assert day_blocks(slug) == [paragraph("s-day-1", "Fog by eight.")]
    end

    test "a skipped remove is not counted as applied", %{slug: slug} do
      enter(slug, "Left the car park at six.", "Fog by eight.")

      capture_log(fn ->
        assert {:ok, %{op_count: 1, block_ids: ["p-after"]}} =
                 canvas(slug, [
                   %{"op" => "remove-block", "id" => "p-day"},
                   type("p-after", "Home!")
                 ])
      end)

      assert ids(Content.paper_blocks(slug)) == ["s-day", "p-day", "s-day-1", "p-after"]
    end

    test "another window deletes the kept line: the old editor's typing goes to the line left",
         %{slug: slug} do
      enter(slug, "Left the car park at six.", "Fog by eight.")

      assert {:ok, _} =
               canvas(
                 slug,
                 [replace("s-day", section("s-day", [paragraph("s-day-1", "Fog by eight.")]))],
                 @other
               )

      assert {:ok, %{block_ids: ["s-day-1"]}} =
               canvas(slug, [type("p-day", "Fog by eight. More.")])

      assert day_blocks(slug) == [paragraph("s-day-1", "Fog by eight. More.")]
    end

    test "each routed write restarts the 24 hours", %{slug: slug} do
      enter(slug, "Left the car park at six.", "Fog by eight.")
      doc = Content.get_paper(slug)
      old = System.os_time(:second) - 86_000
      aged = put_in(doc.content, ["id_remints", "p-day", "at"], old)

      Barkpark.Repo.update_all(
        from(d in Barkpark.Content.Document, where: d.id == ^doc.id),
        set: [content: aged]
      )

      assert {:ok, _} = canvas(slug, [type("p-day", "Fog by eight. Clear.")])
      assert Content.get_paper(slug).content["id_remints"]["p-day"]["at"] > old
    end

    test "ops in one batch are judged against the blocks the batch has written so far", %{
      slug: slug
    } do
      enter(slug, "Left.", "Fog.")

      assert {:ok, _} = canvas(slug, [type("p-day", "Left. Rain."), type("p-day", "Lft. Rain.")])
      assert day_blocks(slug) == [paragraph("p-day", "Lft. Rain."), paragraph("s-day-1", "Fog.")]
    end
  end

  describe "an old editor's Enter inside a container row" do
    for {kind, field, row} <- [
          {"steps", "steps", %{"id" => "r-1", "title" => "One"}},
          {"tabs", "tabs", %{"id" => "r-1", "label" => "One"}}
        ] do
      @kind kind
      @field field
      @row row

      test "#{kind}: the patch carrying the repeat saves, resent it keeps the same ids, and typing finds its line" do
        holder = fn children ->
          %{
            "id" => "box",
            "type" => @kind,
            @field => [Map.put(@row, "blocks", children)]
          }
        end

        slug =
          seed!([holder.([paragraph("p-s", "Pack the tent.")]), paragraph("p-after", "Home.")])

        split = %{
          "op" => "patch-block",
          "id" => "box",
          "patch" => %{
            @field => [
              Map.put(@row, "blocks", [
                paragraph("p-s", "Pack the tent."),
                paragraph("p-s", "Boots.")
              ])
            ]
          }
        }

        stored =
          holder.([paragraph("p-s", "Pack the tent."), paragraph("r-1-1", "Boots.")])

        assert {:ok, _} = canvas(slug, [split])
        assert hd(Content.paper_blocks(slug)) == stored
        assert {:ok, _} = canvas(slug, [split])
        assert hd(Content.paper_blocks(slug)) == stored

        assert {:ok, %{block_ids: ["r-1-1"]}} = canvas(slug, [type("p-s", "Boots. Laces.")])

        assert hd(Content.paper_blocks(slug)) ==
                 holder.([
                   paragraph("p-s", "Pack the tent."),
                   paragraph("r-1-1", "Boots. Laces.")
                 ])
      end
    end
  end

  test "a heal routes every canvas editor; a client without one patches the first copy as before" do
    slug =
      seed!([
        paragraph("p-dup", "Top copy."),
        section("s-1", [paragraph("p-dup", "Nested copy.")])
      ])

    assert {:ok, %{block_ids: ["s-1-0"]}} =
             canvas(slug, [type("p-dup", "Nested copy. More.")], @other)

    assert {:ok, %{block_ids: ["p-dup"]}} = write(slug, [type("p-dup", "Nested copy. Again.")])

    assert Content.paper_blocks(slug) == [
             paragraph("p-dup", "Nested copy. Again."),
             section("s-1", [paragraph("s-1-0", "Nested copy. More.")])
           ]
  end
end
