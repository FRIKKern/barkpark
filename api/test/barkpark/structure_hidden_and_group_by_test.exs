defmodule Barkpark.StructureHiddenAndGroupByTest do
  @moduledoc """
  Gyldendal parity stage E3.3 — two desk declarations the agency's Sanity
  structure has and the twin needed:

    * `desk.hidden: true` on a schema takes a type OUT of the desk entirely (no
      node, and the …Rest census does not resurrect it) — the explicit opt-out
      for worker-written precompute types.
    * `{"kind":"groupBy"}` in the deskStructure document — "Etter kategori":
      one child list per document of the `over` type, each filtered to the
      rows whose `by` path equals that document's id.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "hidden-groupby-#{System.unique_integer([:positive])}"

  defp schema!(name, title, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Tittel", "type" => "string"},
              %{"name" => "category", "title" => "Kategori", "type" => "string"}
            ]
          },
          extra
        ),
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

  setup do
    schema!("publication", "Utgivelse")
    schema!("category", "Kategori")
    schema!("catalogueRow", "Katalograd (avledet)", %{"desk" => %{"hidden" => true}})
    doc!("catalogueRow", "cr-1", "row")
    doc!("category", "cat-fiction", "Fiction")
    doc!("category", "cat-kids", "Children")
    doc!("publication", "pub-1", "Alpha", %{"category" => "cat-fiction"})
    doc!("publication", "pub-2", "Bravo", %{"category" => "cat-kids"})
    doc!("publication", "pub-3", "Charlie", %{"category" => "cat-fiction"})
    :ok
  end

  defp all_type_names(node), do: collect(node.items || [], [])

  defp collect(items, acc) do
    Enum.reduce(items, acc, fn n, acc ->
      acc = if n.type_name, do: [n.type_name | acc], else: acc
      collect(n.items || [], acc)
    end)
  end

  test "desk.hidden takes a type out of the desk — no node, and …Rest does not resurrect it" do
    tree = Structure.build(@dataset)

    refute "catalogueRow" in all_type_names(tree),
           "a hidden type must appear nowhere: #{inspect(all_type_names(tree))}"

    assert "publication" in all_type_names(tree), "a visible type still surfaces"

    # The control: a NON-hidden type with rows and NO schema home (a census-only
    # type) still lands in …Rest, so `hidden` is an opt-out, not a change to the
    # census — and the hidden type is not there beside it.
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: "orphan-1",
      type: "orphanRow",
      dataset: @dataset,
      status: "published",
      title: "orphan",
      rev: "rev-orphan-1",
      content: %{}
    })

    tree = Structure.build(@dataset)
    rest = Enum.find(tree.items, &(&1.id == "rest"))
    assert rest && Enum.any?(rest.items, &(&1.type_name == "orphanRow"))
    refute Enum.any?(rest.items, &(&1.type_name == "catalogueRow"))
  end

  test "groupBy declares one child list per `over` document, filtered on the `by` path" do
    schema!("deskStructure", "Desk", %{
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    items = [
      %{
        "kind" => "groupBy",
        "id" => "by-category",
        "title" => "Etter kategori",
        "type" => "publication",
        "by" => "content.category",
        "over" => "category",
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

    tree = Structure.build(@dataset)
    group = Enum.find(tree.items, &(&1.id == "by-category"))
    assert group, "the groupBy node is at the head of the desk"
    assert Enum.map(group.items, & &1.title) |> Enum.sort() == ["Children", "Fiction"]

    fiction = Enum.find(group.items, &(&1.title == "Fiction"))
    assert fiction.type == :document_type_list and fiction.type_name == "publication"
    assert fiction.filter == %{"content.category" => %{"eq" => "cat-fiction"}}

    # And the pane it opens lists exactly that category's rows, in the declared order.
    {panes, _} = PaneBuilder.build(@dataset, ["by-category", fiction.id])
    pane = List.last(panes)
    refute pane[:filter_error]
    assert Enum.map(pane.items, & &1.title) == ["Charlie", "Alpha"]
  end
end
