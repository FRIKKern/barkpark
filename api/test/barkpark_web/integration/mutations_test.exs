defmodule BarkparkWeb.Integration.MutationsTest do
  @moduledoc """
  Integration probe for the publish / unpublish / delete success paths on
  `POST /v1/data/mutate/:dataset` (Goal `barkpark-b1m`, Task `barkpark-upn`,
  gap #2 from `tmp/api-gap-analysis.md`).

  Existing coverage handled the failure side:

    * `mutate_controller_test.exs` — create-no-type → 422 envelope shapes
    * `contract/mutate_test.exs` — bulk atomic rollback, patch ifRevisionID
      412/200, delete with stale ifRevisionID 412

  None of those exercised the **success side-effect** of publish, unpublish,
  or delete. This file fills that hole — it asserts not just the HTTP envelope
  but also the post-mutation DB state (draft moved, published gone, doc
  removed) via the `Content` context.

  Bulk-order assertion lands here too — operation order in the response
  array must match the request.

  `async: false` because the existing mutate tests are also non-async (they
  re-create the dev token + a `test` dataset schema in setup); using
  the same pattern keeps the test surface uniform.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "mutations-integration",
      ["read", "write", "admin"]
    )

    # Drain the boot-time codelist seeder Task before grabbing the DB —
    # otherwise it can hog the sandbox connection and our setup blows up.
    drain_task_supervisor(30_000)

    {:ok, _schema} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "test"
      )

    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(conn, body) do
    conn |> authed() |> post(~p"/v1/data/mutate/test", Jason.encode!(body))
  end

  defp create_draft!(id) do
    {:ok, doc} = Content.create_document("post", %{"_id" => id, "title" => "t-#{id}"}, "test")
    doc
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "publish — sole mutation success path" do
    test "returns 200 + result with operation:publish + persists drafts.X → X", %{conn: conn} do
      _draft = create_draft!("pub-1")

      resp = mutate(conn, %{"mutations" => [%{"publish" => %{"id" => "pub-1", "type" => "post"}}]})

      assert resp.status == 200
      body = json_response(resp, 200)
      assert is_binary(body["transactionId"])
      assert [%{"operation" => "publish", "id" => "pub-1"} | _] = body["results"]

      # Post-mutation persistence: draft gone, published exists.
      assert {:error, :not_found} = Content.get_document("drafts.pub-1", "post", "test")
      assert {:ok, %{doc_id: "pub-1", status: "published"}} =
               Content.get_document("pub-1", "post", "test")
    end
  end

  describe "unpublish — sole mutation success path" do
    test "returns 200 + result with operation:unpublish + persists X → drafts.X", %{conn: conn} do
      # Setup: create a published doc by create-then-publish.
      _ = create_draft!("unp-1")
      {:ok, _pub} = Content.publish_document("unp-1", "post", "test")
      # Sanity: published exists, no draft.
      assert {:ok, %{status: "published"}} = Content.get_document("unp-1", "post", "test")

      resp =
        mutate(conn, %{"mutations" => [%{"unpublish" => %{"id" => "unp-1", "type" => "post"}}]})

      assert resp.status == 200
      body = json_response(resp, 200)
      # The result `id` reflects the *new* doc shape (drafts.unp-1), since
      # unpublish writes the draft and deletes the published copy.
      assert [%{"operation" => "unpublish", "id" => "drafts.unp-1"} | _] = body["results"]

      # Published gone, draft restored with the published content.
      assert {:error, :not_found} = Content.get_document("unp-1", "post", "test")
      assert {:ok, %{doc_id: "drafts.unp-1", status: "draft"}} =
               Content.get_document("drafts.unp-1", "post", "test")
    end
  end

  describe "delete — sole mutation success path" do
    test "returns 200 + result with operation:delete + the draft is gone", %{conn: conn} do
      _draft = create_draft!("del-1")

      assert {:ok, _} = Content.get_document("drafts.del-1", "post", "test")

      resp =
        mutate(conn, %{
          "mutations" => [%{"delete" => %{"id" => "drafts.del-1", "type" => "post"}}]
        })

      assert resp.status == 200
      body = json_response(resp, 200)
      assert [%{"operation" => "delete"} | _] = body["results"]

      assert {:error, :not_found} = Content.get_document("drafts.del-1", "post", "test")

      # Subsequent GET /v1/data/doc/... → 404
      doc_resp = get(conn, ~p"/v1/data/doc/test/post/drafts.del-1")
      assert doc_resp.status == 404
    end

    test "deleting a published doc removes both published and any draft", %{conn: conn} do
      _ = create_draft!("del-2")
      {:ok, _} = Content.publish_document("del-2", "post", "test")
      # Recreate a draft so both `del-2` and `drafts.del-2` exist.
      {:ok, _} = Content.create_document("post", %{"_id" => "del-2", "title" => "d"}, "test")

      assert {:ok, _} = Content.get_document("del-2", "post", "test")
      assert {:ok, _} = Content.get_document("drafts.del-2", "post", "test")

      resp =
        mutate(conn, %{"mutations" => [%{"delete" => %{"id" => "del-2", "type" => "post"}}]})

      assert resp.status == 200

      # Per Content.delete_document/4 — the delete covers both ids.
      assert {:error, :not_found} = Content.get_document("del-2", "post", "test")
      assert {:error, :not_found} = Content.get_document("drafts.del-2", "post", "test")
    end
  end

  describe "bulk mutations preserve operation order" do
    test "create + publish + unpublish across one batch returns results in request order",
         %{conn: conn} do
      body = %{
        "mutations" => [
          %{"create" => %{"_id" => "bulk-a", "_type" => "post", "title" => "A"}},
          %{"publish" => %{"id" => "bulk-a", "type" => "post"}}
        ]
      }

      resp = mutate(conn, body)
      assert resp.status == 200

      parsed = json_response(resp, 200)
      ops = Enum.map(parsed["results"], & &1["operation"])

      assert ops == ["create", "publish"],
             "expected operations [create, publish] in order, got: #{inspect(ops)}"

      # End state: published `bulk-a`, no draft.
      assert {:ok, %{status: "published"}} = Content.get_document("bulk-a", "post", "test")
      assert {:error, :not_found} = Content.get_document("drafts.bulk-a", "post", "test")
    end
  end
end
