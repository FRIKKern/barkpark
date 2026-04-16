# api/test/barkpark_web/contract/analytics_test.exs
defmodule BarkparkWeb.Contract.AnalyticsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Content.upsert_schema(%{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}, "test")
    Content.upsert_schema(%{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []}, "test")

    Content.create_document("post", %{"doc_id" => "drafts.a1", "title" => "P1"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.a2", "title" => "P2"}, "test")
    Content.create_document("author", %{"doc_id" => "drafts.a3", "title" => "A1"}, "test")
    Content.publish_document("a1", "post", "test")
    :ok
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer barkpark-dev-token")
  end

  test "returns document counts by type", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert is_list(body["types"])
    post_stat = Enum.find(body["types"], &(&1["type"] == "post"))
    assert post_stat["total"] >= 2
    assert post_stat["published"] >= 1
    assert post_stat["drafts"] >= 1
  end

  test "returns total document count", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    body = Jason.decode!(resp.resp_body)
    assert body["total_documents"] >= 3
  end

  test "returns mutation activity", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/analytics/test")
    body = Jason.decode!(resp.resp_body)
    assert is_list(body["recent_activity"])
  end

  test "requires auth", %{conn: conn} do
    resp = get(conn, "/v1/data/analytics/test")
    assert resp.status == 401
  end
end
