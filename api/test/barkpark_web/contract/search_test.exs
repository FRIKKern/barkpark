defmodule BarkparkWeb.Contract.SearchTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.upsert_schema(%{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []}, "test")

    Content.create_document("post", %{"doc_id" => "drafts.s1", "title" => "Elixir Phoenix Guide"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.s2", "title" => "React Tutorial"}, "test")
    Content.create_document("author", %{"doc_id" => "drafts.s3", "title" => "Phoenix Wright"}, "test")

    Content.publish_document("s1", "post", "test")
    Content.publish_document("s2", "post", "test")
    Content.publish_document("s3", "author", "test")
    :ok
  end

  test "searches by title across types", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix"})
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 2
    titles = Enum.map(body["documents"], & &1["title"])
    assert "Elixir Phoenix Guide" in titles
    assert "Phoenix Wright" in titles
  end

  test "filters search by type", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "type" => "post"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
    assert hd(body["documents"])["_type"] == "post"
  end

  test "returns empty list for no matches", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "zzzznoexist"})
    body = Jason.decode!(resp.resp_body)
    assert body["documents"] == []
    assert body["count"] == 0
  end

  test "requires q parameter", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test")
    assert resp.status == 400
  end

  test "respects perspective (defaults to published)", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "Elixir"})
    body = Jason.decode!(resp.resp_body)
    docs = body["documents"]
    assert Enum.all?(docs, &(&1["_draft"] == false))
  end

  test "limits results", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "limit" => "1"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
  end
end
