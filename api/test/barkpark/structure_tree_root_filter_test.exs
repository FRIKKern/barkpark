defmodule Barkpark.StructureTreeRootFilterTest do
  @moduledoc """
  task-e9f14aeb3ed09953 — a desk tree's own `filter` narrows its root AND every
  level below, as Sanity's «Informasjonssider → Hierarkisk struktur» roots at
  `pageType == "information" && !defined(parent._ref)`. Before, a tree ignored
  any filter and rooted at "parent is null": landing pages joined the
  information root (17 roots where Sanity has 14). A tree without a filter is
  unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "tree-root-filter-#{System.unique_integer([:positive])}"
  @token "barkpark-tree-root-filter-token"

  defp doc!(id, title, content) do
    {:ok, _} =
      Content.create_document(
        "infopage",
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, "infopage", @dataset)
  end

  @tree %{
    "kind" => "tree",
    "id" => "hierarkisk",
    "title" => "Hierarkisk struktur",
    "type" => "infopage",
    "parent" => "content.parent",
    "filter" => %{"content.pageType" => %{"eq" => "information"}},
    "orderings" => [%{"field" => "title", "direction" => "asc"}]
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "infopage",
          "title" => "Side",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "pageType", "type" => "string"},
            %{"name" => "parent", "type" => "reference", "refType" => "infopage"}
          ]
        },
        @dataset
      )

    doc!("info-a", "Alpha", %{"pageType" => "information"})
    doc!("info-b", "Bravo", %{"pageType" => "information"})
    doc!("landing-x", "Landing", %{"pageType" => "landingPage"})
    doc!("info-a1", "Alpha one", %{"pageType" => "information", "parent" => "info-a"})
    doc!("landing-a2", "Alpha landing", %{"pageType" => "landingPage", "parent" => "info-a"})

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

    plain = @tree |> Map.delete("filter") |> Map.merge(%{"id" => "alle", "title" => "Alle"})

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{
          "doc_id" => "deskStructure",
          "title" => "Desk",
          "content" => %{"items" => [@tree, plain]}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    :ok
  end

  defp desk_node(id), do: Enum.find(Structure.build(@dataset).items, &(&1.id == id))

  defp row_titles(path) do
    {panes, _} = PaneBuilder.build(@dataset, path)
    pane = List.last(panes)
    refute pane[:filter_error], inspect(pane[:filter_error])
    for %{type: :doc} = i <- pane.items, do: i.title
  end

  test "the node's root filter is the tree's own filter plus the parentless clause" do
    node = desk_node("hierarkisk")

    assert node.filter == %{
             "content.pageType" => %{"eq" => "information"},
             "content.parent" => %{"is" => "null"}
           }

    assert node.tree == %{
             "parent" => "content.parent",
             "filter" => %{"content.pageType" => %{"eq" => "information"}}
           }

    assert node.error == nil
  end

  test "the root lists only the filtered parentless documents" do
    assert row_titles(["hierarkisk"]) == ["Alpha", "Bravo"]
  end

  test "a level below is narrowed by the same filter" do
    # The parent on top, then only its information child (not the landing page).
    assert row_titles(["hierarkisk", "info-a"]) == ["Alpha", "Alpha one"]
  end

  test "a tree without a filter is unchanged" do
    node = desk_node("alle")
    assert node.filter == %{"content.parent" => %{"is" => "null"}}
    assert node.tree == %{"parent" => "content.parent"}
    assert row_titles(["alle"]) == ["Alpha", "Bravo", "Landing"]
    assert row_titles(["alle", "info-a"]) == ["Alpha", "Alpha landing", "Alpha one"]
  end

  test "GET /v1/structure carries the tree's filter for a Studio to drill with", %{conn: conn} do
    {:ok, _} = Barkpark.Auth.create_token(@token, "desk", @dataset, ["read", "write", "admin"])

    items =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/structure/#{@dataset}")
      |> json_response(200)
      |> get_in(["structure", "items"])
      |> Map.new(&{&1["id"], &1})

    assert items["hierarkisk"]["tree"]["filter"] == %{
             "content.pageType" => %{"eq" => "information"}
           }

    assert items["hierarkisk"]["filter"]["content.pageType"] == %{"eq" => "information"}
    refute Map.has_key?(items["alle"]["tree"], "filter")
  end
end
