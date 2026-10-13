defmodule BarkparkWeb.Studio.StudioBetaStoredPickerValuesTest do
  @moduledoc """
  Beta renders a document whose reference and image fields hold their STORED
  shapes (task-a6f50ddb9201e7b1).

  Found dogfooding: a publication whose author was set with the Studio picker
  stores `{"_ref" => id}`. Pressing Beta crashed the LiveView —
  `Phoenix.HTML.Safe not implemented for Map` — because the bound
  field-reference block carries the stored value verbatim into the picker's
  `value` attribute. The process remounted in Classic and the editor only heard
  "Selected “Beta”.". The field-image block had the same exposure for a stored
  image object.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @image %{"url" => "/media/cover.png", "assetId" => "asset-cover"}

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "author",
              "title" => "Forfatter",
              "type" => "reference",
              "to" => [%{"type" => "author"}]
            },
            %{"name" => "cover", "title" => "Omslag", "type" => "image"},
            %{"name" => "body", "title" => "Tekst", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "author"},
            %{"kind" => "field", "name" => "cover"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "publication",
        %{
          "doc_id" => "pub-stored",
          "title" => "Fjellet",
          "content" => %{
            "title" => "Fjellet",
            "author" => %{"_ref" => "author-ness"},
            "cover" => @image
          }
        },
        @dataset
      )

    :ok
  end

  test "Beta renders the pickers with the values Classic would pass", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/publication/pub-stored"))

    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert html =~ ~s(data-test-id="studio-doc-beta-editor")

    [ref_value] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(bp-reference-picker[data-test-id="paper-field-field-reference"]))
      |> LazyHTML.attribute("value")

    assert ref_value == "author-ness"

    [image_value] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(bp-media-picker[data-test-id="paper-field-field-image"]))
      |> LazyHTML.attribute("value")

    assert Jason.decode!(image_value) == @image
  end
end
