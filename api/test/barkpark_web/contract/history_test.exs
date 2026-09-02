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

  # A bare plugin that vetoes the before_save fired by restore_revision's
  # re-upsert — drives a real {:halt, reason} through the restore endpoint.
  defmodule HaltSavePlugin do
    def lifecycle_hooks, do: %{before_save: [&__MODULE__.veto/1]}
    def veto(_payload), do: {:halt, "restores are frozen by policy"}
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

  test "restoring a publish-action revision produces a DRAFT, not a published row",
       %{conn: conn, doc_id: doc_id} do
    # The setup publishes h1, so a revision with action "publish" and status
    # "published" exists. Restoring it must NOT carry that "published" status
    # onto the drafts.-prefixed write target (else the draft masquerades as
    # published in every status-keyed read).
    publish_rev =
      Content.list_revisions(doc_id, "post", "test")
      |> Enum.find(&(&1.action == "publish"))

    assert publish_rev, "setup should have produced a publish-action revision"
    assert publish_rev.status == "published"

    # Snapshot the published row so we can prove restore left it untouched.
    {:ok, published_before} = Content.get_document(doc_id, "post", "test")

    resp =
      conn
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/revision/test/#{publish_rev.id}/restore",
        Jason.encode!(%{type: "post"})
      )

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["restored"] == true
    assert body["document"]["_draft"] == true

    # (a) the drafts.<id> row exists AND is a genuine draft, not "published".
    {:ok, draft} = Content.get_document("drafts.#{doc_id}", "post", "test")
    assert draft.status == "draft"

    # (b) its content matches the restored revision's captured content.
    assert draft.content == publish_rev.content

    # (c) the published row is untouched (same status + content as before).
    {:ok, published_after} = Content.get_document(doc_id, "post", "test")
    assert published_after.status == published_before.status
    assert published_after.content == published_before.content
    assert published_after.rev == published_before.rev
  end

  test "a halted restore returns the canonical error envelope (not a bare string)",
       %{conn: conn, doc_id: doc_id} do
    list_resp =
      conn
      |> authed()
      |> get("/v1/data/history/test/post/#{doc_id}")

    %{"revisions" => revisions} = Jason.decode!(list_resp.resp_body)
    oldest = List.last(revisions)

    # The doc + revisions already exist; register the before_save veto now so it
    # only bites the restore's re-upsert, not the setup writes.
    original = Application.get_env(:barkpark, :plugins)
    on_exit(fn -> Application.put_env(:barkpark, :plugins, original) end)
    Application.put_env(:barkpark, :plugins, [HaltSavePlugin])

    resp =
      conn
      |> authed()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/revision/test/#{oldest["id"]}/restore", Jason.encode!(%{type: "post"}))

    assert resp.status == 409
    parsed = Jason.decode!(resp.resp_body)

    # canonical envelope the bp CLI + SDK decode via error.code — was a bare
    # %{"error" => "halted", "reason" => …} with no code/request_id.
    assert parsed["error"]["code"] == "halted"
    assert is_binary(parsed["error"]["message"]) and parsed["error"]["message"] != ""
    assert is_binary(parsed["error"]["request_id"]) and parsed["error"]["request_id"] != ""
    refute parsed["error"] == "halted"
    refute Map.has_key?(parsed, "reason")
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

  # task-8d4b1f2c7a0e3591 — the `_rev` READ. `_rev` is the token every envelope
  # stamps and every seal / acceptance criterion cites; before this arm the
  # ONLY revision read keyed on the `revisions` row UUID, so a non-UUID `:id`
  # fell straight to 404 and a cited revision was unresolvable through any
  # surface in the API.
  describe "GET /v1/data/revision/:dataset/:id addressed by a `_rev` HASH" do
    test "resolves an OLDER rev hash to the content that rev named", %{conn: conn} do
      # Two writes to one doc, so the FIRST rev names a state the document has
      # already moved past.
      {:ok, first} =
        Content.upsert_document("post", %{"doc_id" => "revread1", "title" => "OLD"}, "test")

      {:ok, second} =
        Content.upsert_document("post", %{"doc_id" => "revread1", "title" => "NEW"}, "test")

      assert first.rev != second.rev
      v2_rev = first.rev

      resp =
        conn
        |> authed()
        |> get("/v1/data/revision/test/#{v2_rev}")

      # RED WITHOUT THE FIX: 404 — a non-UUID id never reached a read.
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["revision"]["rev"] == v2_rev
      assert body["revision"]["type"] == "post"
      assert body["revision"]["dataset"] == "test"
      # The snapshot AS OF that rev, not the live document.
      assert body["revision"]["document"]["title"] == "OLD"
      assert body["revision"]["document"]["_rev"] == v2_rev
    end

    test "an unknown hash is 404, and a UUID still takes the original arm", %{
      conn: conn,
      doc_id: doc_id
    } do
      resp =
        conn
        |> authed()
        |> get("/v1/data/revision/test/#{String.duplicate("a", 32)}")

      assert resp.status == 404

      # The UUID arm is untouched: it still answers with `content`, not `document`.
      list =
        conn
        |> authed()
        |> get("/v1/data/history/test/post/#{doc_id}")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      [newest | _] = list["revisions"]

      uuid_resp =
        conn
        |> authed()
        |> get("/v1/data/revision/test/#{newest["id"]}")

      assert uuid_resp.status == 200
      uuid_body = Jason.decode!(uuid_resp.resp_body)
      assert uuid_body["revision"]["id"] == newest["id"]
      assert Map.has_key?(uuid_body["revision"], "content")
    end

    test "a rev minted in another dataset is NOT readable through this one", %{conn: conn} do
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "other"
      )

      {:ok, other} =
        Content.create_document("post", %{"doc_id" => "xds1", "title" => "Elsewhere"}, "other")

      resp =
        conn
        |> authed()
        |> get("/v1/data/revision/test/#{other.rev}")

      assert resp.status == 404

      ok =
        conn
        |> authed()
        |> get("/v1/data/revision/other/#{other.rev}")

      assert ok.status == 200
    end
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
