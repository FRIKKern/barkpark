defmodule BarkparkWeb.DocumentOpsControllerTest do
  # POST /v1/data/doc/:dataset/:type/:doc_id/ops — the HTTP twin of the block op
  # Studio's editor applies in-process (docs/contracts/product-era.md: anything
  # Studio can do, the API can do too).
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  setup do
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    Barkpark.Auth.create_token("ops-write-token", "w", "test", ["read", "write"], ws)
    Barkpark.Auth.create_token("ops-read-token", "r", "test", ["read"], ws)

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp as(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp create_post!(conn, id) do
    body =
      Jason.encode!(%{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => id,
              "_type" => "post",
              "title" => "Ops target",
              "blocks" => [
                %{
                  "id" => "p1",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "first"}]
                }
              ]
            }
          }
        ]
      })

    resp = conn |> as("ops-write-token") |> post("/v1/data/mutate/test", body)
    assert resp.status == 200, resp.resp_body
    current_rev!(conn, id)
  end

  defp current_rev!(_conn, id) do
    resp =
      scoped_conn()
      |> as("ops-write-token")
      |> get("/v1/data/doc/test/post/#{id}?perspective=raw")

    assert resp.status == 200, resp.resp_body
    doc = Jason.decode!(resp.resp_body)
    rev = get_in(doc, ["result", "_rev"])
    assert is_binary(rev), "no _rev in #{resp.resp_body}"
    rev
  end

  defp append_op do
    %{
      "op" => "append-block",
      "block" => %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "second"}]
      }
    }
  end

  defp post_op(conn, token, type, id, body) do
    conn |> as(token) |> post("/v1/data/doc/test/#{type}/#{id}/ops", Jason.encode!(body))
  end

  test "a write token applies one block op to a non-paper document", %{conn: conn} do
    rev = create_post!(conn, "ops-post-1")

    resp =
      post_op(scoped_conn(), "ops-write-token", "post", "ops-post-1", %{
        "op" => append_op(),
        "ifRev" => rev
      })

    assert resp.status == 200, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["result"]["op_kind"] == "append-block"
    assert is_binary(body["result"]["block_id"])

    refute current_rev!(conn, "ops-post-1") == rev
  end

  test "a stale ifRev answers 412 and writes nothing", %{conn: conn} do
    rev = create_post!(conn, "ops-post-2")

    resp =
      post_op(scoped_conn(), "ops-write-token", "post", "ops-post-2", %{
        "op" => append_op(),
        "ifRev" => rev <> "-stale"
      })

    assert resp.status == 412, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "precondition_failed"
    assert current_rev!(conn, "ops-post-2") == rev
  end

  test "a missing ifRev is refused before anything is written", %{conn: conn} do
    rev = create_post!(conn, "ops-post-3")

    resp = post_op(scoped_conn(), "ops-write-token", "post", "ops-post-3", %{"op" => append_op()})

    assert resp.status == 422
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "malformed_op"
    assert current_rev!(conn, "ops-post-3") == rev
  end

  test "a read-tier token is refused at the write gate", %{conn: conn} do
    rev = create_post!(conn, "ops-post-4")

    resp =
      post_op(scoped_conn(), "ops-read-token", "post", "ops-post-4", %{
        "op" => append_op(),
        "ifRev" => rev
      })

    assert resp.status == 403
    assert current_rev!(conn, "ops-post-4") == rev
  end

  test "papers are refused and pointed at their own ops route", %{conn: conn} do
    resp =
      post_op(conn, "ops-write-token", "paper", "any-slug", %{"op" => append_op(), "ifRev" => "1"})

    assert resp.status == 422
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "invalid_op"
    assert error["message"] =~ "/v1/plugins/bulldocs/papers/:slug/ops"
  end

  test "a type with no schema in scope answers 404", %{conn: conn} do
    resp =
      post_op(conn, "ops-write-token", "no-such-type", "x", %{"op" => append_op(), "ifRev" => "r"})

    assert resp.status == 404
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "not_found"
    assert error["message"] =~ "no-such-type"
  end

  describe "a batch under one ifRev" do
    defp para_op(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    defp stored_block_ids(id) do
      resp =
        scoped_conn()
        |> as("ops-write-token")
        |> get("/v1/data/doc/test/post/#{id}?perspective=raw")

      resp.resp_body |> Jason.decode!() |> get_in(["result", "blocks"]) |> Enum.map(& &1["id"])
    end

    test "three ops apply in order in one write and answer the new rev", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-1")

      resp =
        post_op(scoped_conn(), "ops-write-token", "post", "ops-batch-1", %{
          "ops" => [
            para_op("b1", "one"),
            para_op("b2", "two"),
            %{"op" => "move-block", "id" => "b2", "after" => "p1"}
          ],
          "ifRev" => rev
        })

      assert resp.status == 200, resp.resp_body
      result = Jason.decode!(resp.resp_body)["result"]

      assert Enum.map(result["results"], & &1["op_kind"]) ==
               ~w(append-block append-block move-block)

      assert Enum.map(result["results"], & &1["block_id"]) == ~w(b1 b2 b2)
      assert result["rev"] == current_rev!(conn, "ops-batch-1")
      refute result["rev"] == rev
      assert stored_block_ids("ops-batch-1") == ~w(p1 b2 b1)
    end

    test "one invalid op rolls the whole batch back", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-2")

      resp =
        post_op(scoped_conn(), "ops-write-token", "post", "ops-batch-2", %{
          "ops" => [
            para_op("b1", "one"),
            para_op("b2", "two"),
            %{"op" => "move-block", "id" => "b1", "after" => "no-such-block"}
          ],
          "ifRev" => rev
        })

      assert resp.status == 422, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_op"
      assert current_rev!(conn, "ops-batch-2") == rev
      assert stored_block_ids("ops-batch-2") == ["p1"]
    end

    test "a stale ifRev answers 412 and writes nothing", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-3")

      resp =
        post_op(scoped_conn(), "ops-write-token", "post", "ops-batch-3", %{
          "ops" => [para_op("b1", "one"), para_op("b2", "two")],
          "ifRev" => rev <> "-stale"
        })

      assert resp.status == 412, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["details"]["actual"] == rev
      assert current_rev!(conn, "ops-batch-3") == rev
    end

    test "an empty batch, or op and ops together, is malformed", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-4")

      for body <- [
            %{"ops" => [], "ifRev" => rev},
            %{"ops" => [append_op()], "op" => append_op(), "ifRev" => rev},
            %{"ops" => [append_op(), "not an op"], "ifRev" => rev}
          ] do
        resp = post_op(scoped_conn(), "ops-write-token", "post", "ops-batch-4", body)
        assert resp.status == 422, resp.resp_body
        assert Jason.decode!(resp.resp_body)["error"]["code"] == "malformed_op"
      end

      assert current_rev!(conn, "ops-batch-4") == rev
    end

    test "a read-tier token is refused at the write gate", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-5")

      resp =
        post_op(scoped_conn(), "ops-read-token", "post", "ops-batch-5", %{
          "ops" => [para_op("b1", "one")],
          "ifRev" => rev
        })

      assert resp.status == 403, resp.resp_body
      assert current_rev!(conn, "ops-batch-5") == rev
    end

    test "a write token from another workspace cannot reach the document", %{conn: conn} do
      rev = create_post!(conn, "ops-batch-6")
      other_ws = Barkpark.TenancyFixtures.create_workspace!()
      other_proj = Barkpark.TenancyFixtures.create_project!(other_ws)

      # The type exists over there too, so the refusal is the document lookup.
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "test",
        workspace_id: other_ws.id,
        project_id: other_proj.id
      )

      Barkpark.Auth.create_token("ops-foreign-token", "f", "test", ["read", "write"], other_ws.id)

      resp =
        post_op(scoped_conn(), "ops-foreign-token", "post", "ops-batch-6", %{
          "ops" => [para_op("b1", "one")],
          "ifRev" => rev
        })

      assert resp.status == 404, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["message"] == "document not found"
      assert current_rev!(conn, "ops-batch-6") == rev
    end
  end
end
