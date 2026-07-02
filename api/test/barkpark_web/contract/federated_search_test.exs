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
end
