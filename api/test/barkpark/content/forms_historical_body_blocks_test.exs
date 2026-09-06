defmodule Barkpark.Content.FormsHistoricalBodyBlocksTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo

  @dataset "forms_historical_body_blocks_test"
  @doc_type "historical_body_post"

  setup do
    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Historical body post",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    %{schema: schema}
  end

  test "Classic reads and saves a historical body.blocks envelope without losing authored data",
       %{
         schema: schema
       } do
    blocks = [section_with_card()]

    body = %{
      "blocks" => blocks,
      "html" => "<p>stale derivative must not override authoritative blocks</p>",
      "renderer" => %{"version" => 7},
      "unknown" => ["preserve", %{"deep" => true}]
    }

    {:ok, base_doc} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => "historical-body-map",
          "title" => "Original",
          "content" => %{"body" => body, "outside" => %{"also" => "preserve"}}
        },
        @dataset
      )

    assert base_doc.content["body"] == body
    refute Map.has_key?(base_doc.content, "blocks")

    form = Content.doc_to_form(base_doc, schema)
    expected_html = Render.render_blocks(blocks, %{style: :article})

    assert form["body"] == expected_html
    assert is_binary(form["body"])

    {:ok, saved, _errors} =
      Content.upsert_draft(
        base_doc,
        @doc_type,
        schema,
        %{
          "title" => "Updated",
          "status" => "draft",
          "body" => "<p>Classic must not flatten the authoritative blocks.</p>"
        },
        @dataset
      )

    assert saved.title == "Updated"
    assert saved.content["outside"] == %{"also" => "preserve"}
    assert saved.content["body"]["blocks"] == blocks
    assert saved.content["body"]["html"] == expected_html
    assert saved.content["body"]["renderer"] == %{"version" => 7}
    assert saved.content["body"]["unknown"] == ["preserve", %{"deep" => true}]
    refute Map.has_key?(saved.content, "blocks")

    {:ok, reloaded} = Content.get_document(saved.doc_id, @doc_type, @dataset)
    assert reloaded.content == saved.content
    assert Content.doc_to_form(reloaded, schema)["body"] == expected_html
  end

  test "an opted-in blocks richText field remains structured" do
    value = %{"blocks" => [paragraph("field-child", "Structured field")], "future" => true}

    doc = %{
      title: "Structured",
      status: "draft",
      content: %{"description" => value}
    }

    schema = %{
      fields: [
        %{
          "name" => "description",
          "type" => "richText",
          "editor" => "blocks"
        }
      ]
    }

    assert Content.doc_to_form(doc, schema)["description"] == value
  end

  test "a bare historical body block list is rendered and retained", %{schema: schema} do
    blocks = [paragraph("bare-body", "Bare historical body")]

    {:ok, base_doc} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => "historical-body-list",
          "title" => "Bare",
          "content" => %{"body" => blocks}
        },
        @dataset
      )

    expected_html = Render.render_blocks(blocks, %{style: :article})
    assert Content.doc_to_form(base_doc, schema)["body"] == expected_html

    {:ok, saved, _errors} =
      Content.upsert_draft(
        base_doc,
        @doc_type,
        schema,
        %{"title" => "Bare updated", "body" => "replacement", "status" => "draft"},
        @dataset
      )

    assert saved.content["body"] == blocks
    refute Map.has_key?(saved.content, "blocks")
  end

  test "historical blocks still project changed bound field values", %{schema: body_schema} do
    schema = with_subtitle(body_schema)

    blocks = [
      %{
        "id" => "bound-subtitle",
        "type" => "field",
        "fieldName" => "subtitle",
        "value" => "Before",
        "future" => %{"keep" => true}
      },
      paragraph("free-body", "Free body")
    ]

    {:ok, base_doc} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => "historical-bound-field",
          "title" => "Bound",
          "content" => %{"body" => %{"blocks" => blocks, "unknown" => true}}
        },
        @dataset
      )

    {:ok, saved, _errors} =
      Content.upsert_draft(
        base_doc,
        @doc_type,
        schema,
        %{
          "title" => "Bound",
          "body" => Content.doc_to_form(base_doc, schema)["body"],
          "subtitle" => "After",
          "status" => "draft"
        },
        @dataset
      )

    assert saved.content["subtitle"] == "After"
    assert [saved_bound, saved_free] = saved.content["body"]["blocks"]
    assert saved_bound == %{hd(blocks) | "value" => "After"}
    assert saved_free == List.last(blocks)
    assert saved.content["body"]["unknown"] == true
  end

  test "top-level block authority never falls through to a differing historical body", %{
    schema: body_schema
  } do
    schema = with_subtitle(body_schema)
    nested = [paragraph("wrong-source", "Must not become authoritative")]

    {:ok, canonical} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => "top-level-empty-authority",
          "title" => "Canonical",
          "content" => %{
            "blocks" => [],
            "body" => %{"blocks" => nested, "html" => "<p>stale mirror</p>"}
          }
        },
        @dataset
      )

    # The writer immediately projects the authoritative empty top-level list.
    assert canonical.content["blocks"] == []
    assert canonical.content["body"]["blocks"] == []

    malformed_content = %{
      "blocks" => %{"not" => "a list"},
      "body" => %{
        "blocks" => nested,
        "html" => "<p>retained fallback display</p>",
        "unknown" => %{"keep" => true}
      },
      "subtitle" => "Before"
    }

    {:ok, malformed} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => "malformed-top-level-authority",
          "title" => "Malformed",
          "content" => malformed_content
        },
        @dataset
      )

    {:ok, saved, _errors} =
      Content.upsert_draft(
        malformed,
        @doc_type,
        schema,
        %{
          "title" => "Title still saves",
          "body" => "replacement",
          "blocks" => "must not replace authority",
          "subtitle" => "After",
          "status" => "draft"
        },
        @dataset
      )

    assert saved.title == "Title still saves"
    assert saved.content == %{malformed_content | "subtitle" => "After"}
  end

  test "a malformed historical body authority is preserved instead of flattened", %{
    schema: body_schema
  } do
    schema = with_subtitle(body_schema)

    content = %{
      "body" => %{
        "blocks" => %{"not" => "a list"},
        "html" => "<p>existing</p>",
        "unknown" => 42
      },
      "subtitle" => "Before"
    }

    {:ok, base_doc} =
      Content.upsert_document(
        @doc_type,
        %{"doc_id" => "malformed-historical-body", "title" => "Malformed", "content" => content},
        @dataset
      )

    {:ok, saved, _errors} =
      Content.upsert_draft(
        base_doc,
        @doc_type,
        schema,
        %{
          "title" => "Updated",
          "body" => "replacement",
          "subtitle" => "After",
          "status" => "draft"
        },
        @dataset
      )

    assert saved.title == "Updated"
    assert saved.content == %{content | "subtitle" => "After"}
  end

  test "historical block lists with scalar elements fail closed without crashing", %{
    schema: schema
  } do
    for {id, content} <- [
          {"malformed-map-elements",
           %{
             "body" => %{"blocks" => ["not-a-block"], "unknown" => true},
             "outside" => "keep"
           }},
          {"malformed-list-elements", %{"body" => ["not-a-block"], "outside" => "keep"}},
          {"malformed-top-elements",
           %{
             "blocks" => ["not-a-block"],
             "body" => %{"blocks" => [paragraph("nested-valid", "Do not fall through")]},
             "outside" => "keep"
           }}
        ] do
      {:ok, seeded} =
        Content.upsert_document(
          @doc_type,
          %{"doc_id" => id, "title" => "Malformed elements", "content" => %{}},
          @dataset
        )

      {1, _} =
        Repo.update_all(from(d in Document, where: d.id == ^seeded.id), set: [content: content])

      {:ok, base_doc} = Content.get_document(seeded.doc_id, @doc_type, @dataset)

      assert Content.doc_to_form(base_doc, schema)["body"] == ""

      assert {:error, {:malformed_blocks, _details}} =
               Content.upsert_draft(
                 base_doc,
                 @doc_type,
                 schema,
                 %{
                   "title" => "Title remains editable",
                   "body" => "must not flatten",
                   "blocks" => "must not replace",
                   "status" => "draft"
                 },
                 @dataset
               )

      {:ok, unchanged} = Content.get_document(seeded.doc_id, @doc_type, @dataset)
      assert unchanged.title == "Malformed elements"
      assert unchanged.content == content
    end
  end

  test "reserved body and blocks bindings cannot promote nested authority", %{
    schema: body_schema
  } do
    schema = %{
      body_schema
      | fields:
          body_schema.fields ++
            [
              %{"name" => "blocks", "title" => "Reserved blocks", "type" => "string"},
              %{"name" => "subtitle", "title" => "Subtitle", "type" => "string"}
            ]
    }

    blocks = [
      %{
        "id" => "bound-body",
        "type" => "field",
        "fieldName" => "body",
        "value" => "original body binding"
      },
      %{
        "id" => "bound-blocks",
        "type" => "field",
        "fieldName" => "blocks",
        "value" => "original blocks binding"
      },
      %{
        "id" => "bound-subtitle",
        "type" => "field",
        "fieldName" => "subtitle",
        "value" => "Before"
      }
    ]

    content = %{
      "body" => %{"blocks" => blocks, "unknown" => %{"keep" => true}},
      "subtitle" => "Before",
      "outside" => "unchanged"
    }

    {:ok, base_doc} =
      Content.upsert_document(
        @doc_type,
        %{"doc_id" => "reserved-nested-bindings", "title" => "Reserved", "content" => content},
        @dataset
      )

    assert {:error, {:ambiguous_historical_block_bindings, reserved}} =
             Content.upsert_draft(
               base_doc,
               @doc_type,
               schema,
               %{
                 "title" => "Title must not partially save",
                 "body" => "attempted body replacement",
                 "blocks" => "attempted blocks replacement",
                 "subtitle" => "After",
                 "status" => "draft"
               },
               @dataset
             )

    assert Enum.sort(reserved) == ["blocks", "body"]

    {:ok, unchanged} = Content.get_document(base_doc.doc_id, @doc_type, @dataset)
    assert unchanged.title == "Reserved"
    assert unchanged.content == content
    refute Map.has_key?(unchanged.content, "blocks")
  end

  defp section_with_card do
    %{
      "id" => "section-1",
      "type" => "section",
      "futureSection" => %{"keep" => true},
      "blocks" => [
        %{
          "id" => "card-1",
          "type" => "card",
          "tone" => "quiet",
          "futureCard" => [1, 2, 3],
          "slots" => %{
            "title" => [%{"type" => "heading", "text" => "Card title", "level" => 3}],
            "body" => [paragraph("card-body", "Card body")],
            "futureSlot" => %{"opaque" => true}
          }
        }
      ]
    }
  end

  defp paragraph(id, text) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
  end

  defp with_subtitle(schema) do
    %{
      schema
      | fields:
          schema.fields ++
            [%{"name" => "subtitle", "title" => "Subtitle", "type" => "string"}]
    }
  end
end
