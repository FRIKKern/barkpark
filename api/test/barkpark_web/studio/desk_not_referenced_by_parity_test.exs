defmodule BarkparkWeb.Studio.DeskNotReferencedByParityTest do
  @moduledoc """
  task-f343d828861d7a7a — a declared desk list filtered with
  `{_id: {notReferencedBy: <type>}}` (the Agency desk's «Kategorier uten
  utgivelser») lists the same rows in the LiveView Studio (PaneBuilder) as an
  external Studio reads from `GET /v1/data/query` with the filter the resolved
  desk carries; `referencedBy` likewise, and the two split the type.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @ds "notref-parity-#{System.unique_integer([:positive])}"
  @token "barkpark-notref-parity-token"

  defp schema!(name, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
  end

  defp doc!(type, id, content) do
    {:ok, _} =
      Content.create_document(type, %{"doc_id" => id, "title" => id, "content" => content}, @ds)

    {:ok, _} = Content.publish_document(id, type, @ds)
  end

  setup do
    schema!("category", [%{"name" => "title", "type" => "string"}])

    schema!("publication", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "category", "type" => "reference", "refType" => "category"}
    ])

    for id <- ~w(cat-a cat-b cat-c), do: doc!("category", id, %{})
    doc!("publication", "pub-1", %{"category" => %{"_ref" => "cat-a"}})
    doc!("publication", "pub-2", %{"category" => %{"_ref" => "cat-c"}})

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @ds
      )

    items =
      for {id, op} <- [{"uten", "notReferencedBy"}, {"med", "referencedBy"}] do
        %{
          "kind" => "documentTypeList",
          "id" => id,
          "type" => "category",
          "title" => id,
          "filter" => %{"_id" => %{op => "publication"}}
        }
      end

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @ds
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @ds)
    {:ok, _} = Barkpark.Auth.create_token(@token, "notref", @ds, ["read", "write", "admin"])
    :ok
  end

  defp liveview_rows(list) do
    {panes, _} = PaneBuilder.build(@ds, [list])
    pane = List.last(panes)
    refute pane[:filter_error]
    pane.items |> Enum.filter(&(&1[:type] == :doc)) |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp api_rows(conn, list) do
    node = Enum.find(Structure.build(@ds).items, &(&1.id == list))
    [{op, type}] = Map.to_list(node.filter["_id"])

    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get("/v1/data/query/#{@ds}/category?perspective=published&filter[_id][#{op}]=#{type}")
    |> json_response(200)
    |> get_in(["result", "documents"])
    |> Enum.map(& &1["_id"])
    |> Enum.sort()
  end

  test "notReferencedBy and referencedBy give the same rows in LiveView and over the query API",
       %{conn: conn} do
    assert liveview_rows("uten") == ["cat-b"]
    assert api_rows(conn, "uten") == ["cat-b"]
    assert liveview_rows("med") == ["cat-a", "cat-c"]
    assert api_rows(conn, "med") == ["cat-a", "cat-c"]
  end
end
