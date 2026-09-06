defmodule Barkpark.Content.Papers.BlockFormReplayTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "production"
  @doc_type "block_form_replay_post"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Block form replay post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "layout" => [%{"kind" => "field", "name" => "title"}]
        },
        @dataset
      )

    :ok
  end

  test "paper form replay invokes its resolver once and preserves current block metadata" do
    slug = unique("paper-form")
    paper = seed_paper!(slug)
    request_id = Ecto.UUID.generate()
    parent = self()

    resolver = fn blocks ->
      send(parent, {:resolved, blocks})
      block = Enum.find(blocks, &(&1["id"] == "anchor"))

      {:ok,
       [
         %{
           "op" => "patch-block",
           "id" => block["id"],
           "patch" => %{"text" => "After"}
         }
       ]}
    end

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"block_id" => "anchor", "text" => "After"},
               @dataset,
               request_id,
               "user:form",
               resolver,
               if_rev: paper.content["rev"]
             )

    assert_receive {:resolved, blocks}
    assert Enum.find(blocks, &(&1["id"] == "anchor"))["server-meta"] == %{"keep" => true}

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"block_id" => "anchor", "text" => "After"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("resolver ran during replay") end,
               if_rev: paper.content["rev"]
             )

    refute_receive {:resolved, _}

    assert Enum.find(Content.paper_blocks(slug), &(&1["id"] == "anchor"))["server-meta"] ==
             %{"keep" => true}
  end

  test "form source and canonical ops cannot reuse the same paper request identity" do
    slug = unique("paper-form-canonical")
    paper = seed_paper!(slug)
    request_id = Ecto.UUID.generate()

    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch("Canonical")],
               @dataset,
               request_id,
               "user:form",
               if_rev: paper.content["rev"]
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "Form"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("cross-protocol mismatch must not resolve") end,
               if_rev: paper.content["rev"]
             )
  end

  test "paper source mismatch fails closed and stale or invalid resolution writes nothing" do
    slug = unique("paper-form-refusal")
    paper = seed_paper!(slug)
    before = paper.content
    request_id = Ecto.UUID.generate()

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "stale"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("stale resolver must not run") end,
               if_rev: paper.content["rev"] - 1
             )

    assert Content.get_paper(slug).content == before

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "unfenced"},
               @dataset,
               Ecto.UUID.generate(),
               "user:form",
               fn _ -> flunk("unfenced resolver must not run") end
             )

    assert {:error, {:source_validation, :bad_fields}} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "bad"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> {:error, {:source_validation, :bad_fields}} end,
               if_rev: paper.content["rev"]
             )

    assert Content.get_paper(slug).content == before

    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "good"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> {:ok, [patch("Good")]} end,
               if_rev: paper.content["rev"]
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"text" => "different"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("mismatch resolver must not run") end,
               if_rev: paper.content["rev"]
             )
  end

  test "document form replay resolves authoritative blocks once and keeps the opaque fence" do
    id = unique("document-form")

    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Before"}, @dataset)

    title = Enum.find(doc.content["blocks"], &(&1["fieldName"] == "title"))
    request_id = Ecto.UUID.generate()
    parent = self()

    resolver = fn blocks ->
      send(parent, {:document_resolved, blocks})
      current = Enum.find(blocks, &(&1["id"] == title["id"]))
      {:ok, %{"op" => "patch-block", "id" => current["id"], "patch" => %{"value" => "After"}}}
    end

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => title["id"], "value" => "After"},
               @dataset,
               request_id,
               "user:form",
               resolver,
               if_rev: doc.rev
             )

    assert_receive {:document_resolved, resolved}
    assert Enum.find(resolved, &(&1["id"] == title["id"])) == title

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => title["id"], "value" => "After"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("resolver ran during replay") end,
               if_rev: doc.rev
             )

    {:ok, saved} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert saved.content["title"] == "After"
  end

  test "document stale fence and malformed resolver result roll back without claiming" do
    id = unique("document-form-refusal")

    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Before"}, @dataset)

    before = doc.content
    request_id = Ecto.UUID.generate()

    assert {:error, {:rev_mismatch, %{expected: "stale", actual: actual}}} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"value" => "stale"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> flunk("stale resolver must not run") end,
               if_rev: "stale"
             )

    assert actual == doc.rev

    assert {:error, {:rev_mismatch, %{expected: nil, actual: ^actual}}} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"value" => "unfenced"},
               @dataset,
               Ecto.UUID.generate(),
               "user:form",
               fn _ -> flunk("unfenced resolver must not run") end
             )

    assert {:error, {:block_not_found, "missing", "patch-block"}} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"value" => "missing"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> {:error, {:block_not_found, "missing", "patch-block"}} end,
               if_rev: doc.rev
             )

    assert {:error, :invalid_block_form_resolution} =
             Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"value" => "bad"},
               @dataset,
               request_id,
               "user:form",
               fn _ -> {:ok, []} end,
               if_rev: doc.rev
             )

    {:ok, unchanged} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert unchanged.rev == doc.rev
    assert unchanged.content == before
  end

  defp seed_paper!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [
            %{
              "id" => "anchor",
              "type" => "paragraph",
              "text" => "Before",
              "server-meta" => %{"keep" => true}
            }
          ],
          style: "article"
        })
      )

    paper
  end

  defp patch(text),
    do: %{"op" => "patch-block", "id" => "anchor", "patch" => %{"text" => text}}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
