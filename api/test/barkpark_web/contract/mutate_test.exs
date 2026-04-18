defmodule BarkparkWeb.Contract.MutateTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )
    :ok
  end

  defp do_mutate(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(body))
  end

  test "batch is atomic — partial failure rolls everything back", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "ok-1", "_type" => "post", "title" => "ok"}},
        %{"publish" => %{"id" => "does-not-exist", "type" => "post"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status in [404, 422]
    body_json = Jason.decode!(resp.resp_body)
    assert body_json["error"]["code"] in ~w(validation_failed not_found)

    # Critically: ok-1 must NOT exist
    assert {:error, :not_found} = Content.get_document("drafts.ok-1", "post", "test")
  end

  test "successful batch returns envelopes with transactionId", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "tx-1", "_type" => "post", "title" => "t"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
    body_json = Jason.decode!(resp.resp_body)
    assert is_binary(body_json["transactionId"])
    assert [%{"id" => _, "operation" => "create", "document" => %{"_id" => _, "_type" => "post"}}] =
             body_json["results"]
  end

  test "patch with stale ifRevisionID returns 412 precondition_failed with details", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-1", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "ifRevisionID" => "wrong-rev",
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 412
    parsed = Jason.decode!(resp.resp_body)
    assert parsed["error"]["code"] == "precondition_failed"
    assert parsed["error"]["details"]["expected"] == "wrong-rev"
    assert parsed["error"]["details"]["actual"] == doc.rev
  end

  test "patch with matching ifRevisionID succeeds", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-2", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "ifRevisionID" => doc.rev,
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 200
  end

  test "delete with stale ifRevisionID returns 412", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-3", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{"delete" => %{"id" => doc.doc_id, "type" => "post", "ifRevisionID" => "nope"}}
      ]
    }

    resp = do_mutate(conn, body)

    assert resp.status == 412
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "precondition_failed"
  end

  test "If-Match HTTP header applies as ifRevisionID for single-doc mutation", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-4", "title" => "v1"}, "test")

    body = %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "set" => %{"title" => "v2"}
          }
        }
      ]
    }

    stale =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", ~s("not-the-rev"))
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert stale.status == 412

    fresh =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", ~s("#{doc.rev}"))
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert fresh.status == 200
  end
end
