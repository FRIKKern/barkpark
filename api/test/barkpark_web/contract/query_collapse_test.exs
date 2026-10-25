defmodule BarkparkWeb.Contract.QueryCollapseTest do
  @moduledoc """
  task-3fbfafa3d1035ec2 — `collapse=<field>` on `GET /v1/data/query`: one
  document per value of the field, the first by the list's order, with each
  group's size in `result.collapse.counts`. A document with no value stands
  alone. `total` and facets count groups. gyldendal.no collapses the editions
  of one work (familyId).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"
  @token "barkpark-test-query-collapse"

  setup do
    Content.upsert_schema(
      %{"name" => "edition", "title" => "Edition", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, title, content} <- [
          {"co-a", "Co A1", %{"familyId" => "f1", "format" => "pocket"}},
          {"co-b", "Co B1", %{"familyId" => "f1", "format" => "hardcover"}},
          {"co-c", "Co C2", %{"familyId" => "f2", "format" => "pocket"}},
          {"co-d", "Co D", %{"format" => "ebook"}},
          {"co-e", "Co E", %{"format" => "pocket"}}
        ] do
      {:ok, _} =
        Content.create_document(
          "edition",
          Map.merge(%{"_id" => id, "title" => title}, content),
          @ds
        )

      {:ok, _} = Content.publish_document(id, "edition", @ds)
    end

    :ok
  end

  defp result(conn, query) do
    conn
    |> get("/v1/data/query/#{@ds}/edition?filter[title][startsWith]=Co&" <> query)
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ids(r), do: Enum.map(r["documents"], & &1["_id"])

  test "one document per value, the first by order, with group sizes", %{conn: conn} do
    r = result(conn, "collapse=familyId&order=title:asc")
    assert ids(r) == ["co-a", "co-c", "co-d", "co-e"]

    assert r["collapse"] == %{
             "field" => "familyId",
             "counts" => %{"co-a" => 2, "co-c" => 1, "co-d" => 1, "co-e" => 1}
           }

    assert ids(result(conn, "collapse=familyId&order=title:desc")) == [
             "co-e",
             "co-d",
             "co-c",
             "co-b"
           ]
  end

  test "total, paging and facets count groups", %{conn: conn} do
    r = result(conn, "collapse=familyId&order=title:asc&count=true&facet=format&limit=2&offset=2")
    assert ids(r) == ["co-d", "co-e"]
    assert r["total"] == 4
    assert r["hasMore"] == false

    assert Map.new(r["facets"]["fields"]["format"], &{&1["label"], &1["count"]}) ==
             %{"pocket" => 3, "ebook" => 1}
  end

  test "the filter runs before the collapse", %{conn: conn} do
    r = result(conn, "collapse=familyId&filter[format][eq]=hardcover&count=true")
    assert ids(r) == ["co-b"]
    assert r["total"] == 1
    assert r["collapse"]["counts"] == %{"co-b" => 1}
  end

  test "under drafts a document is grouped by its draft", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "edition",
        %{"_id" => "co-c", "title" => "Co C2", "familyId" => "f1", "format" => "pocket"},
        @ds
      )

    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "query-collapse",
        @ds,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    r =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get(
        "/v1/data/query/#{@ds}/edition?perspective=drafts&filter[title][startsWith]=Co&collapse=familyId&order=title:asc&count=true"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert ids(r) == ["co-a", "co-d", "co-e"]
    assert r["total"] == 3
    assert r["collapse"]["counts"]["co-a"] == 3
  end

  test "without collapse nothing changes", %{conn: conn} do
    r = result(conn, "order=title:asc")
    assert length(r["documents"]) == 5
    refute Map.has_key?(r, "collapse")
  end

  test "a malformed collapse is a 400 naming the parameter", %{conn: conn} do
    for q <- ["collapse=a-b", "collapse[]=familyId", "collapse=a.b"] do
      body = conn |> get("/v1/data/query/#{@ds}/edition?" <> q) |> json_response(400)
      assert body["error"]["code"] == "malformed", q
      assert body["error"]["details"]["parameter"] == "collapse", q
    end
  end
end
