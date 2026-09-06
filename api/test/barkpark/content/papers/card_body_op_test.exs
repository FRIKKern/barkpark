defmodule Barkpark.Content.Papers.CardBodyOpTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @doc_type "card_body_op_post"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Card body op post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "layout" => [%{"kind" => "field", "name" => "title"}]
        },
        @dataset
      )

    :ok
  end

  test "card body op merges content into authoritative chrome and paragraph metadata" do
    {slug, paper} = seed_card!()
    original = card_block(paper)

    assert {:ok, chrome_receipt, :applied} =
             apply_chrome_title(slug, paper.content["rev"], "New title")

    rich_body = [
      %{"type" => "strong", "children" => inline("New")},
      %{"type" => "text", "value" => " body"}
    ]

    assert {:ok, _body_receipt, :applied} =
             apply_body(slug, chrome_receipt.rev, rich_body)

    stored = Content.get_paper(slug) |> card_block()
    assert get_in(stored, ["slots", "title", Access.at(0), "text"]) == "New title"
    assert get_in(stored, ["slots", "body", Access.at(0), "content"]) == rich_body

    assert get_in(stored, ["slots", "body", Access.at(0), "paragraph-meta"]) ==
             %{"keep" => true}

    assert stored["slots"]["media"] == original["slots"]["media"]
    assert stored["slots"]["action"] == original["slots"]["action"]
    assert stored["slots"]["future"] == original["slots"]["future"]
    assert stored["card-meta"] == original["card-meta"]
  end

  test "chrome resolved after a body write preserves the accepted body" do
    {slug, paper} = seed_card!()

    assert {:ok, body_receipt, :applied} =
             apply_body(slug, paper.content["rev"], inline("Body first"))

    assert {:ok, _chrome_receipt, :applied} =
             apply_chrome_title(slug, body_receipt.rev, "Title second")

    stored = Content.get_paper(slug) |> card_block()
    assert get_in(stored, ["slots", "title", Access.at(0), "text"]) == "Title second"
    assert get_in(stored, ["slots", "body", Access.at(0), "content"]) == inline("Body first")
    assert get_in(stored, ["slots", "body", Access.at(0), "paragraph-meta"]) == %{"keep" => true}
  end

  test "card body op creates only the canonical body slot and exact retry is inert" do
    {slug, paper} = seed_card!(body: nil)
    request_id = Ecto.UUID.generate()
    op = body_op(inline("Created"))

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id,
               "user:card-body",
               if_rev: paper.content["rev"]
             )

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id,
               "user:card-body",
               if_rev: paper.content["rev"]
             )

    stored = Content.get_paper(slug) |> card_block()
    assert stored["slots"]["body"] == [%{"type" => "paragraph", "content" => inline("Created")}]
    assert stored["slots"]["future"] == %{"keep" => true}
  end

  test "malformed body ops and malformed current card slots fail closed" do
    {slug, paper} = seed_card!()
    before = paper.content

    for op <- [
          %{"op" => "patch-card-body", "id" => "card", "content" => %{}},
          %{"op" => "patch-card-body", "id" => "card", "content" => [%{}]},
          %{"op" => "patch-card-body", "id" => "card", "content" => ["scalar"]},
          %{
            "op" => "patch-card-body",
            "id" => "card",
            "content" => [%{"type" => "text", "value" => %{}, "unknown" => true}]
          },
          %{
            "op" => "patch-card-body",
            "id" => "card",
            "content" => [%{"type" => "strong", "children" => "opaque"}]
          },
          %{
            "op" => "patch-card-body",
            "id" => "card",
            "content" => [
              %{
                "type" => "strong",
                "children" => [
                  %{"type" => "text", "value" => "one"},
                  %{"type" => "text", "value" => "two"}
                ]
              }
            ]
          },
          %{"op" => "patch-card-body", "id" => "card", "content" => [], "extra" => true},
          %{"op" => "patch-card-body", "id" => "missing", "content" => []}
        ] do
      assert {:error, _reason} =
               Content.apply_paper_block_ops_once(
                 slug,
                 [op],
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:card-body",
                 if_rev: paper.content["rev"]
               )

      assert Content.get_paper(slug).content == before
    end

    {bad_slug, bad_paper} = seed_card!(slots: %{"body" => [%{"type" => "heading"}]})

    assert {:error, _reason} =
             Content.apply_paper_block_ops_once(
               bad_slug,
               [body_op(inline("Rejected"))],
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body",
               if_rev: bad_paper.content["rev"]
             )

    assert Content.get_paper(bad_slug).content == bad_paper.content

    {bad_tone_slug, bad_tone_paper} = seed_card!()
    [bad_tone_card] = bad_tone_paper.content["blocks"]

    bad_tone_content =
      Map.put(bad_tone_paper.content, "blocks", [Map.put(bad_tone_card, "tone", %{})])

    Repo.update_all(from(d in Document, where: d.id == ^bad_tone_paper.id),
      set: [content: bad_tone_content]
    )

    assert {:error, _reason} =
             Content.apply_paper_block_ops_once(
               bad_tone_slug,
               [body_op(inline("Rejected"))],
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body",
               if_rev: bad_tone_content["rev"]
             )

    assert Content.get_paper(bad_tone_slug).content == bad_tone_content

    unsupported =
      %{
        "body" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Keep", "unknown" => true}]
          }
        ]
      }

    {unknown_slug, unknown_paper} = seed_card!(slots: unsupported)

    assert {:error, _reason} =
             Content.apply_paper_block_ops_once(
               unknown_slug,
               [body_op(inline("Must not replace unknown source"))],
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body",
               if_rev: unknown_paper.content["rev"]
             )

    assert Content.get_paper(unknown_slug).content == unknown_paper.content
  end

  test "identified generic document ops lower Card body content against authoritative slots" do
    id = "card-body-doc-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Card"}, @dataset)

    {_slug, paper} = seed_card!()
    card = card_block(paper)
    legacy = %{"title" => "Card", "blocks" => [card]}
    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: legacy])
    {:ok, current} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    request_id = Ecto.UUID.generate()
    op = body_op(inline("Beta body"))

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               current.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:card-body",
               if_rev: current.rev
             )

    assert receipt.op_kind == "patch-card-body"

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               current.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:card-body",
               if_rev: current.rev
             )

    {:ok, stored} = Content.get_document(current.doc_id, @doc_type, @dataset)
    stored_card = card_block(stored)
    assert get_in(stored_card, ["slots", "body", Access.at(0), "content"]) == inline("Beta body")

    assert get_in(stored_card, ["slots", "body", Access.at(0), "paragraph-meta"]) ==
             %{"keep" => true}

    assert stored_card["slots"]["title"] == card["slots"]["title"]
    assert stored_card["slots"]["future"] == card["slots"]["future"]
  end

  test "card body ops require a revision fence on every paper mutation lane" do
    {slug, paper} = seed_card!()
    before = paper.content
    op = body_op(inline("Must be fenced"))

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_op(slug, op, @dataset)

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_ops(slug, [op], @dataset)

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body"
             )

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_op(
               slug,
               %{"op" => "patch-card-body", "id" => "card", "content" => %{}},
               @dataset,
               if_rev: paper.content["rev"] + 1
             )

    assert Content.get_paper(slug).content == before

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_ops(
               slug,
               [op],
               @dataset,
               canvas_run_context: %{
                 container_id: "card",
                 container_run_ids: ["card"]
               }
             )

    assert Content.get_paper(slug).content == before
  end

  test "card body ops require a revision fence on direct and exact-once document lanes" do
    {doc, card} = seed_card_document!()
    op = body_op(inline("Must be fenced"))

    assert {:error, :precondition_failed} =
             Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset)

    assert {:error, :precondition_failed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body"
             )

    assert {:error, {:rev_mismatch, %{actual: actual, expected: "stale-revision"}}} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{"op" => "patch-card-body", "id" => "card", "content" => %{}},
               @dataset,
               if_rev: "stale-revision"
             )

    assert actual == doc.rev

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert card_block(stored) == card
    assert stored.rev == doc.rev
  end

  test "nested card body routing preserves every ancestor and sibling field" do
    {_slug, source} = seed_card!()
    card = card_block(source)
    slug = "nested-card-body-op-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "section",
        "type" => "section",
        "layout" => "stack",
        "section-meta" => %{"keep" => true},
        "blocks" => [
          %{
            "id" => "columns",
            "type" => "columns",
            "columns-meta" => %{"keep" => true},
            "columns" => [
              [card, %{"id" => "sibling", "type" => "paragraph", "text" => "Keep"}],
              [%{"id" => "other-column", "type" => "paragraph", "text" => "Other"}]
            ]
          }
        ]
      }
    ]

    attrs = Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
    {:ok, paper} = Content.upsert_paper(attrs)

    assert {:ok, %{block_ids: ["card"]}, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [body_op(inline("Nested body"))],
               @dataset,
               Ecto.UUID.generate(),
               "user:card-body",
               if_rev: paper.content["rev"]
             )

    stored_blocks = Content.get_paper(slug).content["blocks"]
    [stored_section] = stored_blocks
    [stored_columns] = stored_section["blocks"]
    [[stored_card, stored_sibling], stored_other_column] = stored_columns["columns"]

    assert get_in(stored_card, ["slots", "body", Access.at(0), "content"]) ==
             inline("Nested body")

    assert Map.delete(stored_card, "slots") == Map.delete(card, "slots")
    assert Map.delete(stored_card["slots"], "body") == Map.delete(card["slots"], "body")
    assert stored_sibling == %{"id" => "sibling", "type" => "paragraph", "text" => "Keep"}

    assert stored_other_column == [
             %{"id" => "other-column", "type" => "paragraph", "text" => "Other"}
           ]

    assert Map.drop(stored_columns, ["columns"]) ==
             Map.drop(hd(blocks)["blocks"] |> hd(), ["columns"])

    assert Map.drop(stored_section, ["blocks"]) == Map.drop(hd(blocks), ["blocks"])
  end

  defp apply_body(slug, if_rev, content) do
    Content.apply_paper_block_ops_once(
      slug,
      [body_op(content)],
      @dataset,
      Ecto.UUID.generate(),
      "user:card-body",
      if_rev: if_rev
    )
  end

  defp apply_chrome_title(slug, if_rev, title) do
    Content.apply_paper_block_form_once(
      slug,
      "card-test:v1",
      %{"block_id" => "card", "card-title" => title},
      @dataset,
      Ecto.UUID.generate(),
      "user:card-chrome",
      fn blocks ->
        current = Enum.find(blocks, &(&1["id"] == "card"))
        slots = Map.fetch!(current, "slots")
        [heading] = Map.fetch!(slots, "title")

        {:ok,
         [
           %{
             "op" => "patch-block",
             "id" => "card",
             "patch" => %{
               "slots" => Map.put(slots, "title", [Map.put(heading, "text", title)])
             }
           }
         ]}
      end,
      if_rev: if_rev
    )
  end

  defp body_op(content),
    do: %{"op" => "patch-card-body", "id" => "card", "content" => content}

  defp seed_card!(opts \\ []) do
    slug = "card-body-op-#{System.unique_integer([:positive])}"

    slots =
      Keyword.get(opts, :slots) ||
        %{
          "title" => [%{"type" => "heading", "text" => "Old title", "level" => 3}],
          "body" => [
            %{
              "type" => "paragraph",
              "content" => inline("Old body"),
              "paragraph-meta" => %{"keep" => true}
            }
          ],
          "media" => [%{"type" => "image", "src" => "/old.png", "width" => 640}],
          "action" => [%{"type" => "action", "label" => "Read", "href" => "/read"}],
          "future" => %{"keep" => true}
        }

    slots =
      if Keyword.get(opts, :body, :present) == nil, do: Map.delete(slots, "body"), else: slots

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [
          %{
            "id" => "card",
            "type" => "card",
            "slots" => slots,
            "card-meta" => %{"keep" => true}
          }
        ]
      })

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp seed_card_document! do
    id = "card-body-doc-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Card"}, @dataset)

    {_slug, paper} = seed_card!()
    card = card_block(paper)
    legacy = %{"title" => "Card", "blocks" => [card]}
    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: legacy])
    {:ok, current} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    {current, card}
  end

  defp card_block(%{content: %{"blocks" => blocks}}), do: card_block(blocks)
  defp card_block(blocks), do: Enum.find(blocks, &(&1["id"] == "card"))
  defp inline(text), do: [%{"type" => "text", "value" => text}]
end
