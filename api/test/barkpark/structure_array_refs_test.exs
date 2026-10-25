defmodule Barkpark.StructureArrayRefsTest do
  @moduledoc """
  task-c603a1eb83c4fc01 — a desk groupBy and a tree can follow a reference held
  in an ARRAY, as Sanity's `$id in departments[]._ref` and
  `$parentId in parentCategories[]._ref`. A groupBy with `"op": "has"` lists a
  document under each group it names; a tree with `"parentOp": "has"` roots at
  the documents with no parent (missing or empty array) and shows a document
  with several parents under each. The defaults (`eq`) are unchanged.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "array-refs-#{System.unique_integer([:positive])}"

  defp schema!(name, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @dataset
      )
  end

  defp doc!(type, id, title, content \\ %{}) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)
  end

  defp refs(ids), do: Enum.map(ids, &%{"_type" => "reference", "_ref" => &1, "_key" => &1})

  setup do
    schema!("department", [%{"name" => "title", "type" => "string"}])

    schema!("person", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "departments", "type" => "array"}
    ])

    schema!("category", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "parentCategories", "type" => "array"}
    ])

    doc!("department", "dep-a", "Avdeling A")
    doc!("department", "dep-b", "Avdeling B")
    doc!("person", "p-1", "Ada", %{"departments" => refs(["dep-a", "dep-b"])})
    doc!("person", "p-2", "Bo", %{"departments" => refs(["dep-b"])})
    doc!("person", "p-3", "Cy", %{"departments" => []})

    doc!("category", "c-root", "Root")
    doc!("category", "c-empty", "Empty parents", %{"parentCategories" => []})
    doc!("category", "c-other", "Other root")
    doc!("category", "c-both", "Under both", %{"parentCategories" => refs(["c-root", "c-other"])})
    doc!("category", "c-one", "Under root", %{"parentCategories" => refs(["c-root"])})

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

    title = [%{"field" => "title", "direction" => "asc"}]

    items = [
      %{
        "kind" => "groupBy",
        "id" => "etter-avdeling",
        "title" => "Etter avdeling",
        "type" => "person",
        "over" => "department",
        "by" => "content.departments",
        "op" => "has",
        "orderings" => title
      },
      %{
        "kind" => "tree",
        "id" => "kategorier",
        "title" => "Produktkategorier",
        "type" => "category",
        "parent" => "content.parentCategories",
        "parentOp" => "has",
        "orderings" => title
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

  defp rows(path) do
    {panes, _} = PaneBuilder.build(@dataset, path)
    pane = List.last(panes)
    refute pane[:filter_error], inspect(pane[:filter_error])
    for %{type: :doc} = i <- pane.items, do: i.title
  end

  defp desk_node(id), do: Enum.find(Structure.build(@dataset).items, &(&1.id == id))

  test "a groupBy with op has lists a person under each department it names" do
    groups = desk_node("etter-avdeling").items
    by_title = Map.new(groups, &{&1.title, &1})
    assert by_title["Avdeling A"].filter == %{"content.departments" => %{"has" => "dep-a"}}

    assert rows(["etter-avdeling", by_title["Avdeling A"].id]) == ["Ada"]
    assert rows(["etter-avdeling", by_title["Avdeling B"].id]) == ["Ada", "Bo"]
  end

  test "a tree with parentOp has roots at no parent and shows a child under each parent" do
    node = desk_node("kategorier")
    assert node.filter == %{"content.parentCategories" => %{"countEq" => 0}}
    assert node.tree == %{"parent" => "content.parentCategories", "op" => "has"}
    assert node.error == nil

    # Missing and empty parents are both roots.
    assert rows(["kategorier"]) == ["Empty parents", "Other root", "Root"]
    # The parent on top, then its children; "Under both" shows under each parent.
    assert rows(["kategorier", "c-root"]) == ["Root", "Under both", "Under root"]
    assert rows(["kategorier", "c-other"]) == ["Other root", "Under both"]
  end
end
