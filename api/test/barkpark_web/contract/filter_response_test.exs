defmodule BarkparkWeb.Contract.FilterResponseTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {:ok, _} = Content.create_document("post", %{"_id" => "fr1", "title" => "A"}, "test")
    {:ok, _} = Content.publish_document("fr1", "post", "test")

    :ok
  end

  test "default GET /v1/data/query/test/post wraps in %{result: ...}", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post") |> json_response(200)

    for key <- ~w(result syncTags ms etag schemaHash) do
      assert Map.has_key?(body, key), "envelope missing key: #{key}"
    end

    assert is_list(body["result"]["documents"])
  end

  test "GET ?filterresponse=false returns raw body (no envelope)", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?filterresponse=false") |> json_response(200)

    refute Map.has_key?(body, "result")
    refute Map.has_key?(body, "syncTags")
    refute Map.has_key?(body, "schemaHash")
    assert is_list(body["documents"])
  end

  test "Accept header +filterresponse=false also suppresses", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept", "application/vnd.barkpark+filterresponse=false")
      |> get("/v1/data/query/test/post")
      |> json_response(200)

    refute Map.has_key?(body, "result")
    assert is_list(body["documents"])
  end

  test "GET ?filterresponse=true still wraps", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?filterresponse=true") |> json_response(200)

    assert Map.has_key?(body, "result")
    assert is_list(body["result"]["documents"])
  end

  test "doc endpoint: GET /v1/data/doc/test/post/fr1?filterresponse=false returns the bare document",
       %{conn: conn} do
    body = conn |> get("/v1/data/doc/test/post/fr1?filterresponse=false") |> json_response(200)

    refute Map.has_key?(body, "result")
    assert body["_id"] == "fr1"
    assert body["_type"] == "post"
  end
end
