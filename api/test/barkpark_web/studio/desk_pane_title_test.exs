defmodule BarkparkWeb.Studio.DeskPaneTitleTest do
  @moduledoc """
  task-a3e829ace0b184ea — a declared desk item's `paneTitle` names the pane it
  opens, apart from its row, as Sanity's `S.listItem().title('Med anmeldelser')
  .child(S.documentTypeList('product').title('Produkter med anmeldelser'))`.
  82 of the 179 items in gyldendal.no's desk do this. Without `paneTitle` the
  pane keeps the row's title, as before.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "desk-pane-title-#{System.unique_integer([:positive])}"
  @token "barkpark-desk-pane-title-token"

  @items [
    %{
      "kind" => "documentTypeList",
      "id" => "anmeldt",
      "type" => "product",
      "title" => "Med anmeldelser",
      "paneTitle" => "Produkter med anmeldelser"
    },
    %{"kind" => "documentTypeList", "id" => "alle", "type" => "product", "title" => "Alle"},
    %{
      "kind" => "list",
      "id" => "utgivelser",
      "title" => "Utgivelser",
      "paneTitle" => "Alle utgivelser",
      "items" => [%{"kind" => "documentTypeList", "type" => "product", "title" => "Produkter"}]
    },
    %{
      "kind" => "tree",
      "id" => "kategorier",
      "type" => "category",
      "parent" => "content.parent",
      "title" => "Kategorier",
      "paneTitle" => "Hovedkategorier"
    },
    %{
      "kind" => "groupBy",
      "id" => "etter",
      "type" => "product",
      "over" => "category",
      "by" => "content.category",
      "title" => "Etter kategori",
      "paneTitle" => "Produkter etter kategori"
    },
    %{"kind" => "list", "id" => "tom", "title" => "Tom", "paneTitle" => "", "items" => []}
  ]

  setup do
    for name <- ~w(product category) do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
          },
          @dataset
        )
    end

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

  test "the structure carries paneTitle on list, documentTypeList, tree and groupBy items" do
    assert desk_node("anmeldt").pane_title == "Produkter med anmeldelser"
    assert desk_node("utgivelser").pane_title == "Alle utgivelser"
    assert desk_node("kategorier").pane_title == "Hovedkategorier"
    assert desk_node("etter").pane_title == "Produkter etter kategori"
    # The row keeps its own title.
    assert desk_node("anmeldt").title == "Med anmeldelser"
    # Absent or blank: none.
    assert desk_node("alle").pane_title == nil
    assert desk_node("tom").pane_title == nil
  end

  test "GET /v1/structure returns paneTitle only where one is declared", %{conn: conn} do
    {:ok, _} = Barkpark.Auth.create_token(@token, "desk", @dataset, ["read", "write", "admin"])

    items =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/structure/#{@dataset}")
      |> json_response(200)
      |> get_in(["structure", "items"])
      |> Map.new(&{&1["id"], &1})

    assert items["anmeldt"]["title"] == "Med anmeldelser"
    assert items["anmeldt"]["paneTitle"] == "Produkter med anmeldelser"
    assert items["etter"]["paneTitle"] == "Produkter etter kategori"
    refute Map.has_key?(items["alle"], "paneTitle")
    refute Map.has_key?(items["tom"], "paneTitle")
  end

  test "the LiveView Studio titles the opened pane with paneTitle, and the row with title" do
    title_of = fn path ->
      PaneBuilder.build(@dataset, path) |> elem(0) |> List.last() |> Map.get(:title)
    end

    assert title_of.(["anmeldt"]) == "Produkter med anmeldelser"
    assert title_of.(["utgivelser"]) == "Alle utgivelser"
    assert title_of.(["kategorier"]) == "Hovedkategorier"
    assert title_of.(["etter"]) == "Produkter etter kategori"
    assert title_of.(["alle"]) == "Alle"
    assert title_of.(["tom"]) == "Tom"

    {[root | _], _} = PaneBuilder.build(@dataset, ["anmeldt"])
    row = Enum.find(root.items, &(&1[:id] == "anmeldt"))
    assert row.title == "Med anmeldelser"
  end
end
