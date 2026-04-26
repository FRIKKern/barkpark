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
    %{"result" => body} = conn |> get("/v1/data/query/test/post?limit=2") |> json_response(200)
    assert length(body["documents"]) == 2
    assert body["count"] == 2
    assert body["limit"] == 2
  end

  test "offset paginates", %{conn: conn} do
    %{"result" => b1} =
      conn |> get("/v1/data/query/test/post?limit=2&offset=0") |> json_response(200)

    %{"result" => b2} =
      conn |> get("/v1/data/query/test/post?limit=2&offset=2") |> json_response(200)

    ids1 = Enum.map(b1["documents"], & &1["_id"]) |> MapSet.new()
    ids2 = Enum.map(b2["documents"], & &1["_id"]) |> MapSet.new()
    assert MapSet.disjoint?(ids1, ids2)
  end

  test "filter[title]=T3 works", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter[title]=T3") |> json_response(200)

    assert length(body["documents"]) == 1
    assert hd(body["documents"])["title"] == "T3"
  end

  test "order=_createdAt:asc reverses default", %{conn: conn} do
    %{"result" => desc} = conn |> get("/v1/data/query/test/post") |> json_response(200)

    %{"result" => asc} =
      conn |> get("/v1/data/query/test/post?order=_createdAt:asc") |> json_response(200)

    assert Enum.map(desc["documents"], & &1["_id"]) ==
             Enum.reverse(Enum.map(asc["documents"], & &1["_id"]))
  end

  test "envelope carries result + syncTags + ms + etag + schemaHash", %{conn: conn} do
    resp = get(conn, "/v1/data/query/test/post")
    body = json_response(resp, 200)

    for key <- ~w(result syncTags ms etag schemaHash) do
      assert Map.has_key?(body, key), "envelope missing key: #{key}"
    end

    assert is_map(body["result"])
    assert is_list(body["syncTags"])
    assert is_integer(body["ms"])
    assert is_binary(body["etag"])
    assert is_binary(body["schemaHash"])

    [header_etag | _] = Plug.Conn.get_resp_header(resp, "etag")
    assert header_etag == ~s("#{body["etag"]}")

    type_tag = "bp:ds:test:type:post"
    assert type_tag in body["syncTags"]
  end

  test "If-None-Match matching etag returns 304", %{conn: conn} do
    resp1 = get(conn, "/v1/data/query/test/post")
    body1 = json_response(resp1, 200)
    [etag_header | _] = Plug.Conn.get_resp_header(resp1, "etag")

    resp2 =
      conn
      |> put_req_header("if-none-match", etag_header)
      |> get("/v1/data/query/test/post")

    assert resp2.status == 304
    assert resp2.resp_body == ""
    assert is_binary(body1["etag"])
  end
end
