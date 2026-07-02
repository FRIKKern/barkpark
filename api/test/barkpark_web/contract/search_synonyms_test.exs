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

  # §9 error-envelope conformance: every error body carries a canonical `code`
  # + `request_id` (docs/api-v1.md §9) — the bp CLI + JS SDK key exit codes /
  # classification SOLELY on error.code. These sites used to emit a bare
  # %{error: %{message: ...}} with neither.

  defp assert_error_envelope(body, expected_code) do
    assert body["error"]["code"] == expected_code
    assert is_binary(body["error"]["request_id"])
    assert body["error"]["request_id"] != ""
  end

  test "document promote synonym missing fields → validation_failed envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/data/search/test/synonyms/promote", %{})

    assert_error_envelope(json_response(conn, 422), "validation_failed")
  end

  test "document create synonym missing fields → validation_failed envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/data/search/test/synonyms", %{})

    assert_error_envelope(json_response(conn, 422), "validation_failed")
  end

  test "document delete unknown synonym → not_found envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> delete("/v1/data/search/test/synonyms/does-not-exist")

    assert_error_envelope(json_response(conn, 404), "not_found")
  end

  test "media promote synonym missing fields → validation_failed envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/media/test/search/synonyms/promote", %{})

    assert_error_envelope(json_response(conn, 422), "validation_failed")
  end

  test "media create synonym missing fields → validation_failed envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/media/test/search/synonyms", %{})

    assert_error_envelope(json_response(conn, 422), "validation_failed")
  end

  test "media delete unknown synonym → not_found envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> delete("/v1/media/test/search/synonyms/does-not-exist")

    assert_error_envelope(json_response(conn, 404), "not_found")
  end

  test "insights include synonymCandidates", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test/insights")

    body = json_response(conn, 200)
    assert is_list(body["result"]["synonymCandidates"])
    assert Map.has_key?(body["result"], "zeroHitRate")
    assert Map.has_key?(body["result"], "recoveryRate")
  end

  test "admin can preview and promote synonym candidate", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test/synonyms/preview", %{
        "q" => "hero",
        "from" => "hero",
        "to" => "phoenix"
      })

    preview = json_response(conn, 200)["result"]
    assert Map.has_key?(preview, "beforeCount")
    assert Map.has_key?(preview, "afterCount")

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/data/search/test/synonyms/promote", %{"from" => "guide", "to" => "phoenix"})

    assert json_response(conn, 200)["result"]["from"] == "guide"
  end
end
