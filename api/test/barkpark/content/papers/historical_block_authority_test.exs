defmodule Barkpark.Content.Papers.HistoricalBlockAuthorityTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @doc_type "historical_block_authority"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Historical block authority",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    :ok
  end

  test "present malformed authorities refuse Beta resolution and revision-fenced writes" do
    valid_nested = [paragraph("nested", "Nested must not become fallback authority")]

    for {label, content, path} <- [
          {"top-map", %{"blocks" => %{"invalid" => true}, "body" => %{"blocks" => valid_nested}},
           "blocks"},
          {"top-scalar-list", %{"blocks" => ["invalid"], "body" => %{"blocks" => valid_nested}},
           "blocks"},
          {"nested-scalar-list", %{"body" => %{"blocks" => ["invalid"], "keep" => true}},
           "body.blocks"},
          {"bare-scalar-list", %{"body" => ["invalid"]}, "body"},
          {"body-map", %{"body" => %{"html" => "<p>Classic wrapper</p>", "keep" => true}},
           "body"},
          {"body-number", %{"body" => 42}, "body"}
        ] do
      doc = inject_content!(label, content)
      before = stored_document(doc.doc_id)

      assert Content.resolve_blocks_for_edit(before, @doc_type, @dataset) ==
               {:error, {:malformed_block_authority, path}}

      assert Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{
                 "op" => "append-block",
                 "block" => paragraph("forged", "Must not replace malformed authority")
               },
               @dataset,
               if_rev: before.rev
             ) == {:error, {:malformed_block_authority, path}}

      assert Content.apply_document_block_form_once(
               doc.doc_id,
               @doc_type,
               "block_form:v1",
               %{"block_id" => "nested", "title" => "Must not write"},
               @dataset,
               Ecto.UUID.generate(),
               "user:malformed-authority",
               fn _blocks ->
                 flunk("malformed authority must be rejected before form resolution")
               end,
               if_rev: before.rev
             ) == {:error, {:malformed_block_authority, path}}

      assert stored_document(doc.doc_id) == before
    end
  end

  test "valid top-level and historical authorities preserve precedence" do
    nested = [paragraph("nested", "Nested")]
    top = [paragraph("top", "Top")]

    for {label, content, expected} <- [
          {"top-empty", %{"blocks" => [], "body" => %{"blocks" => nested}}, []},
          {"top-list", %{"blocks" => top, "body" => %{"blocks" => nested}}, top},
          {"nested-list", %{"body" => %{"blocks" => nested, "keep" => true}}, nested},
          {"bare-list", %{"body" => nested}, nested}
        ] do
      doc = inject_content!(label, content)

      assert Content.resolve_blocks_for_edit(stored_document(doc.doc_id), @doc_type, @dataset) ==
               {expected, false}
    end
  end

  defp inject_content!(label, content) do
    id = "#{label}-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_document(
        @doc_type,
        %{"doc_id" => id, "title" => label, "content" => %{}},
        @dataset
      )

    {1, _} =
      Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: content])

    stored_document(doc.doc_id)
  end

  defp stored_document(id) do
    {:ok, doc} = Content.get_document(id, @doc_type, @dataset)
    doc
  end

  defp paragraph(id, text) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
  end
end
