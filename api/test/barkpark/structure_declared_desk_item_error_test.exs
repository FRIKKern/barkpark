defmodule Barkpark.StructureDeclaredDeskItemErrorTest do
  @moduledoc """
  task-d99d878b061b435a — one declared desk item that cannot be built never
  drops the declared desk. Before, a `referencedBy product` filter over a
  product schema with a multi-type `arrayOf` field raised, `declared_desk/3`
  rescued, and all of gyldendal.no's 179 items fell back to the default desk
  with only a log line. Now the filter works, and an item that still cannot be
  built is an error node in its own place, its reason in `error`, which
  `GET /v1/structure/:dataset` returns.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure

  @dataset "desk-item-error-#{System.unique_integer([:positive])}"
  @token "barkpark-desk-item-error-token"

  defp schema!(name, fields, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"} | fields]
          },
          extra
        ),
        @dataset
      )
  end

  defp doc!(type, id, content) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => id, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)
  end

  defp declare!(items) do
    schema!("deskStructure", [%{"name" => "items", "title" => "Items", "type" => "array"}], %{
      "singleton" => true,
      "visibility" => "private"
    })

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Innhold", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  setup do
    schema!("series", [])
    schema!("department", [])

    schema!("product", [
      %{
        "name" => "tilleggsressurser",
        "type" => "arrayOf",
        "of" => [
          %{
            "name" => "lenke",
            "type" => "composite",
            "fields" => [%{"name" => "url", "type" => "url"}]
          },
          %{
            "name" => "notat",
            "type" => "composite",
            "fields" => [%{"name" => "text", "type" => "string"}]
          }
        ]
      },
      %{"name" => "department", "type" => "reference", "to" => [%{"type" => "department"}]},
      %{
        "name" => "series",
        "type" => "arrayOf",
        "of" => %{
          "type" => "composite",
          "fields" => [%{"name" => "series", "type" => "reference", "to" => ["series"]}]
        }
      }
    ])

    doc!("department", "dep.a", %{})
    doc!("department", "dep.b", %{})
    doc!("series", "series.used", %{})
    doc!("series", "series.idle", %{})

    doc!("product", "p1", %{
      "department" => %{"_ref" => "dep.a"},
      "series" => [%{"series" => %{"_ref" => "series.used"}}]
    })

    :ok
  end

  @items [
    %{
      "kind" => "list",
      "title" => "Serier",
      "items" => [
        %{"kind" => "documentTypeList", "type" => "series", "title" => "Alle serier"},
        %{
          "kind" => "documentTypeList",
          "type" => "series",
          "title" => "Med produkter",
          "filter" => %{"_id" => %{"referencedBy" => "product"}}
        },
        %{
          "kind" => "documentTypeList",
          "type" => "series",
          "title" => "Ikke brukt på produkter",
          "filter" => %{"_id" => %{"notReferencedBy" => "product"}}
        },
        %{
          "kind" => "documentTypeList",
          "type" => "series",
          "title" => "Skrivefeil",
          "filter" => %{"_id" => %{"referencedBy" => "produkt"}}
        }
      ]
    },
    %{
      "kind" => "groupBy",
      "title" => "Etter virksomhet",
      "type" => "product",
      "over" => "department",
      "by" => "content.department",
      "overFilter" => %{"_id" => %{"referencedBy" => "product"}}
    },
    %{
      "kind" => "groupBy",
      "id" => "broken-group",
      "title" => "Etter feltet som ikke finnes",
      "type" => "product",
      "over" => "department",
      "by" => "content.department",
      "overFilter" => %{"_id" => %{"referencedBy" => "product.nope"}}
    },
    %{"kind" => "documentTypeList", "type" => "product", "title" => "Produkter"}
  ]

  defp declared(tree), do: Enum.take(tree.items, 4)

  test "referencedBy product builds, and a bad item leaves the rest of the declared desk" do
    declare!(@items)
    tree = Structure.build(@dataset)

    # The declared tier stands: no fallback to the default host groups.
    refute Enum.any?(tree.items, &(&1.id in ["content-types", "settings"]))

    [serier, etter, broken, produkter] = declared(tree)

    assert {serier.title, etter.title, produkter.title} ==
             {"Serier", "Etter virksomhet", "Produkter"}

    # groupBy over departments a product points at: only dep.a.
    assert Enum.map(etter.items, & &1.title) == ["dep.a"]
    assert etter.error == nil

    # The item that cannot be built keeps its place, with the reason.
    assert broken.id == "broken-group"
    assert broken.type == :list and broken.items == []
    assert broken.error =~ "overFilter"
    assert broken.error =~ "names no field \"nope\""

    [alle, med, ikke, skrivefeil] = serier.items
    assert Enum.map([alle, med, ikke], & &1.error) == [nil, nil, nil]
    assert skrivefeil.type == :document_type_list
    assert skrivefeil.error =~ "names no document type in this dataset: \"produkt\""
  end

  test "an item that raises while it is built becomes an error node" do
    # A groupBy whose `over` reads with a filter op the builder refuses.
    declare!([
      %{"kind" => "documentTypeList", "type" => "series", "title" => "Serier"},
      %{
        "kind" => "groupBy",
        "title" => "Ugyldig",
        "type" => "product",
        "over" => "department",
        "by" => "content.department",
        "overFilter" => %{"title" => %{"referencedBy" => "product"}}
      }
    ])

    [serier, ugyldig] = tree_head(2)
    assert serier.title == "Serier" and serier.error == nil
    assert ugyldig.title == "Ugyldig"
    assert ugyldig.error =~ "referencedBy"
  end

  defp tree_head(n), do: Enum.take(Structure.build(@dataset).items, n)

  test "the structure response names the failing item and the reason", %{conn: conn} do
    declare!(@items)
    {:ok, _} = Barkpark.Auth.create_token(@token, "desk", @dataset, ["read", "write", "admin"])

    root =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/structure/#{@dataset}")
      |> json_response(200)
      |> Map.fetch!("structure")

    broken = Enum.find(root["items"], &(&1["id"] == "broken-group"))
    assert broken["title"] == "Etter feltet som ikke finnes"
    assert broken["error"] =~ "names no field \"nope\""

    serier = Enum.find(root["items"], &(&1["title"] == "Serier"))
    med = Enum.find(serier["items"], &(&1["title"] == "Med produkter"))
    refute Map.has_key?(med, "error")
  end

  test "the desk pane lists what the filter selects" do
    declare!(@items)
    tree = Structure.build(@dataset)
    [serier | _] = declared(tree)
    [_, med, ikke, _] = serier.items

    list = fn node ->
      "series"
      |> Content.list_documents(@dataset, perspective: :drafts, filter_map: node.filter)
      |> Enum.map(& &1.title)
    end

    assert list.(med) == ["series.used"]
    assert list.(ikke) == ["series.idle"]
  end
end
