defmodule BarkparkWeb.Contract.SearchSynonymsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Search.Synonyms

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.syn1", "title" => "Elixir Phoenix Guide"},
      "test"
    )

    Content.publish_document("syn1", "post", "test")
    :ok
  end

  test "admin can create synonym and search expands via synonym target", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/data/search/test/synonyms", %{"from" => "hero", "to" => "phoenix"})

    assert json_response(conn, 200)["result"]["from"] == "hero"

    resp =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test", %{"q" => "hero"})

    body = json_response(resp, 200)
    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "Elixir Phoenix Guide"
  end

  test "admin can list and delete synonyms", %{conn: conn} do
    {:ok, row} = Synonyms.create("documents", "test", %{"from" => "x", "to" => "y"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test/synonyms")

    ids = Enum.map(json_response(conn, 200)["result"], & &1["id"])
    assert row.id in ids

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> delete("/v1/data/search/test/synonyms/#{row.id}")

    assert json_response(conn, 200)["ok"] == true
  end

  test "insights include synonymCandidates", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test/insights")

    body = json_response(conn, 200)
    assert is_list(body["result"]["synonymCandidates"])
  end
end
