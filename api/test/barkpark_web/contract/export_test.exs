defmodule BarkparkWeb.Contract.ExportTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.e1", "title" => "One"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.e2", "title" => "Two"}, "test")
    Content.publish_document("e1", "post", "test")
    :ok
  end

  defp do_export(conn, dataset, params \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> get("/v1/data/export/#{dataset}", params)
  end

  test "exports all documents as NDJSON", %{conn: conn} do
    resp = do_export(conn, "test")
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"

    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert length(docs) >= 2
    assert Enum.all?(docs, &Map.has_key?(&1, "_id"))
    assert Enum.all?(docs, &Map.has_key?(&1, "_type"))
  end

  test "filters export by type", %{conn: conn} do
    resp = do_export(conn, "test", %{"type" => "post"})
    assert resp.status == 200
    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert Enum.all?(docs, &(&1["_type"] == "post"))
  end

  test "returns empty NDJSON for empty dataset", %{conn: conn} do
    resp = do_export(conn, "nonexistent")
    assert resp.status == 200
    assert resp.resp_body == ""
  end

  test "requires auth token", %{conn: conn} do
    resp = get(conn, "/v1/data/export/test")
    assert resp.status == 401
  end
end
