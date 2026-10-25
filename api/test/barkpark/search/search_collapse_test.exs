defmodule Barkpark.Search.SearchCollapseTest do
  @moduledoc """
  task-3bbf99d2bce8ee51 — `collapse=<field>` on search: one hit per value, the
  best-ranked, with group sizes; the total and facets count groups. With
  collapse off the hits are those of the plain search, in its order.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "search-collapse-test"

  setup do
    ws = create_workspace!()
    scope = [workspace_id: ws.id, project_id: create_project!(ws).id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "displayName", "type" => "string"},
            %{"name" => "familyId", "type" => "string"},
            %{"name" => "Format", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    for {id, name, family, format} <- [
          {"b1", "Legemiddelhåndtering for sykepleiere", "f1", "Heftet"},
          {"b2", "Legemiddelhåndtering", "f1", "Lydbok"},
          {"b3", "Legemiddelhåndtering i praksis", "f2", "Heftet"},
          {"b4", "Legemiddelhåndtering og farmakologi", nil, "Ebok"},
          {"b5", "Legemiddelhåndtering legemiddelhåndtering", nil, "Heftet"}
        ] do
      content = %{"displayName" => name, "Format" => format}
      content = if family, do: Map.put(content, "familyId", family), else: content

      {:ok, _} =
        Content.create_document("book", %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, "book", @ds, scope)
    end

    %{scope: scope}
  end

  defp search(scope, opts) do
    Content.search_documents("legemiddelhåndtering", @ds, [type: "book"] ++ opts ++ scope)
  end

  test "collapse on a field no two hits share leaves the hits and their order as they were",
       %{scope: scope} do
    {plain, plain_total, _} = search(scope, [])
    # Every hit is its own group: no book holds `missing`.
    {same, same_total, meta} = search(scope, collapse: "missing")

    assert Enum.map(same, & &1.doc_id) == Enum.map(plain, & &1.doc_id)
    assert same == plain
    assert same_total == plain_total
    assert Map.values(meta.collapse.counts) |> Enum.uniq() == [1]
  end

  test "collapse keeps the best-ranked hit of each group, counts groups and sizes them",
       %{scope: scope} do
    {plain, 5, _} = search(scope, [])

    family = %{"b1" => "f1", "b2" => "f1", "b3" => "f2"}

    expected =
      plain
      |> Enum.map(& &1.doc_id)
      |> Enum.uniq_by(&Map.get(family, &1, &1))

    {hits, total, meta} = search(scope, collapse: "familyId", facet_fields: ["Format"])

    assert Enum.map(hits, & &1.doc_id) == expected
    assert total == 4
    f1 = Enum.find(expected, &(Map.get(family, &1) == "f1"))
    assert meta.collapse.counts[f1] == 2
    assert meta.collapse.field == "familyId"

    # A group with members on two formats counts once on each.
    formats = Map.new(meta.facets["fields"]["Format"], &{&1["label"], &1["count"]})
    assert formats == %{"Heftet" => 3, "Lydbok" => 1, "Ebok" => 1}

    {page, 4, _} = search(scope, collapse: "familyId", offset: 1, limit: 2)
    assert Enum.map(page, & &1.doc_id) == Enum.slice(expected, 1, 2)
  end
end
