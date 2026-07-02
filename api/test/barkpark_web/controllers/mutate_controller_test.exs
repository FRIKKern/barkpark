defmodule BarkparkWeb.MutateControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    Barkpark.Auth.create_token("barkpark-readonly-token", "ro", "test", ["read"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp authed_readonly(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-readonly-token")
    |> put_req_header("content-type", "application/json")
  end

  describe "write-gate (RequireWritePermission plug)" do
    # A read-only token must be rejected with 403 BEFORE Content.apply_mutations
    # runs. We send an otherwise-invalid payload: a write token would reach
    # validation (422); the read-only token is gated first (403).
    test "read-only token is rejected with 403 at the write-gate", %{conn: conn} do
      resp = conn |> authed_readonly() |> post("/v1/data/mutate/test", invalid_payload())

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "forbidden"
    end

    test "write-capable token passes the gate (reaches validation, not 403)", %{conn: conn} do
      resp = conn |> authed() |> post("/v1/data/mutate/test", invalid_payload())

      # Passed the gate — the write token reaches Content validation, which
      # rejects the no-_type payload with 422. The point is it is NOT 403.
      refute resp.status == 403
      assert resp.status == 422
    end
  end

  # A create without _type triggers Ecto.Changeset validate_required on Document
  # → Errors.to_envelope produces validation_failed with a details map.
  defp invalid_payload do
    Jason.encode!(%{
      "mutations" => [
        %{"create" => %{"_id" => "no-type-1", "title" => "x"}}
      ]
    })
  end

  test "back-compat: validation error returns the legacy v1 envelope when Accept-Version is absent",
       %{conn: conn} do
    resp = conn |> authed() |> post("/v1/data/mutate/test", invalid_payload())

    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)

    assert body["error"]["code"] == "validation_failed"
    # v1 keeps the legacy `details` map keyed by field name with a list of strings
    assert is_map(body["error"]["details"])
    assert is_list(body["error"]["details"]["type"])
    refute Map.has_key?(body["error"], "errors")
    refute Map.has_key?(body["error"], "warnings")
  end

  test "Accept-Version: 2 returns the hierarchical v2 envelope", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> put_req_header("accept-version", "2")
      |> post("/v1/data/mutate/test", invalid_payload())

    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)

    assert body["error"]["code"] == "validation_failed"
    refute Map.has_key?(body["error"], "details")

    assert %{"errors" => errors, "warnings" => %{}, "infos" => %{}} = body["error"]
    assert is_map(errors)
    assert [%{"severity" => _, "code" => _, "message" => _} | _] = errors["/type"]
  end

  test "non-validation errors keep the same shape regardless of Accept-Version", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-x", "title" => "v1"}, "test")

    body =
      Jason.encode!(%{
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
      })

    resp =
      conn
      |> authed()
      |> put_req_header("accept-version", "2")
      |> post("/v1/data/mutate/test", body)

    assert resp.status == 412
    parsed = Jason.decode!(resp.resp_body)
    # rev_mismatch's structured `details` is NOT a per-field error map and
    # must not be reshaped by the v2 envelope transformation.
    assert parsed["error"]["code"] == "precondition_failed"
    assert parsed["error"]["details"]["expected"] == "wrong-rev"
  end

  # Regression: a patch on a PUBLISHED id must target the draft (the row
  # Writer.upsert_document actually writes), not merge from the published row.
  # Reading the published row as merge base silently overwrites the newer draft
  # with published-content-plus-patch (data loss), and its ifRevisionID guard
  # protects the published row while the draft is what gets written.
  # Create published p1 with content {"b" => 0}, then a DIVERGENT draft
  # drafts.p1 with {"a" => "draft-only", "b" => 1}. Returns the draft doc.
  defp published_plus_divergent_draft do
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "p1", "title" => "pub", "content" => %{"b" => 0}}, "test")

    {:ok, _} = Content.publish_document("p1", "post", "test")

    {:ok, draft} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "p1", "title" => "draft", "content" => %{"a" => "draft-only", "b" => 1}},
        "test"
      )

    draft
  end

  defp patch_body(patch) do
    Jason.encode!(%{"mutations" => [%{"patch" => Map.merge(%{"id" => "p1", "type" => "post"}, patch)}]})
  end

  describe "patch merge base == write target (draft-first)" do
    test "patch preserves draft-only edits and leaves the published row untouched", %{conn: conn} do
      published_plus_divergent_draft()

      resp = conn |> authed() |> post("/v1/data/mutate/test", patch_body(%{"set" => %{"x" => 1}}))
      assert resp.status == 200

      # The draft — the row that was written — kept its draft-only field and
      # gained the patched key. Merge base was the draft, not the published row.
      {:ok, draft} = Content.get_document("drafts.p1", "post", "test")
      assert draft.content["a"] == "draft-only"
      assert draft.content["x"] == 1

      # The published row is untouched: it never received the patched key and
      # was never overwritten with draft content.
      {:ok, published} = Content.get_document("p1", "post", "test")
      assert published.content == %{"b" => 0}
    end

    test "ifRevisionID guards the DRAFT row (the written row), not the published row", %{conn: conn} do
      draft = published_plus_divergent_draft()

      # The guard rev is the DRAFT's rev — with the fix, ensure_rev compares
      # against the row actually being written, so this succeeds.
      resp =
        conn
        |> authed()
        |> post("/v1/data/mutate/test", patch_body(%{"ifRevisionID" => draft.rev, "set" => %{"x" => 1}}))

      assert resp.status == 200

      {:ok, written} = Content.get_document("drafts.p1", "post", "test")
      assert written.content["x"] == 1
      assert written.content["a"] == "draft-only"
    end

    test "Phase-1B patch ops (setIfMissing/inc) also merge from the draft", %{conn: conn} do
      published_plus_divergent_draft()

      resp =
        conn
        |> authed()
        |> post("/v1/data/mutate/test", patch_body(%{"inc" => %{"b" => 5}, "setIfMissing" => %{"c" => "z"}}))

      assert resp.status == 200

      {:ok, draft} = Content.get_document("drafts.p1", "post", "test")
      # inc'd from the DRAFT's b=1 (→ 6), not the published b=0 (→ 5); draft-only
      # field survived; setIfMissing filled the absent key.
      assert draft.content["b"] == 6
      assert draft.content["a"] == "draft-only"
      assert draft.content["c"] == "z"

      {:ok, published} = Content.get_document("p1", "post", "test")
      assert published.content == %{"b" => 0}
    end
  end
end
