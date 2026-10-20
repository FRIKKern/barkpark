defmodule BarkparkWeb.Studio.StudioDeskPlusPresetTest do
  @moduledoc """
  task-dc9b751450c2c2c4 — a declared desk type list's `initialValues` preset
  the document its "+" starts, as Sanity's initialValueTemplates: a page made
  from «Landingssider» has pageType landingPage and shows in that list at once.
  A list without them starts an empty document, as before. Presets are
  checked against the schema: an undeclared field, a select value outside its
  options or a value of the wrong kind is dropped, never written.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Structure}

  @dataset "production"
  @type_name "presetpage"
  @token "barkpark-desk-preset-token"

  @items [
    %{
      "kind" => "documentTypeList",
      "id" => "landingssider",
      "type" => "presetpage",
      "title" => "Landingssider",
      "filter" => %{"content.pageType" => %{"eq" => "landingPage"}},
      "initialValues" => %{"content.pageType" => "landingPage"}
    },
    %{
      "kind" => "documentTypeList",
      "id" => "alle",
      "type" => "presetpage",
      "title" => "Alle sider"
    },
    %{
      "kind" => "documentTypeList",
      "id" => "feil",
      "type" => "presetpage",
      "title" => "Feil",
      "initialValues" => %{"pageType" => "notAnOption", "ghost" => "x"}
    },
    %{
      "kind" => "documentTypeList",
      "id" => "delvis",
      "type" => "presetpage",
      "title" => "Delvis",
      "initialValues" => %{"pageType" => "infoPage", "title" => 42, "ghost" => 1}
    },
    %{
      "kind" => "documentTypeList",
      "id" => "tom",
      "type" => "presetpage",
      "title" => "Tom",
      "initialValues" => %{}
    }
  ]

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Side",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "pageType",
              "title" => "Sidetype",
              "type" => "select",
              "options" => [
                %{"title" => "Landingsside", "value" => "landingPage"},
                %{"title" => "Informasjonsside", "value" => "infoPage"}
              ]
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Innhold", "content" => %{"items" => @items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    :ok
  end

  defp desk_node(id), do: Enum.find(Structure.build(@dataset).items, &(&1.id == id))

  test "the structure carries initialValues, a filter path read as its field" do
    assert desk_node("landingssider").initial_values == %{"pageType" => "landingPage"}
    assert desk_node("alle").initial_values == nil
    assert desk_node("tom").initial_values == nil
  end

  test "initialValues are checked against the schema: only declared fields with fitting values" do
    # A select value outside its options and an undeclared field: nothing left.
    assert desk_node("feil").initial_values == nil
    # A string field given a number and an undeclared field are dropped; the valid option stays.
    assert desk_node("delvis").initial_values == %{"pageType" => "infoPage"}
  end

  test "GET /v1/structure returns initialValues only where declared", %{conn: conn} do
    {:ok, _} = Barkpark.Auth.create_token(@token, "desk", @dataset, ["read", "write", "admin"])

    items =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/structure/#{@dataset}")
      |> json_response(200)
      |> get_in(["structure", "items"])
      |> Map.new(&{&1["id"], &1})

    assert items["landingssider"]["initialValues"] == %{"pageType" => "landingPage"}
    refute Map.has_key?(items["alle"], "initialValues")
  end

  defp press_plus(conn, list) do
    {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{list}"))

    view
    |> element(~s(button.pane-add-btn[phx-value-type="#{@type_name}"]))
    |> render_click()

    path = assert_patch(view)
    [_, id] = Regex.run(~r{/(#{@type_name}-[0-9a-f]+)$}, path)
    {:ok, doc} = Content.get_document("drafts." <> id, @type_name, @dataset)
    {view, id, doc}
  end

  test "the + of a list with initialValues starts the document with them, and it is in that list",
       %{conn: conn} do
    # An existing page is never touched by a preset: only the new document gets it.
    {:ok, existing} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => "presetpage-existing",
          "title" => "Eksisterende",
          "content" => %{"pageType" => "infoPage"}
        },
        @dataset
      )

    {view, id, doc} = press_plus(conn, "landingssider")
    assert doc.content["pageType"] == "landingPage"
    assert render(view) =~ id

    {:ok, after_press} = Content.get_document(existing.doc_id, @type_name, @dataset)
    assert after_press.content == %{"pageType" => "infoPage"}
    assert after_press.rev == existing.rev
  end

  test "the + of a list whose presets do not fit the schema writes none of them", %{conn: conn} do
    {_view, _id, doc} = press_plus(conn, "feil")
    refute Map.has_key?(doc.content, "pageType")
    refute Map.has_key?(doc.content, "ghost")

    {_view, _id, doc} = press_plus(conn, "delvis")
    assert doc.content["pageType"] == "infoPage"
    refute Map.has_key?(doc.content, "ghost")
    refute doc.content["title"] == 42
  end

  test "the + of a list without initialValues starts an empty document, as before", %{conn: conn} do
    {_view, _id, doc} = press_plus(conn, "alle")
    refute Map.has_key?(doc.content, "pageType")
  end
end
