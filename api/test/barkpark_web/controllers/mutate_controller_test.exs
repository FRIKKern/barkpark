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

  # The ledger's back door (cch-w1-ledger-close-guard, epic decision D22).
  #
  # OBSERVED LIVE before the guard: a `type:task` row went `open` → `done`
  # through one `/v1/data/mutate` patch carrying `set:{"lifecycle_status":
  # "done"}` — HTTP 200, `claim=None closed_by=None`. That is the mechanism
  # behind the 11-tasks-fake-done defect. Both patch clauses in
  # `Content.Mutations` were exploitable, and the compound clause is reachable
  # through its OWN `set` merge (NOT through `unset`, which 422s because the
  # schema marks the field required) — so it needs its own test, not a variant
  # of the plain-set one.
  describe "ledger close-bypass guard" do
    setup do
      for schema_def <- Barkpark.Tasks.schema_definitions("test") do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, "test")
      end

      :ok
    end

    test "PLAIN-SET clause: a blind terminal lifecycle_status patch is refused",
         %{conn: conn} do
      create_task(conn, "guard-plain")

      resp = mutate(conn, [%{"patch" => task_patch("guard-plain", %{"lifecycle_status" => "done"})}])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      # The message IS the retry instruction — it names the sanctioned path.
      assert [message] = body["error"]["details"]["lifecycle_status"]
      assert message =~ "bp task close"
      assert message =~ "ifRevisionID"

      # The whole batch rolled back: the row is still open.
      assert task_content("guard-plain")["lifecycle_status"] == "open"
    end

    test "COMPOUND-OP clause: the same close through setIfMissing + unset + set is refused, " <>
           "and the forged attribution never lands",
         %{conn: conn} do
      create_task(conn, "guard-compound")

      # `setIfMissing` routes this patch to the COMPOUND clause (it matches on
      # the presence of any compound key), so it never reaches the plain-set
      # clause — guarding only that one leaves this vector fully open.
      # `setIfMissing` is also the attribution forgery: it writes a `closed_by`
      # the closer never earned.
      patch =
        "guard-compound"
        |> task_patch(%{"lifecycle_status" => "done"})
        |> Map.put("setIfMissing", %{"closed_by" => "compound-clause-probe"})
        |> Map.put("unset", ["priority"])

      resp = mutate(conn, [%{"patch" => patch}])

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"

      content = task_content("guard-compound")
      assert content["lifecycle_status"] == "open"
      # Rolled back atomically — the forged closer identity is NOT persisted.
      refute Map.has_key?(content, "closed_by")
      # …nor did the piggybacked unset take effect.
      assert content["priority"] == 1
    end

    test "a revision precondition is the escape: the same close with ifRevisionID succeeds",
         %{conn: conn} do
      create_task(conn, "guard-cas")
      {:ok, doc} = Content.get_document("drafts.guard-cas", "task", "test")

      patch =
        "guard-cas"
        |> task_patch(%{"lifecycle_status" => "done"})
        |> Map.put("ifRevisionID", doc.rev)

      assert mutate(conn, [%{"patch" => patch}]).status == 200
      assert task_content("guard-cas")["lifecycle_status"] == "done"
    end

    test "the guard fires only on a CHANGE into a terminal state: patching an unrelated field " <>
           "on an already-closed task still works",
         %{conn: conn} do
      create_task(conn, "guard-noop", %{"lifecycle_status" => "done"})

      # `lifecycle_status` is present and terminal in BOTH the existing row and
      # the merge result, but unchanged — bookkeeping on closed rows (retros,
      # digests, compaction) must not be collateral damage.
      resp = mutate(conn, [%{"patch" => task_patch("guard-noop", %{"close_reason" => "shipped"})}])

      assert resp.status == 200
      assert task_content("guard-noop")["close_reason"] == "shipped"
      assert task_content("guard-noop")["lifecycle_status"] == "done"
    end

    test "replication is not collateral damage: the same mutation with source: :sync applies",
         %{conn: conn} do
      create_task(conn, "guard-sync")

      # `Sync.Applier` passes `source: :sync` (applier.ex:177) where
      # `MutateController` passes `source: :api` (mutate_controller.ex:14). A
      # replica must be able to mirror an upstream close it did not itself
      # perform, so the guard keys on that already-threaded opt.
      assert {:ok, {_tx, [%{operation: "update"}]}} =
               Content.apply_mutations(
                 [%{"patch" => task_patch("guard-sync", %{"lifecycle_status" => "done"})}],
                 "test",
                 source: :sync
               )

      assert task_content("guard-sync")["lifecycle_status"] == "done"

      # Control: the SAME mutation shape from the API source is refused, so the
      # assertion above cannot pass for the wrong reason (e.g. a guard that
      # never fires at all). It runs against a FRESH row — replaying it against
      # `guard-sync` would be a no-change write, which the guard deliberately
      # permits, and would have passed vacuously.
      create_task(conn, "guard-sync-control")

      assert {:error, {:invalid_task_content, _}} =
               Content.apply_mutations(
                 [%{"patch" => task_patch("guard-sync-control", %{"lifecycle_status" => "done"})}],
                 "test",
                 source: :api
               )
    end

    defp create_task(conn, id, content_extra \\ %{}) do
      content =
        Map.merge(
          %{"kind" => "task", "lifecycle_status" => "open", "priority" => 1},
          content_extra
        )

      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => id,
              "_type" => "task",
              "title" => "Guard fixture #{id}",
              "content" => content
            }
          }
        ])

      assert resp.status == 200
      resp
    end

    defp task_patch(id, set_fields),
      do: %{"id" => id, "type" => "task", "set" => set_fields}

    defp task_content(id) do
      {:ok, doc} = Content.get_document("drafts.#{id}", "task", "test")
      doc.content
    end

    defp mutate(conn, mutations) do
      conn
      |> authed()
      |> post("/v1/data/mutate/test", Jason.encode!(%{"mutations" => mutations}))
    end
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
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "title" => "pub", "content" => %{"b" => 0}},
        "test"
      )

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
    Jason.encode!(%{
      "mutations" => [%{"patch" => Map.merge(%{"id" => "p1", "type" => "post"}, patch)}]
    })
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

    test "ifRevisionID guards the DRAFT row (the written row), not the published row", %{
      conn: conn
    } do
      draft = published_plus_divergent_draft()

      # The guard rev is the DRAFT's rev — with the fix, ensure_rev compares
      # against the row actually being written, so this succeeds.
      resp =
        conn
        |> authed()
        |> post(
          "/v1/data/mutate/test",
          patch_body(%{"ifRevisionID" => draft.rev, "set" => %{"x" => 1}})
        )

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
        |> post(
          "/v1/data/mutate/test",
          patch_body(%{"inc" => %{"b" => 5}, "setIfMissing" => %{"c" => "z"}})
        )

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

  # ── the publish wall over HTTP (authoring-excellence) ───────────────────────

  # A label-spine-compliant content map: non-trivial description + weighted
  # tags with distinct strengths and ≥20-char rationales.
  defp good_labels(tag_count) do
    tags =
      for i <- 1..tag_count do
        %{
          "tag" => "wall-tag-#{i}",
          "strength" => 100 - i,
          "rationale" => "Tag ##{i} exists to exercise the publish wall's HTTP contract."
        }
      end

    %{
      "description" => "A deliberately non-trivial description for the HTTP wall tests.",
      "tags" => tags
    }
  end

  defp create_paper(conn, id, content) do
    conn
    |> authed()
    |> post(
      "/v1/data/mutate/test",
      Jason.encode!(%{
        "mutations" => [
          %{"create" => %{"_id" => id, "_type" => "paper", "title" => "P", "content" => content}}
        ]
      })
    )
  end

  defp patch_paper(conn, id, fields) do
    conn
    |> authed()
    |> post(
      "/v1/data/mutate/test",
      Jason.encode!(%{
        "mutations" => [%{"patch" => %{"id" => id, "type" => "paper", "set" => fields}}]
      })
    )
  end

  defp publish_paper(conn, id) do
    conn
    |> authed()
    |> post(
      "/v1/data/mutate/test",
      Jason.encode!(%{"mutations" => [%{"publish" => %{"id" => id, "type" => "paper"}}]})
    )
  end

  describe "publish wall (label spine over HTTP mutate)" do
    setup do
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
        "test"
      )

      # E3 tag registry: the weighted tags good_labels/1 emits must resolve to
      # PUBLISHED type:tag docs in this dataset.
      Barkpark.LabelFixtures.register_tags!("test", for(i <- 1..3, do: "wall-tag-#{i}"))

      :ok
    end

    test "unlabeled FIRST publish → 422 label_spine with field/rule/fix + hint; the labeled retry succeeds",
         %{conn: conn} do
      assert create_paper(conn, "w1", %{"body" => "no labels yet"}).status == 200

      resp = publish_paper(conn, "w1")
      assert resp.status == 422
      error = Jason.decode!(resp.resp_body)["error"]

      # Machine-readable code + documentation-grade details + fix-suggesting
      # hint — the rejection IS the retry instructions.
      assert error["code"] == "label_spine"
      assert is_binary(error["details"]["field"])
      assert is_binary(error["details"]["rule"])
      assert is_binary(error["details"]["fix"])
      assert is_binary(error["hint"]) and error["hint"] != ""

      # The one retry an agent performs: patch the labels in, publish again.
      assert patch_paper(conn, "w1", good_labels(2)).status == 200
      retry = publish_paper(conn, "w1")
      assert retry.status == 200

      {:ok, published} = Content.get_document("w1", "paper", "test")
      assert published.status == "published"
    end

    test "patching a published paper with blocks and weighted tags reprojects preview without a 500",
         %{conn: conn} do
      assert create_paper(conn, "w-preview-tags", good_labels(2)).status == 200
      assert publish_paper(conn, "w-preview-tags").status == 200

      blocks = [
        %{
          "id" => "intro",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Preview projection survives."}]
        }
      ]

      response = patch_paper(conn, "w-preview-tags", %{"blocks" => blocks})

      assert response.status == 200
      {:ok, draft} = Content.get_document("drafts.w-preview-tags", "paper", "test")
      assert draft.content["preview"]["extensions"]["tags"] == ["wall-tag-1", "wall-tag-2"]
    end

    test "a legal tag count OUTSIDE the 2–4 norm rides `warnings` on the 200 envelope, never blocks",
         %{conn: conn} do
      assert create_paper(conn, "w-norm", good_labels(1)).status == 200

      resp = publish_paper(conn, "w-norm")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert [warning] = body["warnings"]
      assert warning["code"] == "label_norm"
      assert warning["severity"] == "advisory"
      assert warning["message"] =~ "w-norm"

      # The publish itself went through — advisory never blocks.
      assert [%{"operation" => "publish"}] = body["results"]
    end

    test "a tag count INSIDE the 2–4 norm publishes with no warnings key", %{conn: conn} do
      assert create_paper(conn, "w-quiet", good_labels(3)).status == 200

      resp = publish_paper(conn, "w-quiet")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      refute Map.has_key?(body, "warnings")
    end
  end
end
