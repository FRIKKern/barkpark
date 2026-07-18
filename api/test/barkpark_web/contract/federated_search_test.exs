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

  # Wiring proof: federated document hits are rendered through
  # render_many_by_type(schema_resolver, caller_context), so a `private` field is
  # DROPPED for the anonymous federated caller. Without the per-type schema
  # resolver this multi-type surface would leak non-encrypted private fields (the
  # schema-free guard alone only catches ciphertext).
  test "anonymous federated search redacts a private field on a document hit",
       %{conn: conn} do
    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "ssn", "type" => "string", "private" => true}
        ]
      },
      "test"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.fsec", "title" => "Redacted Falcon Post", "ssn" => "SSN-999"},
      "test"
    )

    Content.publish_document("fsec", "post", "test")

    body =
      get(conn, "/v1/search/test", %{"q" => "falcon", "surfaces" => "documents"})
      |> json_response(200)

    hits = body["results"]["documents"]["hits"]
    hit = Enum.find(hits, &(&1["_id"] == "fsec"))

    assert hit, "expected the published post to appear in the federated hits"
    assert hit["title"] == "Redacted Falcon Post"
    refute Map.has_key?(hit, "ssn")
    # Belt-and-braces: the secret value must not appear ANYWHERE in the payload.
    refute body |> Jason.encode!() |> String.contains?("SSN-999")
  end

  # AXI R3: the federated DOCUMENTS surface adopts the shared HitEnvelope
  # builder via the re-keying adapter (documents→hits, count→total), so
  # ?view=brief yields the same brief cards as REST/loopback/WS. The media
  # surface is out of scope (AssetResponse renders, not documents).
  test "?view=brief re-keys brief hit cards onto the documents surface; media is untouched",
       %{conn: conn} do
    resp =
      get(conn, "/v1/search/test", %{
        "q" => "phoenix",
        "surfaces" => "documents,media",
        "view" => "brief"
      })

    assert resp.status == 200
    body = json_response(resp, 200)

    docs_payload = body["results"]["documents"]
    assert docs_payload["total"] >= 1
    # Surface payload keeps its historical key set (no correctedTo/facets/
    # truncation/query — those never existed on this surface).
    assert Enum.sort(Map.keys(docs_payload)) ==
             ~w(highlights hits parsedQuery recovery total)

    [card | _] = docs_payload["hits"]
    assert Enum.sort(Map.keys(card)) == ~w(highlights id slug snippet title type)
    assert card["type"] == "post"
    assert card["snippet"] =~ "Phoenix"
    refute Map.has_key?(card, "_id")

    # Media surface unchanged by the view param.
    assert is_map(body["results"]["media"])
  end
end
