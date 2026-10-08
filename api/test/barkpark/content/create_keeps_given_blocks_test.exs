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

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kicker", "title" => "Kicker", "type" => "string"}
          ]
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

  # task-b43256e0d9d90733: a flat-shape mutate create stored the blocks only; the
  # bound fields, body and preview waited for the first patch.
  for type <- ["story", "note"] do
    test "a mutate createOrReplace on #{type} projects its blocks into the fields" do
      id = "#{unquote(type)}-#{System.unique_integer([:positive])}"

      blocks = [
        %{"id" => "f-kicker", "type" => "field-string", "fieldName" => "kicker", "value" => "K"},
        para("p-1", "Body text.")
      ]

      {:ok, _} =
        Barkpark.Content.Mutations.apply_mutations(
          [
            %{
              "createOrReplace" => %{
                "_id" => id,
                "_type" => unquote(type),
                "title" => "T",
                "blocks" => blocks
              }
            }
          ],
          @dataset
        )

      {:ok, doc} = Content.get_document("drafts." <> id, unquote(type), @dataset)

      assert doc.content["kicker"] == "K"
      assert doc.content["body"]["blocks"] |> Enum.map(& &1["id"]) == ["p-1"]
      assert is_map(doc.content["preview"])
    end
  end

  # A create that sends its own rendered body beside blocks keeps that body:
  # Sanity-shaped blocks render to nothing, and the text was lost at birth.
  test "a create keeps a body it sends, and still projects the bound fields" do
    body = %{"blocks" => [para("b-1", "Kept.")], "html" => "<p>Kept.</p>"}

    blocks = [
      %{"id" => "f-kicker", "type" => "field-string", "fieldName" => "kicker", "value" => "K"},
      %{"_type" => "block", "_key" => "s1", "children" => [%{"_type" => "span", "text" => "x"}]}
    ]

    for type <- ["story", "note"] do
      attrs = %{
        "doc_id" => "#{type}-#{System.unique_integer([:positive])}",
        "title" => "T",
        "content" => %{"blocks" => blocks, "body" => body}
      }

      {:ok, doc} = Content.create_document(type, attrs, @dataset)
      assert doc.content["body"] == body, type
      assert doc.content["kicker"] == "K", type
    end
  end
end
