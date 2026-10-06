defmodule BarkparkWeb.Studio.StudioImageAltSubfieldTest do
  @moduledoc """
  An image field that declares Sanity's alt SUBFIELD (`fields: [{name: "alt"}]`)
  gets the picker's Alt text input in Classic and in Beta's property rows
  (task-6f2b84a0e32688ad; the value shape and validation are
  task-f0f51946d2de672d, #21802).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @image ~s({"url":"/media/cover.png","assetId":"asset-cover"})

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "altpub",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "cover",
              "title" => "Omslag",
              "type" => "image",
              "options" => %{"hotspot" => true},
              "fields" => [
                %{
                  "name" => "alt",
                  "title" => "Alternativ tekst",
                  "type" => "string",
                  "validation" => %{"required" => true}
                }
              ]
            },
            %{"name" => "plain", "title" => "Plain", "type" => "image"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "altpub",
        %{
          "doc_id" => "altpub-1",
          "title" => "Fjellet",
          "content" => %{
            "title" => "Fjellet",
            "cover" => Jason.decode!(@image),
            "plain" => Jason.decode!(@image)
          }
        },
        @dataset
      )

    :ok
  end

  defp pickers(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("bp-media-picker")
    |> Enum.map(fn el ->
      {LazyHTML.attribute(el, "alt") |> List.first(),
       LazyHTML.attribute(el, "hotspot") |> List.first()}
    end)
  end

  test "Classic: the declared alt subfield turns on the picker's Alt text input", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/altpub/altpub-1"))

    # cover declares alt (+ hotspot); plain declares neither, byte-identical as before
    assert [{alt_cover, hot_cover}, {nil, nil}] = pickers(html)
    assert alt_cover != nil
    assert hot_cover != nil
  end

  test "Beta: the property row's picker offers the same Alt text input", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/altpub/altpub-1"))
    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert html =~ ~s(data-test-id="studio-doc-beta-editor")

    beta =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(bp-media-picker[data-test-id="paper-field-field-image"]))
      |> Enum.map(fn el -> LazyHTML.attribute(el, "alt") |> List.first() end)

    assert length(beta) == 2
    assert Enum.count(beta, &(&1 != nil)) == 1
  end

  test "Classic: a missing required alt is shown under the image field on publish",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/altpub/altpub-1"))
    html = render_click(view, "publish", %{})

    assert html =~ "Alternativ tekst: Required"
  end

  test "a missing required alt is reported for the image field" do
    {:ok, schema} = Content.get_schema("altpub", @dataset)

    assert {:error, errors} =
             Barkpark.Content.Validation.validate(
               %{"title" => "Fjellet", "cover" => Jason.decode!(@image)},
               "Fjellet",
               schema
             )

    assert inspect(errors) =~ "alt"
  end
end
