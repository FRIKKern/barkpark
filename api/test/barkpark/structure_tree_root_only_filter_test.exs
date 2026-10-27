defmodule Barkpark.StructureTreeRootOnlyFilterTest do
  @moduledoc """
  task-7d29adf66bbf5df4 — a tree's `rootFilter` alone decides the root level.
  Sanity's category tree roots at `isTopLevel == true` although those
  categories have parents, and each level below lists the children with no
  other clause. Without `rootFilter` the root is the parentless clause merged
  with `filter`, and `filter` narrows every level below.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "tree-root-only-#{System.unique_integer([:positive])}"

  defp doc!(type, id, title, content) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)
  end

  defp refs(ids), do: Enum.map(ids, &%{"_type" => "reference", "_ref" => &1, "_key" => &1})

  defp desk!(items) do
    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "shelf",
          "title" => "Shelf",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "featured", "type" => "boolean"},
            %{"name" => "parents", "type" => "array"}
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

    # "Hall" is parentless and not featured. "Left" and "Right" are featured
    # but sit under "Hall". "Top", "Bottom" and "Corner" are children that are
    # not featured; "Corner" sits under both featured shelves.
    doc!("shelf", "s-hall", "Hall", %{})
    doc!("shelf", "s-left", "Left", %{"featured" => true, "parents" => refs(["s-hall"])})
    doc!("shelf", "s-right", "Right", %{"featured" => true, "parents" => refs(["s-hall"])})
    doc!("shelf", "s-top", "Top", %{"parents" => refs(["s-left"])})
    doc!("shelf", "s-bottom", "Bottom", %{"parents" => refs(["s-left"])})
    doc!("shelf", "s-corner", "Corner", %{"parents" => refs(["s-left", "s-right"])})
    :ok
  end

  @title [%{"field" => "title", "direction" => "asc"}]

  defp tree(extra) do
    Map.merge(
      %{
        "kind" => "tree",
        "id" => "shelves",
        "title" => "Shelves",
        "type" => "shelf",
        "parent" => "content.parents",
        "parentOp" => "has",
        "orderings" => @title
      },
      extra
    )
  end

  defp rows(path) do
    {panes, _} = PaneBuilder.build(@dataset, path)
    pane = List.last(panes)
    refute pane[:filter_error], inspect(pane[:filter_error])
    for %{type: :doc} = i <- pane.items, do: i.title
  end

  defp desk_node(id), do: Enum.find(Structure.build(@dataset).items, &(&1.id == id))

  test "rootFilter roots at the featured shelves although they have parents" do
    desk!([tree(%{"rootFilter" => %{"content.featured" => %{"eq" => true}}})])

    node = desk_node("shelves")
    assert node.filter == %{"content.featured" => %{"eq" => true}}
    assert node.tree == %{"parent" => "content.parents", "op" => "has"}
    assert node.error == nil

    assert rows(["shelves"]) == ["Left", "Right"]
  end

  test "rootFilter does not narrow the levels below" do
    desk!([tree(%{"rootFilter" => %{"content.featured" => %{"eq" => true}}})])

    # The opened shelf on top, then its children, none of them featured.
    assert rows(["shelves", "s-left"]) == ["Left", "Bottom", "Corner", "Top"]
    assert rows(["shelves", "s-right"]) == ["Right", "Corner"]
  end

  test "without rootFilter the root stays parentless and filter narrows every level" do
    desk!([tree(%{"filter" => %{"content.featured" => %{"eq" => true}}})])

    node = desk_node("shelves")

    assert node.filter == %{
             "content.featured" => %{"eq" => true},
             "content.parents" => %{"countEq" => 0}
           }

    assert rows(["shelves"]) == []
  end

  test "rootFilter with filter: the root reads rootFilter, the levels read filter" do
    desk!([
      tree(%{
        "rootFilter" => %{"content.featured" => %{"eq" => true}},
        "filter" => %{"title" => %{"notContains" => "Top"}}
      })
    ])

    node = desk_node("shelves")
    assert node.filter == %{"content.featured" => %{"eq" => true}}

    assert node.tree == %{
             "parent" => "content.parents",
             "op" => "has",
             "filter" => %{"title" => %{"notContains" => "Top"}}
           }

    assert rows(["shelves"]) == ["Left", "Right"]
    assert rows(["shelves", "s-left"]) == ["Left", "Bottom", "Corner"]
  end

  test "an invalid rootFilter is reported on the item" do
    desk!([tree(%{"rootFilter" => %{"content.featured" => %{"bogusOp" => true}}})])

    assert desk_node("shelves").error =~ "bogusOp"
  end
end
