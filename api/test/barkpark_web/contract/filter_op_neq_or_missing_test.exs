defmodule BarkparkWeb.Contract.FilterOpNeqOrMissingTest do
  @moduledoc """
  task-728fb2adbd900f8f — `neqOrMissing` is GROQ's `!=`: a document without the
  field, or with null, counts as not equal. gyldendal.no's desk filters with
  `isHidden != true` in 8 items (Synlige serier: Sanity 418 of 459, Barkpark's
  `neq` 1). `neq` keeps leaving those documents out, as documented.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @ds "test"

  setup do
    Content.upsert_schema(
      %{"name" => "series", "title" => "Serie", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, content} <- [
          {"s-hidden", %{"isHidden" => true, "meta" => %{"hidden" => true}}},
          {"s-shown", %{"isHidden" => false, "meta" => %{"hidden" => false}}},
          {"s-missing", %{}},
          {"s-null", %{"isHidden" => nil, "meta" => %{}}}
        ] do
      {:ok, _} =
        Content.create_document("series", Map.merge(%{"_id" => id, "title" => "S"}, content), @ds)

      {:ok, _} = Content.publish_document(id, "series", @ds)
    end

    :ok
  end

  defp ids(conn, query) do
    %{"result" => body} =
      conn |> get("/v1/data/query/#{@ds}/series?filter[title]=S&" <> query) |> json_response(200)

    body["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()
  end

  test "neqOrMissing keeps a missing or null field; neq leaves it out", %{conn: conn} do
    assert ids(conn, "filter[isHidden][neqOrMissing]=true") == ["s-missing", "s-null", "s-shown"]
    assert ids(conn, "filter[isHidden][neq]=true") == ["s-shown"]
  end

  test "neqOrMissing on the title column keeps an untitled document", %{conn: conn} do
    {:ok, _} =
      Content.create_document("series", %{"_id" => "s-untitled", "isHidden" => false}, @ds)

    {:ok, _} = Content.publish_document("s-untitled", "series", @ds)

    %{"result" => body} =
      conn
      |> get("/v1/data/query/#{@ds}/series?filter[isHidden]=false&filter[title][neqOrMissing]=S")
      |> json_response(200)

    assert Enum.map(body["documents"], & &1["_id"]) == ["s-untitled"]
  end

  test "neqOrMissing on a nested path", %{conn: conn} do
    assert ids(conn, "filter[meta.hidden][neqOrMissing]=true") == [
             "s-missing",
             "s-null",
             "s-shown"
           ]
  end

  test "a desk list filters with it, a JSON boolean value included" do
    desk_filter = %{"content.isHidden" => %{"neqOrMissing" => true}}
    assert :ok = Content.Query.check_filter("series", @ds, desk_filter, [])

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

    items = [
      %{
        "kind" => "documentTypeList",
        "id" => "synlige",
        "type" => "series",
        "title" => "Synlige serier",
        "filter" => desk_filter
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @ds
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @ds)

    {panes, _} = PaneBuilder.build(@ds, ["synlige"])
    pane = List.last(panes)
    refute pane[:filter_error]
    assert pane.items |> Enum.map(& &1.id) |> Enum.sort() == ["s-missing", "s-null", "s-shown"]
  end

  test "it is a documented operator: the door accepts it" do
    assert "neqOrMissing" in Content.Query.valid_filter_ops()
  end
end
