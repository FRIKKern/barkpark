defmodule Barkpark.PortableDoc.ProjectionImageValueTest do
  @moduledoc """
  A Beta image edit stores the image as an OBJECT, the shape Classic stores
  (task-7d500331aeb7aed2). `bp-media-picker` emits a JSON string; projection
  used to copy it verbatim, so `content[field]` became a string-in-a-string
  and the v2 walker read the image's typed `alt` as missing.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Projection

  @dataset "production"
  @picker ~s({"url":"/media/cover.png","assetId":"asset-cover","alt":"A mountain"})

  test "projected_value/1 decodes a field-image JSON object string, keeps a bare URL" do
    assert Projection.projected_value(%{"type" => "field-image", "value" => @picker}) ==
             %{"url" => "/media/cover.png", "assetId" => "asset-cover", "alt" => "A mountain"}

    assert Projection.projected_value(%{"type" => "field-image", "value" => "/media/x.png"}) ==
             "/media/x.png"

    assert Projection.projected_value(%{"type" => "field-image", "value" => "{not json"}) ==
             "{not json"

    # other field types are untouched
    assert Projection.projected_value(%{"type" => "field-string", "value" => @picker}) == @picker
  end

  test "a Beta block op on an image field stores an object carrying alt, and the required alt is met" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "imgproj",
          "title" => "Imgproj",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "cover",
              "type" => "image",
              "fields" => [
                %{"name" => "alt", "type" => "string", "validation" => %{"required" => true}}
              ]
            }
          ]
        },
        @dataset
      )

    id = "imgproj-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "imgproj",
        %{
          "doc_id" => id,
          "title" => "T",
          "content" => %{"cover" => %{"url" => "/media/cover.png", "assetId" => "asset-cover"}}
        },
        @dataset
      )

    {blocks, _synth?} = Content.resolve_blocks_for_edit(doc, "imgproj", @dataset)
    cover = Enum.find(blocks, &(&1["fieldName"] == "cover"))
    assert cover, "fixture: the editor list carries a cover block"

    op = %{"op" => "patch-block", "id" => cover["id"], "patch" => %{"value" => @picker}}
    {:ok, _} = Content.apply_document_block_op(doc.doc_id, "imgproj", op, @dataset)

    {:ok, saved} = Content.get_document(doc.doc_id, "imgproj", @dataset)
    assert %{"alt" => "A mountain", "url" => "/media/cover.png"} = saved.content["cover"]

    {:ok, schema} = Content.get_schema("imgproj", @dataset)
    assert {:ok, _} = Barkpark.Content.Validation.validate(saved.content, saved.title, schema)
  end
end
