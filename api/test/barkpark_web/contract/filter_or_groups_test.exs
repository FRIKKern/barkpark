defmodule BarkparkWeb.Contract.FilterOrGroupsTest do
  @moduledoc """
  task-02d4488c460185c0 — `filter[$or][i][field][op]=value` on
  `GET /v1/data/query`: a row matches when ANY branch matches; each branch is
  an ordinary filter map, ANDed inside itself. The group combines with the
  other (ANDed) filters, sort and paging. A malformed group is a 400
  `invalid_filter` naming the group or the branch. gyldendal.no's desk ORs
  across fields (`isVisible == true || !defined(isVisible)`, a date of birth or
  of death equal to 0001-01-01).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.PaneBuilder

  @ds "test"

  setup do
    Content.upsert_schema(
      %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, content} <- [
          {"or-a", %{"born" => "0001-01-01", "died" => "1990-05-05", "isVisible" => true}},
          {"or-b", %{"born" => "1950-01-01", "died" => "0001-01-01", "isVisible" => false}},
          {"or-c", %{"born" => "1960-01-01", "isVisible" => true}},
          {"or-d", %{"born" => "1970-01-01"}}
        ] do
      {:ok, _} =
        Content.create_document(
          "person",
          Map.merge(%{"_id" => id, "title" => "Or " <> id}, content),
          @ds
        )

      {:ok, _} = Content.publish_document(id, "person", @ds)
    end

    :ok
  end

  defp ids(conn, query) do
    conn
    |> get(
      "/v1/data/query/#{@ds}/person?perspective=published&filter[title][startsWith]=Or&" <> query
    )
    |> json_response(200)
    |> get_in(["result", "documents"])
    |> Enum.map(& &1["_id"])
  end

  defp error(conn, query) do
    conn
    |> get("/v1/data/query/#{@ds}/person?" <> query)
    |> json_response(400)
    |> Map.fetch!("error")
  end

  test "a row matches any branch: a date of birth or of death equal to 0001-01-01", %{conn: conn} do
    q = "filter[$or][0][born][eq]=0001-01-01&filter[$or][1][died][eq]=0001-01-01&order=_id:asc"
    assert ids(conn, q) == ["or-a", "or-b"]
  end

  test "visible or missing (Sanity's isVisible == true || !defined(isVisible))", %{conn: conn} do
    q = "filter[$or][0][isVisible][eq]=true&filter[$or][1][isVisible][is]=null&order=_id:asc"
    assert ids(conn, q) == ["or-a", "or-c", "or-d"]
  end

  test "a branch ANDs its own clauses, and the group ANDs with the other filters", %{conn: conn} do
    q =
      "filter[$or][0][isVisible][eq]=true&filter[$or][0][born][eq]=1960-01-01" <>
        "&filter[$or][1][died][eq]=0001-01-01&filter[born][neq]=1950-01-01&order=_id:asc"

    assert ids(conn, q) == ["or-c"]
  end

  test "sort and paging apply to the matched set", %{conn: conn} do
    q = "filter[$or][0][isVisible][eq]=true&filter[$or][1][isVisible][is]=null&order=_id:desc"
    assert ids(conn, q <> "&limit=2") == ["or-d", "or-c"]
    assert ids(conn, q <> "&limit=2&offset=2") == ["or-a"]
  end

  test "a malformed group is a 400 naming the group or the branch", %{conn: conn} do
    e = error(conn, "filter[$or]=born%3D1")
    assert e["code"] == "invalid_filter" and e["details"]["field"] == "$or"

    e = error(conn, "filter[$or][0][born][bogus]=1")
    assert e["code"] == "invalid_filter"
    assert e["message"] =~ "in filter[$or][0]"

    e = error(conn, "filter[$and][0][born][eq]=1")
    assert e["details"]["field"] == "$and"
  end

  test "a declared desk list can filter with an $or group" do
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

    filter = %{
      "$or" => [
        %{"content.born" => %{"eq" => "0001-01-01"}},
        %{"content.died" => %{"eq" => "0001-01-01"}}
      ]
    }

    assert :ok = Content.Query.check_filter("person", @ds, filter, [])

    items = [
      %{
        "kind" => "documentTypeList",
        "id" => "feil",
        "type" => "person",
        "title" => "Feil",
        "filter" => filter
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @ds
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @ds)

    assert Enum.find(Structure.build(@ds).items, &(&1.id == "feil")).error == nil
    {panes, _} = PaneBuilder.build(@ds, ["feil"])
    rows = for %{type: :doc} = i <- List.last(panes).items, do: i.id
    assert Enum.sort(rows) == ["or-a", "or-b"]
  end
end
