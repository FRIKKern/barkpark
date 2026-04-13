defmodule BarkparkWeb.Contract.QueryTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    for i <- 1..5 do
      {:ok, _} = Content.create_document("post", %{"_id" => "q#{i}", "title" => "T#{i}"}, "test")
      {:ok, _} = Content.publish_document("q#{i}", "post", "test")
    end

    :ok
  end

  test "limit caps page size", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?limit=2") |> json_response(200)
    assert length(body["documents"]) == 2
    assert body["count"] == 2
    assert body["limit"] == 2
  end

  test "offset paginates", %{conn: conn} do
    b1 = conn |> get("/v1/data/query/test/post?limit=2&offset=0") |> json_response(200)
    b2 = conn |> get("/v1/data/query/test/post?limit=2&offset=2") |> json_response(200)
    ids1 = Enum.map(b1["documents"], & &1["_id"]) |> MapSet.new()
    ids2 = Enum.map(b2["documents"], & &1["_id"]) |> MapSet.new()
    assert MapSet.disjoint?(ids1, ids2)
  end

  test "filter[title]=T3 works", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?filter[title]=T3") |> json_response(200)
    assert length(body["documents"]) == 1
    assert hd(body["documents"])["title"] == "T3"
  end

  test "order=_createdAt:asc reverses default", %{conn: conn} do
    desc = conn |> get("/v1/data/query/test/post") |> json_response(200)
    asc = conn |> get("/v1/data/query/test/post?order=_createdAt:asc") |> json_response(200)
    assert Enum.map(desc["documents"], & &1["_id"]) == Enum.reverse(Enum.map(asc["documents"], & &1["_id"]))
  end
end
