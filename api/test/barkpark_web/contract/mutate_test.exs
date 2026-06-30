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

  test "patch unset removes a content key, leaving the rest (Phase-1B)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "unset-1", "title" => "v1"}, "test")
    # Establish content via set, then unset one key.
    do_mutate(conn, %{
      "mutations" => [
        %{
          "patch" => %{
            "id" => doc.doc_id,
            "type" => "post",
            "set" => %{"draft" => true, "tags" => ["a"]}
          }
        }
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "unset" => ["draft"]}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    refute Map.has_key?(after_doc.content, "draft")
    assert after_doc.content["tags"] == ["a"]
  end

  test "patch set + unset in one op applies both (unset clause wins on ordering)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "unset-2", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"a" => 1, "b" => 2}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "set" => %{"c" => 3},
              "unset" => ["a"]
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    # set-only clause would have matched on `set` and ignored `unset`, leaving "a".
    refute Map.has_key?(after_doc.content, "a")
    assert after_doc.content["b"] == 2
    assert after_doc.content["c"] == 3
  end

  test "patch unset cannot remove promoted/system fields (title survives)", %{conn: conn} do
    {:ok, doc} =
      Content.create_document("post", %{"_id" => "unset-3", "title" => "keep-me"}, "test")

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "unset" => ["title"]}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.title == "keep-me"
  end

  test "patch inc increments a numeric field; a missing field starts from 0 (Phase-1B)", %{
    conn: conn
  } do
    {:ok, doc} = Content.create_document("post", %{"_id" => "inc-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"views" => 10}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "inc" => %{"views" => 5, "hits" => 3}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["views"] == 15
    # `hits` did not exist — inc treats the missing value as 0.
    assert after_doc.content["hits"] == 3
  end

  test "patch dec decrements a numeric field", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "dec-1", "title" => "v1"}, "test")

    do_mutate(conn, %{
      "mutations" => [
        %{"patch" => %{"id" => doc.doc_id, "type" => "post", "set" => %{"stock" => 8}}}
      ]
    })

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{"patch" => %{"id" => doc.doc_id, "type" => "post", "dec" => %{"stock" => 3}}}
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["stock"] == 5
  end

  test "patch set + inc compose in one op (inc reads the set value)", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "inc-2", "title" => "v1"}, "test")

    resp =
      do_mutate(conn, %{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "set" => %{"score" => 100},
              "inc" => %{"score" => 1}
            }
          }
        ]
      })

    assert resp.status == 200
    {:ok, after_doc} = Content.get_document(doc.doc_id, "post", "test")
    assert after_doc.content["score"] == 101
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
