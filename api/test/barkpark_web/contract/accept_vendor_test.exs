defmodule BarkparkWeb.Contract.AcceptVendorTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {:ok, _} = Content.create_document("post", %{"_id" => "v1", "title" => "Hi"}, "test")
    {:ok, _} = Content.publish_document("v1", "post", "test")
    :ok
  end

  test "query with vendor Accept returns envelope + vendor content-type", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/vnd.barkpark+json")
      |> get("/v1/data/query/test/post")

    assert resp.status == 200

    [ct | _] = Plug.Conn.get_resp_header(resp, "content-type")
    assert String.starts_with?(ct, "application/vnd.barkpark+json")

    body = Jason.decode!(resp.resp_body)
    for key <- ~w(result syncTags ms etag schemaHash) do
      assert Map.has_key?(body, key), "envelope missing key: #{key}"
    end
  end

  test "query with plain application/json keeps json content-type (regression)", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/v1/data/query/test/post")

    assert resp.status == 200
    [ct | _] = Plug.Conn.get_resp_header(resp, "content-type")
    assert String.starts_with?(ct, "application/json")
  end

  test "query with unsupported Accept returns 406", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/xml")
      |> get("/v1/data/query/test/post")

    assert resp.status == 406
  end

  test "doc endpoint with vendor Accept also returns vendor envelope", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/vnd.barkpark+json")
      |> get("/v1/data/doc/test/post/v1")

    assert resp.status == 200

    [ct | _] = Plug.Conn.get_resp_header(resp, "content-type")
    assert String.starts_with?(ct, "application/vnd.barkpark+json")

    body = Jason.decode!(resp.resp_body)
    assert Map.has_key?(body, "result")
    assert body["result"]["_id"] == "v1"
  end
end
