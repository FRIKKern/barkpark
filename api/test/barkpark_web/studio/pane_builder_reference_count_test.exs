defmodule BarkparkWeb.Studio.PaneBuilderReferenceCountTest do
  @moduledoc """
  Gyldendal parity E9 — the agency desk's two count-based lists, rendered.

  Sanity writes them as a correlated count:

      _type == "category" && count(*[_type == "publication" && references(^._id)]) > 0
      _type == "category" && count(*[_type == "publication" && references(^._id)]) == 0

  A declared `documentTypeList` carrying `referencedBy` / `notReferencedBy`
  renders the same two sets, and the pane reports no filter error — the shape a
  desk node gets when its filter cannot be applied.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "refcount-panes-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "category",
          "title" => "Kategori",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "category",
              "title" => "Kategori",
              "type" => "reference",
              "to" => ["category"]
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

    for {id, title} <- [{"cat-krim", "Krim"}, {"cat-poesi", "Poesi"}] do
      {:ok, _} =
        Content.create_document(
          "category",
          %{"doc_id" => id, "title" => title, "content" => %{}},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "category", @dataset)
    end

    {:ok, _} =
      Content.create_document(
        "publication",
        %{
          "doc_id" => "pub-1",
          "title" => "Nordic Noir",
          "content" => %{"category" => "cat-krim"}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("pub-1", "publication", @dataset)

    items = [
      %{
        "kind" => "documentTypeList",
        "id" => "kategorier-med-utgivelser",
        "type" => "category",
        "title" => "Kategorier med utgivelser",
        "filter" => %{"_id" => %{"referencedBy" => "publication"}}
      },
      %{
        "kind" => "groupBy",
        "id" => "etter-kategori",
        "type" => "publication",
        "by" => "content.category",
        "over" => "category",
        "title" => "Etter kategori",
        "overFilter" => %{"_id" => %{"referencedBy" => "publication"}}
      },
      %{
        "kind" => "documentTypeList",
        "id" => "kategorier-uten-utgivelser",
        "type" => "category",
        "title" => "Kategorier uten utgivelser",
        "filter" => %{"_id" => %{"notReferencedBy" => "publication"}}
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

  defp titles(node_id) do
    {panes, _editor} = PaneBuilder.build(@dataset, [node_id])
    pane = List.last(panes)

    refute pane[:filter_error],
           "the desk node reported a filter error: #{inspect(pane[:filter_error])}"

    assert pane.type_name == "category"
    pane.items |> Enum.map(& &1.title) |> Enum.sort()
  end

  test "the referenced list holds only the category a publication points at" do
    assert titles("kategorier-med-utgivelser") == ["Krim"]
  end

  test "the unreferenced list is its complement" do
    assert titles("kategorier-uten-utgivelser") == ["Poesi"]
  end

  test "a groupBy groups over the referenced rows only, like Sanity's «Etter kategori»" do
    {panes, _editor} = PaneBuilder.build(@dataset, ["etter-kategori"])
    pane = List.last(panes)

    # One child list per category a publication points at — and none for the
    # unused one, which would otherwise be an empty group in the desk.
    assert Enum.map(pane.items, & &1.title) == ["Krim"]
  end
end
