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

  test "patch with stale ifRevisionID returns rev_mismatch", %{conn: conn} do
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

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "rev_mismatch"
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

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert resp.status == 200
  end
end
