defmodule Barkpark.Content.FieldBlockOpsUntouchedVocabularyTest do
  @moduledoc """
  task-bbd13e5a46240cc1 — P1: editors cannot save ANY change to a doc holding
  a seeded inline object outside the field's declared vocabulary.

  Repro (barkpark-studio, guerrilla 853c0464f): post-11's `description` field
  was seeded from Sanity and holds a `chip` inline inside one paragraph's
  prose. `FieldVocabulary.allowed_inline_types/1` only ever admits
  text/marks/annotations, so a block-op batch that never reads or writes that
  paragraph (e.g. append a new paragraph at the end) was refused 422
  `invalid_op` ("inline chip is not in this field's vocabulary") — because
  `FieldVocabulary.validate/2` was checking the field's WHOLE block list, not
  the blocks the batch actually touched.

  Fix: `Content.Papers.BlockOps.apply_field_block_ops/6` now checks only
  `Patch.touched_block_ids/1`'s set against the result (block_ops.ex,
  `touched_vocabulary_targets/2`) — an untouched block round-trips
  byte-identical regardless of what it holds; a batch that INSERTS or EDITS
  an out-of-vocabulary block is still refused exactly as before.

  Deliberately does NOT decide whether `chip` (or inline objects generally)
  should ever be IN a vocabulary — that is the owner question on
  task-85fee859cf3bfef6. This fixes "a batch can't touch field X at all",
  not "what inline X may contain".
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  # No "chip" in `marks` or `annotations` — the vocabulary this field
  # declares has no opinion on it at all (matches post-11's real schema:
  # text/marks/annotations only).
  @vocab %{
    "styles" => ["normal", "h2", "h3"],
    "marks" => ["strong", "em"],
    "annotations" => [%{"name" => "link"}]
  }

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "chipvocab-ws-#{suffix}", name: "CV #{suffix}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Description",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => @vocab
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, scope: scope}
  end

  # The chip-bearing paragraph, exactly as a seed/import would have written
  # it — an inline object type ("chip") this field's vocabulary never
  # declared, nested in the SAME `"content"` array a normal text run lives
  # in (the shape `FieldVocabulary.check_inline_list/2` walks).
  defp chip_paragraph(id) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [
        %{"type" => "text", "value" => "see "},
        %{"type" => "chip", "value" => "@alan"}
      ]
    }
  end

  defp plain_paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp create_seeded!(scope, blocks) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "post-#{System.unique_integer([:positive])}",
          "title" => "post-11",
          "description" => %{"blocks" => blocks, "html" => "<p>seeded</p>"}
        },
        @dataset,
        scope
      )

    doc
  end

  test "a batch that never touches the chip block applies, and the chip round-trips byte-identical",
       %{scope: scope} do
    chip = chip_paragraph("p-chip")
    doc = create_seeded!(scope, [plain_paragraph("p1", "intro"), chip])

    assert {:ok, %{blocks: new_blocks, written_doc_id: written}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "post",
               "description",
               [%{"op" => "append-block", "block" => plain_paragraph("p2", "outro")}],
               @dataset,
               scope
             )

    assert Enum.find(new_blocks, &(&1["id"] == "p-chip")) == chip

    {:ok, saved} = Content.get_document(written, "post", @dataset, scope)
    assert %{"blocks" => saved_blocks} = saved.content["description"]
    assert Enum.find(saved_blocks, &(&1["id"] == "p-chip")) == chip
    assert Enum.any?(saved_blocks, &(&1["id"] == "p2"))
  end

  test "patch-block on the chip block itself is still refused", %{scope: scope} do
    doc = create_seeded!(scope, [plain_paragraph("p1", "intro"), chip_paragraph("p-chip")])

    assert {:error, {:out_of_vocabulary, "inline chip" <> _}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "post",
               "description",
               [%{"op" => "patch-block", "id" => "p-chip", "patch" => %{"id" => "p-chip"}}],
               @dataset,
               scope
             )
  end

  test "insert-after a NEW block that itself carries a chip is still refused", %{scope: scope} do
    doc = create_seeded!(scope, [plain_paragraph("p1", "intro")])

    assert {:error, {:out_of_vocabulary, "inline chip" <> _}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "post",
               "description",
               [%{"op" => "insert-after", "afterId" => "p1", "block" => chip_paragraph("p-new")}],
               @dataset,
               scope
             )
  end

  test "moving the chip block (position only, content unchanged) is NOT refused", %{
    scope: scope
  } do
    chip = chip_paragraph("p-chip")
    doc = create_seeded!(scope, [plain_paragraph("p1", "a"), chip, plain_paragraph("p2", "b")])

    assert {:ok, %{blocks: new_blocks}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "post",
               "description",
               [%{"op" => "move-block", "id" => "p-chip", "after" => "p2"}],
               @dataset,
               scope
             )

    assert Enum.find(new_blocks, &(&1["id"] == "p-chip")) == chip
    assert Enum.map(new_blocks, & &1["id"]) == ["p1", "p2", "p-chip"]
  end

  test "a batch touching an UNRELATED chip-free block while the chip is present elsewhere still applies",
       %{scope: scope} do
    doc =
      create_seeded!(scope, [
        plain_paragraph("p1", "intro"),
        chip_paragraph("p-chip"),
        plain_paragraph("p3", "to be edited")
      ])

    assert {:ok, %{blocks: new_blocks}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "post",
               "description",
               [
                 %{
                   "op" => "patch-block",
                   "id" => "p3",
                   "patch" => %{"content" => [%{"type" => "text", "value" => "edited"}]}
                 }
               ],
               @dataset,
               scope
             )

    assert Enum.find(new_blocks, &(&1["id"] == "p-chip")) == chip_paragraph("p-chip")
    assert %{"content" => [%{"value" => "edited"}]} = Enum.find(new_blocks, &(&1["id"] == "p3"))
  end
end
