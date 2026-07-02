defmodule BarkparkWeb.Contract.FederatedSearchTest do
  use BarkparkWeb.ConnCase, async: false

  # Locks the anonymous federated-search `limit` clamp (bound_limit/1): a client
  # can't fan an unbounded row count out to both surfaces via `?limit=<huge>`.
  doctest BarkparkWeb.FederatedSearchController, only: [bound_limit: 1]

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.f1", "title" => "Federated Phoenix Post"},
      "test"
    )

    Content.publish_document("f1", "post", "test")
    :ok
  end

  test "federated search returns documents and media surfaces", %{conn: conn} do
    resp =
      get(conn, "/v1/search/test", %{
        "q" => "phoenix",
        "surfaces" => "documents,media",
        "limit" => "5"
      })

    assert resp.status == 200
    body = json_response(resp, 200)
    assert body["results"]["documents"]["total"] >= 1
    assert is_list(body["results"]["documents"]["hits"])
    assert is_map(body["results"]["media"])
    assert is_integer(body["ms"])
  end

  # Regression: parse_surfaces had only nil + is_binary clauses, so Phoenix's
  # ?surfaces[]=documents (a list) / ?surfaces[bad]=1 (a map) raised a
  # FunctionClauseError → 500 on this anonymous endpoint. Now both fall back to
  # the default surfaces and return 200.
  test "anonymous ?surfaces[]=documents (list) falls back to defaults, not a 500",
       %{conn: conn} do
    resp = get(conn, "/v1/search/test", %{"q" => "phoenix", "surfaces" => ["documents"]})

    assert resp.status == 200
    body = json_response(resp, 200)
    assert body["surfaces"] == ["documents", "media"]
    assert is_map(body["results"]["documents"])
    assert is_map(body["results"]["media"])
  end

  test "anonymous ?surfaces[bad]=1 (map) falls back to defaults, not a 500",
       %{conn: conn} do
    resp = get(conn, "/v1/search/test", %{"q" => "phoenix", "surfaces" => %{"bad" => "1"}})

    assert resp.status == 200
    body = json_response(resp, 200)
    assert body["surfaces"] == ["documents", "media"]
  end
end
