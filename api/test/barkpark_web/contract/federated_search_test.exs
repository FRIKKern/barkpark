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

  test "array-shaped ?surfaces[] param falls back to default surfaces instead of 500",
       %{conn: conn} do
    resp = get(conn, "/v1/search/test?q=federated&surfaces[]=documents")

    assert resp.status == 200
    body = json_response(resp, 200)
    # fail-soft: both default surfaces present, request did not crash
    assert is_map(body["results"]["documents"])
    assert is_map(body["results"]["media"])
  end

  test "duplicate ?surfaces are deduped — a surface is queried exactly once",
       %{conn: conn} do
    resp = get(conn, "/v1/search/test?q=federated&surfaces=documents,documents")

    assert resp.status == 200
    body = json_response(resp, 200)
    # The echoed surfaces list collapses the duplicate, so the surface is only
    # fanned out (and its hits only counted) once.
    assert body["surfaces"] == ["documents"]
    assert map_size(body["results"]) == 1
    assert is_map(body["results"]["documents"])
  end
end
