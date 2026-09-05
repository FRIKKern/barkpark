defmodule BarkparkWeb.Studio.PaneBuilderDeclaredDeskTest do
  @moduledoc """
  Gyldendal parity stage E3.2 — the panes a declared desk opens: a pinned
  singleton opens its declared `documentId` (not the type name), a declared
  type list applies its own filter and orderings.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "declared-panes-#{System.unique_integer([:positive])}"

  setup do
    for {name, title, extra} <- [
          {"publication", "Utgivelse", %{}},
          {"siteSettings", "Nettstedsinnstillinger",
           %{"singleton" => true, "visibility" => "private"}},
          {"deskStructure", "Desk",
           %{
             "singleton" => true,
             "visibility" => "private",
             "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
           }}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => title,
              "visibility" => "public",
              "fields" => [
                %{"name" => "title", "title" => "Tittel", "type" => "string"},
                %{"name" => "cover", "title" => "Omslag", "type" => "image"}
              ]
            },
            extra
          ),
          @dataset
        )
    end

    for {id, title, cover} <- [
          {"p-b", "Bravo", %{"url" => "/b"}},
          {"p-a", "Alpha", nil},
          {"p-c", "Charlie", nil}
        ] do
      content = if cover, do: %{"cover" => cover}, else: %{}

      {:ok, _} =
        Content.create_document(
          "publication",
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )
    end

    {:ok, _} =
      Content.create_document(
        "siteSettings",
        %{"doc_id" => "site-settings-main", "title" => "Settings Main", "content" => %{}},
        @dataset
      )

    items = [
      %{
        "kind" => "singleton",
        "id" => "forside",
        "type" => "siteSettings",
        "documentId" => "site-settings-main",
        "title" => "Nettstedsinnstillinger"
      },
      %{
        "kind" => "documentTypeList",
        "id" => "uten-omslag",
        "type" => "publication",
        "title" => "Uten omslag",
        "filter" => %{"content.cover" => %{"is" => "null"}},
        "orderings" => [%{"field" => "title", "direction" => "desc"}]
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    :ok
  end

  test "a declared singleton opens its documentId, not the type name" do
    {_panes, editor} = PaneBuilder.build(@dataset, ["forside"])
    assert editor, "the singleton must open an editor"
    assert Barkpark.Content.DraftId.published_id(editor.doc.doc_id) == "site-settings-main"
    assert editor.type == "siteSettings"
  end

  test "a declared type list applies its own filter and orderings" do
    {panes, _editor} = PaneBuilder.build(@dataset, ["uten-omslag"])
    pane = List.last(panes)
    assert pane.type_name == "publication"
    refute pane[:filter_error]
    assert Enum.map(pane.items, & &1.title) == ["Charlie", "Alpha"]
  end
end
