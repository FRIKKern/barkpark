defmodule Barkpark.Content.RichTextFormatTest do
  @moduledoc """
  The declared `format` of a richText field and its two schema-save aliases
  (owner decision D1, task-9296af21cac3f813). The schemas and ids are made up.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.RichTextFormat

  @dataset "rich_text_format_test"

  describe "format/1" do
    test "a declared format wins" do
      assert RichTextFormat.format(%{"name" => "body", "format" => "portableText"}) ==
               :portable_text

      assert RichTextFormat.format(%{"name" => "intro", "format" => "portableDoc"}) ==
               :portable_doc
    end

    test "with no format: the block editor is PortableDoc, body and blocks are legacy, the rest Portable Text" do
      assert RichTextFormat.format(%{"name" => "intro", "editor" => "blocks"}) == :portable_doc
      assert RichTextFormat.format(%{"name" => "body"}) == :legacy
      assert RichTextFormat.format(%{"name" => "blocks"}) == :legacy
      assert RichTextFormat.format(%{"name" => "intro"}) == :portable_text
    end

    test "a legacy body reads its stored value" do
      pt = [%{"_type" => "block", "_key" => "a", "children" => []}]
      doc = [%{"id" => "p1", "type" => "paragraph"}]

      assert RichTextFormat.stores_portable_text?(%{"name" => "body"}, pt)
      refute RichTextFormat.stores_portable_text?(%{"name" => "body"}, doc)

      assert RichTextFormat.stores_portable_text?(
               %{"name" => "body", "format" => "portableText"},
               nil
             )
    end
  end

  describe "normalise_field/1" do
    test "type portableText becomes richText with the format" do
      assert RichTextFormat.normalise_field(%{"name" => "body", "type" => "portableText"}) ==
               %{"name" => "body", "type" => "richText", "format" => "portableText"}
    end

    test "Sanity's array of blocks becomes richText with its vocabulary" do
      sanity = %{
        "name" => "content",
        "title" => "Content",
        "type" => "array",
        "of" => [
          %{
            "type" => "block",
            "styles" => [%{"title" => "Normal", "value" => "normal"}, "h2"],
            "lists" => ["bullet"],
            "marks" => %{
              "decorators" => [%{"title" => "Strong", "value" => "strong"}, "strike-through"],
              "annotations" => [
                %{
                  "name" => "siteLink",
                  "type" => "object",
                  "fields" => [%{"name" => "href", "type" => "string"}]
                }
              ]
            },
            "of" => [
              %{
                "name" => "badge",
                "type" => "object",
                "fields" => [%{"name" => "label", "type" => "string"}]
              }
            ]
          },
          %{"type" => "factBox", "title" => "Fact box"},
          %{"type" => "image"}
        ]
      }

      assert RichTextFormat.normalise_field(sanity) == %{
               "name" => "content",
               "title" => "Content",
               "type" => "richText",
               "format" => "portableText",
               "blocks" => %{
                 "styles" => ["normal", "h2"],
                 "lists" => ["bullet"],
                 "marks" => ["strong", "strike-through"],
                 "annotations" => [
                   %{"name" => "siteLink", "fields" => [%{"name" => "href", "type" => "string"}]}
                 ],
                 "inline" => [
                   %{"name" => "badge", "fields" => [%{"name" => "label", "type" => "string"}]}
                 ],
                 "of" => [%{"name" => "factBox", "title" => "Fact box"}, %{"name" => "image"}]
               }
             }
    end

    test "a Sanity block member that names no lists leaves those keys out" do
      sanity = %{"name" => "c", "type" => "array", "of" => [%{"type" => "block"}]}

      assert %{"type" => "richText", "format" => "portableText", "blocks" => blocks} =
               RichTextFormat.normalise_field(sanity)

      assert blocks == %{"of" => []}
    end

    test "format portableDoc gets the block editor" do
      assert RichTextFormat.normalise_field(%{
               "name" => "x",
               "type" => "richText",
               "format" => "portableDoc"
             })["editor"] ==
               "blocks"
    end

    test "aliases are normalised inside composites, arrays and a vocabulary's fields" do
      field = %{
        "name" => "sections",
        "type" => "arrayOf",
        "of" => [
          %{
            "name" => "section",
            "type" => "composite",
            "fields" => [%{"name" => "text", "type" => "portableText"}]
          }
        ]
      }

      [%{"fields" => [text]}] = RichTextFormat.normalise_field(field)["of"]
      assert text["type"] == "richText" and text["format"] == "portableText"
    end

    test "other fields are left alone" do
      field = %{"name" => "tags", "type" => "array", "of" => [%{"type" => "string"}]}
      assert RichTextFormat.normalise_field(field) == field
    end
  end

  describe "schema save" do
    defp apply_schema(fields),
      do:
        Content.upsert_schema(
          %{"name" => "story", "title" => "Story", "visibility" => "public", "fields" => fields},
          @dataset
        )

    test "the aliases are stored as richText with a format" do
      {:ok, schema} =
        apply_schema([
          %{"name" => "body", "type" => "portableText"},
          %{
            "name" => "lead",
            "type" => "array",
            "of" => [%{"type" => "block", "styles" => ["normal"]}]
          }
        ])

      assert [body, lead] = schema.fields
      assert %{"type" => "richText", "format" => "portableText"} = body

      assert %{
               "type" => "richText",
               "format" => "portableText",
               "blocks" => %{"styles" => ["normal"]}
             } =
               lead
    end

    test "an unknown format, and portableText with the block editor, are refused" do
      assert {:error, cs} =
               apply_schema([%{"name" => "body", "type" => "richText", "format" => "html"}])

      assert errors_on(cs).fields |> hd() =~ "must be one of portableText, portableDoc"

      assert {:error, cs} =
               apply_schema([
                 %{
                   "name" => "body",
                   "type" => "richText",
                   "format" => "portableText",
                   "editor" => "blocks"
                 }
               ])

      assert errors_on(cs).fields |> hd() =~ "cannot use `editor: blocks`"
    end

    test "a localizedText format is not read as a richText format" do
      assert {:ok, _} =
               apply_schema([
                 %{
                   "name" => "t",
                   "type" => "localizedText",
                   "languages" => ["nb"],
                   "format" => "plain"
                 }
               ])
    end

    test "a named object type in a vocabulary's `of` is read with its fields" do
      # Object types resolve through a workspace scope (Schema.resolve_object_type/3).
      {:ok, ws} =
        Barkpark.Tenancy.create_workspace(%{
          slug: "rtf-#{System.unique_integer([:positive])}",
          name: "Rich text format"
        })

      {:ok, proj} = Barkpark.Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: @dataset, name: @dataset})
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "factBox",
            "title" => "Fact box",
            "kind" => "object",
            "fields" => [%{"name" => "heading", "type" => "string"}]
          },
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "story",
            "title" => "Story",
            "fields" => [
              %{
                "name" => "body",
                "type" => "richText",
                "format" => "portableText",
                "blocks" => %{"of" => [%{"name" => "factBox", "title" => "Fact box"}]}
              }
            ]
          },
          @dataset,
          scope
        )

      {:ok, schema} = Content.get_schema("story", @dataset, scope)
      [%{"blocks" => %{"of" => [entry]}}] = schema.fields

      assert entry["namedType"] == "factBox"
      assert [%{"name" => "heading", "type" => "string"}] = entry["fields"]

      # The stored row keeps the name only.
      {:ok, raw} = Content.Schema.get_schema_raw("story", @dataset, scope)

      assert [%{"blocks" => %{"of" => [%{"name" => "factBox", "title" => "Fact box"}]}}] =
               raw.fields
    end
  end

  describe "edges" do
    test "a reference field of a Portable Text custom block is an edge" do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
          @dataset
        )

      {:ok, _} =
        apply_schema([
          %{
            "name" => "body",
            "type" => "richText",
            "format" => "portableText",
            "blocks" => %{
              "of" => [
                %{
                  "name" => "quoteCard",
                  "fields" => [
                    %{"name" => "speaker", "type" => "reference", "refType" => "person"}
                  ]
                }
              ]
            }
          }
        ])

      {:ok, _} =
        Content.create_document("person", %{"_id" => "pers-1", "title" => "A person"}, @dataset)

      {:ok, _} = Content.publish_document("pers-1", "person", @dataset)

      body = [%{"_type" => "quoteCard", "_key" => "q1", "speaker" => "pers-1"}]

      {:ok, _} =
        Content.create_document(
          "story",
          %{"_id" => "story-1", "title" => "S", "content" => %{"body" => body}},
          @dataset
        )

      {:ok, doc} = Content.publish_document("story-1", "story", @dataset)

      assert [%{to_id: "pers-1", field: "body"}] = Content.extract_edges(doc)
    end
  end
end
