defmodule Barkpark.StructureDeclaredDeskTest do
  @moduledoc """
  Gyldendal parity stage E3.2 — a per-dataset `deskStructure` document declares
  the MAIN desk tier: order, dividers, nested lists, filtered type lists and
  pinned singletons with a `documentId`. It replaces the curated + generic +
  settings host groups only; the …Rest census keeps surfacing every type the
  declaration forgot (the never-hide invariant), and a malformed document
  degrades to the default tree — never a blank desk.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure

  @dataset "declared-desk-#{System.unique_integer([:positive])}"

  defp schema!(name, title, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
          },
          extra
        ),
        @dataset
      )
  end

  # The agency desk, minus groupBy/tree (E3.3).
  @tree [
    %{
      "kind" => "singleton",
      "type" => "frontpage",
      "documentId" => "frontpage",
      "title" => "Forside",
      "icon" => "home"
    },
    %{"kind" => "divider"},
    %{
      "kind" => "list",
      "title" => "Utgivelser",
      "icon" => "book",
      "items" => [
        %{"kind" => "documentTypeList", "type" => "publication", "title" => "Alle utgivelser"},
        %{"kind" => "divider", "title" => "Med mangler"},
        %{
          "kind" => "documentTypeList",
          "type" => "publication",
          "title" => "Uten omslag",
          "filter" => %{"content.cover" => %{"is" => "null"}},
          "orderings" => [%{"field" => "title", "direction" => "asc"}]
        }
      ]
    },
    %{"kind" => "documentTypeList", "type" => "author", "title" => "Forfattere"},
    %{"kind" => "divider"},
    %{
      "kind" => "singleton",
      "type" => "siteSettings",
      "documentId" => "site-settings-main",
      "title" => "Nettstedsinnstillinger"
    }
  ]

  defp declare!(items) do
    schema!("deskStructure", "Desk", %{
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  setup do
    schema!("publication", "Utgivelse")
    schema!("author", "Forfatter")
    schema!("catalogueRow", "Katalograd (avledet)")
    schema!("frontpage", "Forside", %{"singleton" => true, "visibility" => "private"})

    schema!("siteSettings", "Nettstedsinnstillinger", %{
      "singleton" => true,
      "visibility" => "private"
    })

    :ok
  end

  defp ids(nodes), do: Enum.map(nodes, &{&1.type, &1.title})

  test "without a deskStructure document the default tree stands" do
    tree = Structure.build(@dataset)
    assert Enum.any?(tree.items, &(&1.id == "content-types"))
    assert Enum.any?(tree.items, &(&1.id == "settings"))
  end

  test "a published deskStructure declares the MAIN tier in its own order, with dividers, nested lists, filters and pinned singletons" do
    declare!(@tree)
    tree = Structure.build(@dataset)

    # The declared tier is ONE group at the head; plugin links, the Plugins
    # tier and …Rest follow it with their own positional dividers.
    main = Enum.take(tree.items, 6)

    assert ids(main) == [
             {:document, "Forside"},
             {:divider, nil},
             {:list, "Utgivelser"},
             {:document_type_list, "Forfattere"},
             {:divider, nil},
             {:document, "Nettstedsinnstillinger"}
           ]

    forside = Enum.at(main, 0)
    assert forside.type_name == "frontpage" and forside.doc_id == "frontpage"

    settings = List.last(main)
    assert settings.type_name == "siteSettings" and settings.doc_id == "site-settings-main"

    utg = Enum.at(main, 2)

    assert ids(utg.items) == [
             {:document_type_list, "Alle utgivelser"},
             {:divider, "Med mangler"},
             {:document_type_list, "Uten omslag"}
           ]

    uten = List.last(utg.items)
    assert uten.filter == %{"content.cover" => %{"is" => "null"}}
    assert uten.orderings == [%{"field" => "title", "direction" => "asc"}]

    # the curated / generic / settings host groups are gone…
    refute Enum.any?(tree.items, &(&1.id in ["content-types", "settings"]))
  end

  test "NEVER-HIDE: a type the declaration forgot still surfaces under …Rest" do
    declare!(@tree)

    # …Rest is a DOCUMENT census: a forgotten type with rows must surface.
    {:ok, _} =
      Content.create_document(
        "catalogueRow",
        %{"doc_id" => "cr-1", "title" => "row", "content" => %{}},
        @dataset
      )

    {:ok, _} = Content.publish_document("cr-1", "catalogueRow", @dataset)
    tree = Structure.build(@dataset)
    rest = Enum.find(tree.items, &(&1.id == "rest"))
    assert rest, "…Rest must exist because catalogueRow was not declared"
    assert Enum.any?(rest.items, &(&1.type_name == "catalogueRow"))

    refute Enum.any?(rest.items, &(&1.type_name == "publication")),
           "a declared type is claimed, not repeated in …Rest"
  end

  test "a malformed deskStructure degrades to the default tree, never a blank desk" do
    schema!("deskStructure", "Desk", %{
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{
          "doc_id" => "deskStructure",
          "title" => "Desk",
          "content" => %{"items" => [%{"kind" => "nonsense"}]}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    tree = Structure.build(@dataset)
    assert Enum.any?(tree.items, &(&1.id == "content-types"))
  end

  test "an UNPUBLISHED deskStructure draft does not apply (publish to apply)" do
    schema!("deskStructure", "Desk", %{
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => @tree}},
        @dataset
      )

    tree = Structure.build(@dataset)
    assert Enum.any?(tree.items, &(&1.id == "content-types"))
  end
end
