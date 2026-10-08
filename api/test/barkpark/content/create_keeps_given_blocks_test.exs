defmodule Barkpark.Content.CreateKeepsGivenBlocksTest do
  @moduledoc """
  A create on a type with a layout that carries its own block list keeps those
  blocks, and the schema's prefill fills only the fields the create leaves empty
  (task-ca8ea94527d39fa0).

  Found seeding a story (layout title, kicker, summary, region body; prefill
  kicker "New story"): the given blocks were replaced by a synthesized scaffold,
  and the kicker the author set in a block came back as the prefill.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "story",
          "title" => "Stories",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kicker", "title" => "Kicker", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "text"},
            %{"name" => "dek", "title" => "Dek", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "kicker"},
            %{"kind" => "field", "name" => "summary"},
            %{"kind" => "field", "name" => "dek"},
            %{"kind" => "region", "name" => "body"}
          ],
          "prefill" => %{
            "kicker" => "New story",
            "summary" => "Prefilled",
            "dek" => "Prefilled dek"
          }
        },
        @dataset
      )

    :ok
  end

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  test "given blocks are kept, and prefill fills only the fields the create leaves empty" do
    blocks = [
      %{
        "id" => "f-title",
        "type" => "field-string",
        "fieldName" => "title",
        "value" => "A story"
      },
      para("p-1", "Between the title and the kicker."),
      %{
        "id" => "f-kicker",
        "type" => "field-string",
        "fieldName" => "kicker",
        "value" => "Freeform fixture"
      },
      para("p-2", "Body text.")
    ]

    attrs = %{
      "doc_id" => "story-#{System.unique_integer([:positive])}",
      "title" => "A story",
      "content" => %{"blocks" => blocks, "summary" => "Given summary"}
    }

    {:ok, doc} = Content.create_document("story", attrs, @dataset)

    assert Enum.map(doc.content["blocks"], & &1["id"]) == ["f-title", "p-1", "f-kicker", "p-2"]
    # Set by a block: the block's value, not the prefill.
    assert doc.content["kicker"] == "Freeform fixture"
    # Set by content: kept.
    assert doc.content["summary"] == "Given summary"
    # Set by neither: the prefill.
    assert doc.content["dek"] == "Prefilled dek"
  end

  test "a create with no blocks still gets the scaffold" do
    attrs = %{"doc_id" => "story-#{System.unique_integer([:positive])}", "title" => "Bare"}

    {:ok, doc} = Content.create_document("story", attrs, @dataset)

    assert Enum.any?(doc.content["blocks"], &(&1["fieldName"] == "kicker"))
    assert doc.content["kicker"] == "New story"
  end
end
