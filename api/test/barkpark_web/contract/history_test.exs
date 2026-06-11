defmodule BarkparkWeb.Contract.HistoryTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {:ok, doc} =
      Content.create_document("post", %{"doc_id" => "drafts.h1", "title" => "V1"}, "test")

    Content.publish_document("h1", "post", "test")

    Content.apply_mutations(
      [%{"patch" => %{"id" => "h1", "type" => "post", "set" => %{"title" => "V2"}}}],
      "test"
    )

    {:ok, doc_id: "h1"}
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer barkpark-dev-token")
  end

  test "list revisions for a document", %{conn: conn, doc_id: doc_id} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert is_list(body["revisions"])
    assert length(body["revisions"]) >= 2

    [newest | _] = body["revisions"]
    assert Map.has_key?(newest, "id")
    assert Map.has_key?(newest, "action")
    assert Map.has_key?(newest, "title")
    assert Map.has_key?(newest, "timestamp")
  end

  test "list revisions respects limit", %{conn: conn, doc_id: doc_id} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}", %{"limit" => "1"})

    body = Jason.decode!(resp.resp_body)
    assert length(body["revisions"]) == 1
  end

  test "get a single revision", %{conn: conn, doc_id: doc_id} do
    list_resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    %{"revisions" => [%{"id" => rev_id} | _]} = Jason.decode!(list_resp.resp_body)

    resp =
      conn
      |> authed()
      |> get("/v1/data/revision/test/#{rev_id}")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["revision"]["id"] == rev_id
    assert Map.has_key?(body["revision"], "content")
  end

  test "restore a revision creates a draft", %{conn: conn, doc_id: doc_id} do
    list_resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    %{"revisions" => revisions} = Jason.decode!(list_resp.resp_body)
    oldest = List.last(revisions)

    resp =
      conn
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/revision/test/#{oldest["id"]}/restore", Jason.encode!(%{type: "post"}))

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["restored"] == true
    assert body["document"]["_draft"] == true
  end

  test "returns empty list for unknown document", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/nonexistent")

    body = Jason.decode!(resp.resp_body)
    assert resp.status == 200
    assert body["revisions"] == []
  end

  test "returns 404 for unknown revision", %{conn: conn} do
    fake_uuid = "00000000-0000-0000-0000-000000000000"

    resp =
      conn
      |> authed()
      |> get("/v1/data/revision/test/#{fake_uuid}")

    assert resp.status == 404
  end

  test "requires auth", %{conn: conn} do
    resp = get(conn, "/v1/data/history/test/post/h1")
    assert resp.status == 401
  end

  # barkpark-vdmk: a revision created in dataset "other" must NOT be readable or
  # restorable through a URL that names dataset "test", even for the same token.
  describe "cross-dataset revision IDOR (vdmk)" do
    setup do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "drafts.other1", "title" => "OTHER-V1"},
          "other"
        )

      Content.publish_document("other1", "post", "other")

      [other_rev | _] = Content.list_revisions("other1", "post", "other")
      {:ok, other_rev_id: other_rev.id}
    end

    test "GET a revision via the wrong dataset → 404", %{conn: conn, other_rev_id: other_rev_id} do
      # Sanity: the revision IS reachable under its OWN dataset.
      ok =
        conn
        |> authed()
        |> get("/v1/data/revision/other/#{other_rev_id}")

      assert ok.status == 200

      # The IDOR: same token, but the URL names "test" instead of "other".
      # Pre-fix this leaked the "other" revision; post-fix → 404.
      leak =
        conn
        |> authed()
        |> get("/v1/data/revision/test/#{other_rev_id}")

      assert leak.status == 404,
             "CROSS-DATASET LEAK (revision get): read 'other' revision via 'test' URL"
    end

    test "RESTORE a revision via the wrong dataset → 404, no write into B",
         %{conn: conn, other_rev_id: other_rev_id} do
      resp =
        conn
        |> authed()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/data/revision/test/#{other_rev_id}/restore", Jason.encode!(%{type: "post"}))

      assert resp.status == 404,
             "CROSS-DATASET RESTORE: restored 'other' revision into 'test' (status #{resp.status})"

      # And the "other" revision's doc was never re-upserted into "test".
      assert Content.list_revisions("other1", "post", "test") == []
    end
  end
end
