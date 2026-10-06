defmodule Barkpark.Content.StaleRegionShadowTest do
  @moduledoc """
  A stored block list written before task-9f230ad6d5b50fb0 can bind a richText
  `body` twice: a field block for `body` AND the body region's free blocks.
  `resolve_blocks_for_edit/3` drops that field block and reports the list as
  synthesized, so the first op persists the repair (task-c60a40c9a0990c0d).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "production"

  defp schema!(name, body_type) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => name,
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "body", "type" => body_type}
          ]
        },
        @dataset
      )
  end

  defp doc!(type, blocks, body) do
    id = "#{type}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(type, %{"doc_id" => id, "title" => "T"}, @dataset)

    {:ok, doc} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T",
          "content" => %{"title" => "T", "body" => body, "blocks" => blocks}
        },
        @dataset
      )

    doc
  end

  @stale [
    %{"id" => "f-title", "type" => "field-string", "fieldName" => "title", "value" => "T"},
    %{"id" => "f-body", "type" => "field-text", "fieldName" => "body", "value" => "old string"},
    %{
      "id" => "p-1",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Region text"}]
    }
  ]

  test "a richText body drops its stale field block and reports the list as synthesized" do
    schema!("shadowrt", "richText")
    doc = doc!("shadowrt", @stale, %{"html" => "<p>Region text</p>"})

    assert {blocks, true} = Content.resolve_blocks_for_edit(doc, "shadowrt", @dataset)
    assert Enum.map(blocks, & &1["id"]) == ["f-title", "p-1"]
  end

  test "the first block op persists the repaired list, and content.body takes the region's text" do
    schema!("shadowop", "richText")
    doc = doc!("shadowop", @stale, %{"html" => "<p>Region text</p>"})

    op = %{
      "op" => "patch-block",
      "id" => "p-1",
      "patch" => %{"content" => [%{"type" => "text", "value" => "Edited"}]}
    }

    {:ok, _} = Content.apply_document_block_op(doc.doc_id, "shadowop", op, @dataset)
    {:ok, saved} = Content.get_document(doc.doc_id, "shadowop", @dataset)

    refute Enum.any?(saved.content["blocks"], &(&1["fieldName"] == "body"))
    refute saved.content["body"] == "old string"
    assert inspect(saved.content["body"]) =~ "Edited"
  end

  test "a text body keeps its field block (it owns content.body; no region)" do
    schema!("shadowtx", "text")
    doc = doc!("shadowtx", @stale, "old string")

    assert {blocks, false} = Content.resolve_blocks_for_edit(doc, "shadowtx", @dataset)
    assert Enum.map(blocks, & &1["id"]) == ["f-title", "f-body", "p-1"]
  end

  test "a list with no shadow is returned verbatim" do
    schema!("shadowno", "richText")
    clean = Enum.reject(@stale, &(&1["id"] == "f-body"))
    doc = doc!("shadowno", clean, %{"html" => "<p>Region text</p>"})

    assert {^clean, false} = Content.resolve_blocks_for_edit(doc, "shadowno", @dataset)
  end
end
