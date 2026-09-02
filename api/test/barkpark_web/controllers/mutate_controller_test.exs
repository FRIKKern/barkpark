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

  # [collide-refusal] Gyldendal field report #3 — the mixed shape used to
  # answer 200 while dropping every flat sibling key.
  #
  # `Writer.from_envelope/1` branches on "is there a MAP under `content`". On
  # that branch attrs pass through unchanged, and `Document.changeset/2`'s
  # 12-column `cast/3` whitelist then discards every non-column top-level key —
  # silently, with no warnings key in the response. THE TRIGGER IS A FIELD-NAME
  # COLLISION, not a malformed request: a purely flat document whose own
  # editorial field is named `content` takes the legacy-envelope branch it never
  # meant to use.
  #
  # MEASURED ON UNPATCHED main (2026-08-20): status 200, stored content
  # %{"nb" => "brodtekst"}, LOST ["authorRef", "publishedAt", "slug"], response
  # body keys exactly ["results", "transactionId"].
  #
  # The fix REFUSES and must never fold — `Content.Mutations.incoming_content/1`
  # resolves through the same `from_envelope/1` and is blind to flat siblings,
  # so folding them into `content` would ship a task-lifecycle bypass. See the
  # `[collide-refusal]` comment in content/writer.ex.
  describe "mixed-shape refusal (field-report #3)" do
    setup do
      Content.upsert_schema(
        %{"name" => "artikkel", "title" => "Artikkel", "visibility" => "public", "fields" => []},
        "test"
      )

      :ok
    end

    test "MIXED shape is 422 and names every discarded key", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-mixed",
              "_type" => "post",
              "title" => "Mixed",
              "content" => %{"body" => "hi"},
              "slug" => "the-slug",
              "publishedAt" => "2026-08-20",
              "authorRef" => "a-1"
            }
          }
        ])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [message] = body["error"]["details"]["unknown_fields"]
      assert message =~ "authorRef, publishedAt, slug"
      # Refused means REFUSED: nothing landed, not even the content map.
      assert {:error, _} = Content.get_document("drafts.collide-mixed", "post", "test")
    end

    test "COLLIDE shape — the document's OWN field is named content — is 422, not 200",
         %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-nb",
              "_type" => "artikkel",
              "title" => "Kollisjon",
              "content" => %{"nb" => "brodtekst"},
              "slug" => "kollisjon",
              "publishedAt" => "2026-08-20",
              "authorRef" => "forfatter-1"
            }
          }
        ])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert [message] = body["error"]["details"]["unknown_fields"]
      assert message =~ "authorRef, publishedAt, slug"
      assert {:error, _} = Content.get_document("drafts.collide-nb", "artikkel", "test")
    end

    # It is the shared create spine that drops, not one verb — so pin the
    # refusal on each door individually rather than trusting the shared path.
    for {verb, id} <- [
          {"create", "collide-v-create"},
          {"createOrReplace", "collide-v-cor"},
          {"createIfNotExists", "collide-v-cine"},
          {"replace", "collide-v-replace"}
        ] do
      test "#{verb} refuses the mixed shape", %{conn: conn} do
        verb = unquote(verb)
        id = unquote(id)

        # `replace` reads FIRST and 404s an absent id, so give it a row to
        # replace — the refusal must still win over a successful overwrite.
        if verb == "replace" do
          assert mutate(conn, [
                   %{
                     "create" => %{
                       "_id" => id,
                       "_type" => "post",
                       "title" => "seed",
                       "content" => %{"body" => "seed"}
                     }
                   }
                 ]).status == 200
        end

        resp =
          mutate(conn, [
            %{
              verb => %{
                "_id" => id,
                "_type" => "post",
                "title" => "Mixed",
                "content" => %{"body" => "hi"},
                "slug" => "the-slug"
              }
            }
          ])

        assert resp.status == 422
        body = Jason.decode!(resp.resp_body)
        assert [message] = body["error"]["details"]["unknown_fields"]
        assert message =~ "slug"
      end
    end

    test "the legitimate FLAT shape (no content key) still folds and lands", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-flat-ok",
              "_type" => "post",
              "title" => "Flat",
              "slug" => "the-slug",
              "publishedAt" => "2026-08-20"
            }
          }
        ])

      assert resp.status == 200
      {:ok, doc} = Content.get_document("drafts.collide-flat-ok", "post", "test")
      assert doc.content["slug"] == "the-slug"
      assert doc.content["publishedAt"] == "2026-08-20"
    end

    test "a reserved-keys-only payload with a content map still lands", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-reserved-ok",
              "_type" => "post",
              "title" => "Reserved",
              "status" => "draft",
              "content" => %{"body" => "hi"}
            }
          }
        ])

      assert resp.status == 200
      {:ok, doc} = Content.get_document("drafts.collide-reserved-ok", "post", "test")
      assert doc.content == %{"body" => "hi"}
    end

    # [own-content-field] gh-6291, WAS a silent loss, now FIXED. A SCALAR
    # `content` takes the FLAT branch (`from_envelope/1` guards on `is_map`),
    # so the mixed-shape refusal correctly stays quiet and the siblings fold —
    # but that branch's `Map.drop(@reserved_in)` used to DISCARD the scalar
    # too, because `"content"` is a member of `@reserved_in`. It was consumed
    # by nothing on that branch: pure loss. The flat branch now folds the
    # caller's own `content` field like every other non-reserved key.
    #
    # RED BEFORE / GREEN AFTER: on origin/main this test reads
    #   code:  assert doc.content["content"] == "just text"
    #   left:  nil
    #   right: "just text"
    # which IS the reported defect. Its predecessor asserted `== nil` and
    # pinned the loss as a known gap; that assertion is what this replaces.
    test "a flat document's OWN scalar content field survives the write", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-scalar-ok",
              "_type" => "post",
              "title" => "Scalar",
              "content" => "just text",
              "slug" => "the-slug"
            }
          }
        ])

      assert resp.status == 200
      {:ok, doc} = Content.get_document("drafts.collide-scalar-ok", "post", "test")
      # The siblings still fold, exactly as before.
      assert doc.content["slug"] == "the-slug"
      # ...and the caller's own field is no longer thrown away.
      assert doc.content["content"] == "just text"

      # ROUND-TRIP, not just storage: the field has to come back OUT too, or
      # storing it would be a private victory. `Envelope.render/3` is the single
      # read chokepoint every read surface threads through.
      rendered = Barkpark.Content.Envelope.render(doc, nil, :internal)
      assert rendered["content"] == "just text"
      assert rendered["slug"] == "the-slug"
    end

    # [status-collision] gh-6292. Unlike `content`, a flat `status` IS consumed
    # (it is lifted into the lifecycle column) and is never re-emitted by
    # `Envelope.render/3` — so a caller's own `status` field cannot be stored
    # from this shape at all. What it used to get back was
    # `status: ["is invalid"]` from `Document.changeset/2`'s inclusion check:
    # true, and useless. The refusal now names the collision and the way out.
    test "a flat document's own status field is refused with the collision named",
         %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-status-refused",
              "_type" => "post",
              "title" => "Stock record",
              "status" => "in_stock",
              "slug" => "the-slug"
            }
          }
        ])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert [message] = body["error"]["details"]["status"]
      # It names the offending value, the vocabulary it is not in, and the fix.
      assert message =~ ~s("in_stock")
      assert message =~ "lifecycle"
      assert message =~ "content"
      # ...and nothing was written.
      assert {:error, :not_found} =
               Content.get_document("drafts.collide-status-refused", "post", "test")
    end

    # THE REGRESSION GUARD for the refusal above: the documented flat envelope
    # still works. `status` here is the envelope's lifecycle key, and the write
    # lands.
    test "the flat envelope's own lifecycle status still lands", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-status-envelope",
              "_type" => "post",
              "title" => "Envelope status",
              "status" => "draft",
              "slug" => "the-slug"
            }
          }
        ])

      assert resp.status == 200
      {:ok, doc} = Content.get_document("drafts.collide-status-envelope", "post", "test")
      assert doc.status == "draft"
      assert doc.content["slug"] == "the-slug"
      # It is the LIFECYCLE key, so it is not folded into content.
      refute Map.has_key?(doc.content, "status")
    end

    # MEASURED, and pinned as a RECORDED FACT rather than an endorsement — the
    # same discipline the scalar-content gap got before it was fixed. A flat
    # `status` whose value HAPPENS to be a lifecycle word is byte-identical
    # whether the caller meant the envelope or their own field, so the refusal
    # cannot fire: the value rewrites the document's lifecycle state while the
    # caller's field vanishes. Closing it needs a contract change (a `_status`
    # envelope key, or consulting the type's schema for a declared `status`
    # field), which is a different blast radius. Filed as
    # gfr-w1-flat-status-enum-valid-collision.
    test "KNOWN RESIDUE: an enum-VALID status collision is still ambiguous and still lands",
         %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_id" => "collide-status-residue",
              "_type" => "post",
              "title" => "Archived order",
              "status" => "archived",
              "slug" => "the-slug"
            }
          }
        ])

      assert resp.status == 200
      {:ok, doc} = Content.get_document("drafts.collide-status-residue", "post", "test")
      # The caller's "archived" became the DOCUMENT's lifecycle state...
      assert doc.status == "archived"
      # ...and their own field is not in content. This is the residue.
      refute Map.has_key?(doc.content, "status")
    end
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
      register_task_schemas!()
      :ok
    end

    test "PLAIN-SET clause: a blind terminal lifecycle_status patch is refused",
         %{conn: conn} do
      create_task(conn, "guard-plain")

      resp =
        mutate(conn, [%{"patch" => task_patch("guard-plain", %{"lifecycle_status" => "done"})}])

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

    # D7a SUPERSEDE (tlv writer-seam gate): this test used to assert the
    # rev-carrying open→done patch SUCCEEDS — the revision escape was the
    # sanctioned path out of the close guard. The Writer-seam transition gate
    # now enforces the charter-D7 legality table downstream of that escape:
    # a revision precondition still proves the caller read the row, but a read
    # no longer licenses an ILLEGAL transition (`any → done` is reached only
    # through the close primitive). The escape remains live for LEGAL terminal
    # transitions — see the `blocked` rev-escape test below, which stays 200.
    test "D7a supersede: a revision precondition no longer licenses an illegal open → done patch",
         %{conn: conn} do
      create_task(conn, "guard-cas")
      {:ok, doc} = Content.get_document("drafts.guard-cas", "task", "test")

      patch =
        "guard-cas"
        |> task_patch(%{"lifecycle_status" => "done"})
        |> Map.put("ifRevisionID", doc.rev)

      resp = mutate(conn, [%{"patch" => patch}])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      # The refusal names from, to and the sanctioned verb.
      assert [message] = body["error"]["details"]["lifecycle_status"]
      assert message =~ "\"open\""
      assert message =~ "\"done\""
      assert message =~ "bp task close"

      # The row never moved.
      assert task_content("guard-cas")["lifecycle_status"] == "open"
    end

    test "the guard fires only on a CHANGE into a terminal state: patching an unrelated field " <>
           "on an already-closed task still works",
         %{conn: conn} do
      create_task(conn, "guard-noop", %{"lifecycle_status" => "done"})

      # `lifecycle_status` is present and terminal in BOTH the existing row and
      # the merge result, but unchanged — bookkeeping on closed rows (retros,
      # digests, compaction) must not be collateral damage.
      resp =
        mutate(conn, [%{"patch" => task_patch("guard-noop", %{"close_reason" => "shipped"})}])

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
                 [
                   %{"patch" => task_patch("guard-sync-control", %{"lifecycle_status" => "done"})}
                 ],
                 "test",
                 source: :api
               )
    end

    # THE DRIFT TRIPWIRE. The guard's terminal set is DUPLICATED from
    # `@closed_lifecycle_statuses` in `api/lib/barkpark/tasks/close.ex` (that
    # module owns the definition and exposes no public accessor, and widening
    # this slice's fence to add one was out of scope). A copied constant with
    # nothing pinning it is a door that silently re-opens: add a terminal status
    # to close.ex, and the guard misses it while every test above stays green.
    #
    # So this reads close.ex's OWN list out of its source and proves the guard
    # refuses a blind patch into EVERY status in it. It is behavioural, not a
    # string compare — it fails if the guard stops covering a status for any
    # reason, not only if the literal drifts.
    test "every terminal status close.ex owns is fenced — the copied list cannot drift silently",
         %{conn: conn} do
      source = File.read!(Path.join(__DIR__, "../../../lib/barkpark/tasks/close.ex"))

      [_, inner] =
        Regex.run(~r/@closed_lifecycle_statuses\s+~w\(([^)]*)\)/, source) ||
          flunk(
            "could not find @closed_lifecycle_statuses in close.ex — did it move or change shape?"
          )

      statuses = inner |> String.split(~r/\s+/, trim: true)
      assert length(statuses) >= 3, "expected close.ex to own at least done/cancelled/blocked"

      for status <- statuses do
        id = "guard-drift-#{status}"
        create_task(conn, id)

        resp = mutate(conn, [%{"patch" => task_patch(id, %{"lifecycle_status" => status})}])

        assert resp.status == 422,
               "close.ex treats #{inspect(status)} as terminal, but /v1/data/mutate accepted a " <>
                 "blind patch into it (HTTP #{resp.status}). Add it to " <>
                 "@terminal_lifecycle_statuses in Barkpark.Content.Mutations."

        assert task_content(id)["lifecycle_status"] == "open"
      end
    end

    defp register_task_schemas! do
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

    # PDS-D291: one MET criterion keeps the sanctioned-path `done` closes below
    # out of the close-artifact gate, which refuses a `done` close of a
    # criteria-less kind:task row whose reason names no PR+sha. This file
    # measures the mutate back door, not the close reason.
    defp create_task(conn, id, content_extra \\ %{}) do
      content =
        Map.merge(
          %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "priority" => 1,
            "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
          },
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

  # ── the criteria fence, pinned at the HTTP seam (pds-bl-criteria-fence-http-level-pin) ──
  #
  # PDS wave 26 shipped the acceptance_criteria fence in gate_task_publish/2
  # and proved it through Content.publish_document/4 only. This pins the seam
  # an operator actually hits: a publish issued over /v1/data/mutate must map
  # the fence refusal to a 422 validation_failed carrying the teachable
  # acceptance_criteria message — and the stamped proof must survive, read
  # back over HTTP, never from the repo.
  describe "criteria fence over HTTP (pds-bl-criteria-fence-http-level-pin)" do
    setup do
      register_task_schemas!()
      Barkpark.LabelFixtures.register_tags!("test")
      :ok
    end

    test "a criteria-clearing publish over /v1/data/mutate answers 422 validation_failed " <>
           "with the acceptance_criteria message, and the stamp survives the HTTP read-back",
         %{conn: conn} do
      # Publish a proof-bearing task through the HTTP door (birth — exempt).
      content =
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "priority" => 1,
          "acceptance_criteria" => [
            %{"criterion" => "it works", "met" => true, "evidence" => "run output pasted"}
          ]
        }
        |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

      assert %{status: 200} =
               mutate(conn, [
                 %{
                   "create" => %{
                     "_id" => "fence-http-pin",
                     "_type" => "task",
                     "title" => "Fence HTTP pin fixture",
                     "content" => content
                   }
                 },
                 %{"publish" => %{"id" => "fence-http-pin", "type" => "task"}}
               ])

      # The stale draft: same doc, criteria regressed to unproven — written
      # over HTTP too (a draft edit is a plain content edit; only the PUBLISH
      # may refuse).
      regressed =
        Map.put(content, "acceptance_criteria", [
          %{"criterion" => "it works", "met" => false, "evidence" => ""}
        ])

      assert %{status: 200} =
               mutate(conn, [
                 %{
                   "createOrReplace" => %{
                     "_id" => "drafts.fence-http-pin",
                     "_type" => "task",
                     "title" => "Fence HTTP pin fixture",
                     "content" => regressed
                   }
                 }
               ])

      # The erasing publish over the wire: 422 validation_failed, and the
      # refusal carries the fence's teachable acceptance_criteria message.
      resp = mutate(conn, [%{"publish" => %{"id" => "fence-http-pin", "type" => "task"}}])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [message] = body["error"]["details"]["acceptance_criteria"]
      assert message =~ "clear the `met: true` flag"
      assert message =~ "bp task stamp"

      # The proof survives — read back over HTTP, not from the repo.
      read =
        conn
        |> authed()
        |> get("/v1/data/doc/test/task/fence-http-pin")
        |> json_response(200)

      # /v1/data/doc answers the PUBLISHED row flattened under "result".
      result = read["result"]
      assert result["_draft"] == false

      assert [%{"met" => true, "evidence" => "run output pasted"}] =
               result["acceptance_criteria"]
    end
  end

  # ── cch-w2: the claim's own fence, and the create-family doors ────────────
  #
  # Round 1 (cch-w1 / D22) fenced the two `patch` clauses against a blind close.
  # This wave pays the CLASS rather than the two instances, and measurement
  # refuted two of the assumptions round 1 shipped on:
  #
  #   * D52 — the patch door was NOT claim-safe. Three siblings measured HTTP
  #     200 on main: `unset:["claim"]` + terminal set + CORRECT rev;
  #     `set:{"claim":null}` + terminal set + correct rev; and `unset:["claim"]`
  #     with no rev and no lifecycle change at all (pure claim theft). The
  #     revision escape D22 relies on is precisely what let the first two
  #     through, which is why the claim fence is a SEPARATE function with no
  #     revision escape (D51) rather than another branch in the close guard.
  #   * D53 — the create family was never guarded at all: `createOrReplace` and
  #     `replace` reach `Content.create_document` and skip
  #     `ensure_task_close_is_cas` entirely. `create` / `createIfNotExists` are
  #     left exempt because they are STRUCTURALLY incapable of touching a live
  #     row (409 / noop), which these tests prove rather than assume.
  #
  # Every test below is written so it FAILS (200 instead of 422) against the
  # pre-guard tree — verified by reverting `mutations.ex` and re-running.
  describe "ledger claim fence + create-family doors (cch-w2)" do
    setup do
      register_task_schemas!()
      :ok
    end

    # ── D50: replace's contract is a 404, and that must stay pinned ─────────

    # THE TRIPWIRE. `replace` reads first and propagates `{:error, :not_found}`
    # for an absent id — `docs/api-v1.md:105` ("overwrites an *existing* draft,
    # `not_found` if none"). While wiring the guards, binding `existing` to nil
    # here "so the guard's nil fork is reachable" silently converted `replace`
    # into an UPSERT: HTTP 200 and the row created. NOTHING caught it — the
    # whole mutate + writer-fence suite stayed green through the regression.
    # This test is the thing that catches it next time.
    test "replace against a non-existent id is 404 and creates NOTHING", %{conn: conn} do
      resp = mutate(conn, [%{"replace" => task_doc("cchw2-ghost", %{})}])

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
      assert {:error, _} = Content.get_document("drafts.cchw2-ghost", "task", "test")
    end

    # ── D52: the three patch-door claim siblings ────────────────────────────

    test "PATCH SIBLING (a): unset:[\"claim\"] + terminal set + CORRECT rev is refused",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-drop-a")

      # The correct rev satisfies the CLOSE guard's escape — which is exactly
      # why a claim-drop branch appended to that guard's cond would be dead
      # code. Only an orthogonal fence catches this.
      patch =
        "cchw2-drop-a"
        |> task_patch(%{"lifecycle_status" => "done"})
        |> Map.put("unset", ["claim"])
        |> Map.put("ifRevisionID", task_rev("cchw2-drop-a"))

      resp = mutate(conn, [%{"patch" => patch}])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [message] = body["error"]["details"]["claim"]
      assert message =~ "bp task release"
      assert message =~ "revision precondition does NOT unlock this"

      content = task_content("cchw2-drop-a")
      assert content["claim"]["worker"] == "honest-worker"
      assert content["lifecycle_status"] == "open"
    end

    test "PATCH SIBLING (b): set:{\"claim\":null} + terminal set + correct rev is refused",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-drop-b")

      # No compound key — this lands on the PLAIN-SET clause, which is a
      # separate `apply_one` head. Guarding one clause leaves the other open
      # (the round-1 two-clause lesson), so both are wired.
      patch =
        "cchw2-drop-b"
        |> task_patch(%{"lifecycle_status" => "done", "claim" => nil})
        |> Map.put("ifRevisionID", task_rev("cchw2-drop-b"))

      resp = mutate(conn, [%{"patch" => patch}])

      assert resp.status == 422
      assert [_message] = Jason.decode!(resp.resp_body)["error"]["details"]["claim"]

      content = task_content("cchw2-drop-b")
      assert content["claim"]["worker"] == "honest-worker"
      assert content["lifecycle_status"] == "open"
    end

    test "PATCH SIBLING (c): PURE claim theft — unset:[\"claim\"], no rev, no lifecycle change",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-drop-c")

      # The nastiest of the three, and the one D22's guard could never have
      # seen: with no lifecycle transition the close guard's FIRST cond branch
      # returns :ok before anything else is inspected. The row stays
      # `in_progress` and simply loses its owner.
      resp =
        mutate(conn, [
          %{"patch" => %{"id" => "cchw2-drop-c", "type" => "task", "unset" => ["claim"]}}
        ])

      assert resp.status == 422
      assert [message] = Jason.decode!(resp.resp_body)["error"]["details"]["claim"]
      assert message =~ "honest-worker"

      assert task_content("cchw2-drop-c")["claim"]["worker"] == "honest-worker"
    end

    # ── D53: the two create-family lifecycle doors ──────────────────────────

    test "createOrReplace cannot close an open task without a revision precondition",
         %{conn: conn} do
      create_task(conn, "cchw2-cor-close")

      resp =
        mutate(conn, [
          %{"createOrReplace" => task_doc("cchw2-cor-close", %{"lifecycle_status" => "done"})}
        ])

      assert resp.status == 422
      assert [message] = Jason.decode!(resp.resp_body)["error"]["details"]["lifecycle_status"]
      assert message =~ "bp task close"
      assert task_content("cchw2-cor-close")["lifecycle_status"] == "open"
    end

    test "replace cannot close an open task without a revision precondition", %{conn: conn} do
      create_task(conn, "cchw2-rep-close")

      resp =
        mutate(conn, [
          %{"replace" => task_doc("cchw2-rep-close", %{"lifecycle_status" => "done"})}
        ])

      assert resp.status == 422
      assert [message] = Jason.decode!(resp.resp_body)["error"]["details"]["lifecycle_status"]
      assert message =~ "bp task close"
      assert task_content("cchw2-rep-close")["lifecycle_status"] == "open"
    end

    test "createOrReplace cannot close a CLAIMED task even with a correct ifRevisionID",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-cor-claimed")

      # A whole-document write that omits `claim` erases it. The revision
      # precondition unlocks the lifecycle guard (the caller did read the row),
      # and the claim fence stops it anyway — the two guards compose.
      attrs =
        "cchw2-cor-claimed"
        |> task_doc(%{"lifecycle_status" => "done"})
        |> Map.put("ifRevisionID", task_rev("cchw2-cor-claimed"))

      resp = mutate(conn, [%{"createOrReplace" => attrs}])

      assert resp.status == 422
      assert [_message] = Jason.decode!(resp.resp_body)["error"]["details"]["claim"]

      content = task_content("cchw2-cor-claimed")
      assert content["lifecycle_status"] == "open"
      assert content["claim"]["worker"] == "honest-worker"
    end

    test "replace cannot close a CLAIMED task even with a correct ifRevisionID", %{conn: conn} do
      create_claimed_task(conn, "cchw2-rep-claimed")

      attrs =
        "cchw2-rep-claimed"
        |> task_doc(%{"lifecycle_status" => "done"})
        |> Map.put("ifRevisionID", task_rev("cchw2-rep-claimed"))

      resp = mutate(conn, [%{"replace" => attrs}])

      assert resp.status == 422
      assert [_message] = Jason.decode!(resp.resp_body)["error"]["details"]["claim"]

      content = task_content("cchw2-rep-claimed")
      assert content["lifecycle_status"] == "open"
      assert content["claim"]["worker"] == "honest-worker"
    end

    test "the FLAT Sanity envelope is not an escape — no nested `content` map still lands content",
         %{conn: conn} do
      create_task(conn, "cchw2-flat")

      # `Writer.from_envelope/1` folds every non-reserved top-level key into
      # `content`, so this writes lifecycle_status=done exactly like the nested
      # shape. The guard resolves the SAME envelope rather than reading
      # `attrs["content"]` and seeing an empty map.
      resp =
        mutate(conn, [
          %{
            "createOrReplace" => %{
              "_id" => "cchw2-flat",
              "_type" => "task",
              "title" => "flat envelope",
              "kind" => "task",
              "lifecycle_status" => "done"
            }
          }
        ])

      assert resp.status == 422
      assert task_content("cchw2-flat")["lifecycle_status"] == "open"
    end

    # ── D53: create / createIfNotExists are PROVEN exempt, not trusted ──────

    test "create 409s and createIfNotExists noops against an existing claimed task",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-exempt")

      forged = task_doc("cchw2-exempt", %{"lifecycle_status" => "done"})

      resp = mutate(conn, [%{"create" => forged}])
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "conflict"

      resp = mutate(conn, [%{"createIfNotExists" => forged}])
      assert resp.status == 200
      assert [%{"operation" => "noop"}] = Jason.decode!(resp.resp_body)["results"]

      # Neither op is wired to either guard, because neither can reach a live
      # row: the fence would be dead code.
      content = task_content("cchw2-exempt")
      assert content["lifecycle_status"] == "open"
      assert content["claim"]["worker"] == "honest-worker"
    end

    test "the FRESH-create exemption is intact: an importer can still file an already-done task",
         %{conn: conn} do
      # There is no prior revision on a birth, so `ifRevisionID` is undefined
      # here and the same guard shape would degrade from a fence into an
      # unconditional ban — breaking the dataset importer (migration
      # 20260528100000). This is the exemption, held deliberately.
      resp =
        mutate(conn, [
          %{"createOrReplace" => task_doc("cchw2-import", %{"lifecycle_status" => "done"})}
        ])

      assert resp.status == 200
      assert task_content("cchw2-import")["lifecycle_status"] == "done"
    end

    # ── The exemption's price, measured rather than asserted away ───────────

    test "RESIDUAL HARM: one forged FRESH create unblocks a dependent in Tasks.Queue.ready",
         %{conn: conn} do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id, dataset: "test"]

      # The CONTROL is dependency-free and must appear in BOTH lists — without
      # it a `ready` query that silently returns [] (wrong scope, wrong dataset)
      # would make the "before" assertion pass vacuously.
      create_task(conn, "cchw2-ac7-control")
      create_task(conn, "cchw2-ac7-dependent", %{"dependencies" => ["cchw2-ac7-dep"]})

      before_ids = ready_doc_ids(scope)
      assert "drafts.cchw2-ac7-control" in before_ids
      refute "drafts.cchw2-ac7-dependent" in before_ids

      # A dangling dependency fails CLOSED, and `Queue.ready` satisfies a
      # dependency on exactly one signal: a same-scope task with
      # lifecycle_status == "done". Forging that row is a plain `create`, which
      # this slice deliberately leaves exempt — so the dependent flips to ready
      # with zero attribution anywhere in the ledger.
      assert mutate(conn, [
               %{"create" => task_doc("cchw2-ac7-dep", %{"lifecycle_status" => "done"})}
             ]).status == 200

      after_ids = ready_doc_ids(scope)
      assert "drafts.cchw2-ac7-control" in after_ids
      assert "drafts.cchw2-ac7-dependent" in after_ids

      # NO COMPENSATING CONTROL SHIPS IN THIS SLICE. Closing this needs an
      # attribution requirement on task BIRTHS, which is a different fence
      # (`create` has no prior revision to assert against). Recorded here so the
      # exemption stays visible instead of reading as "handled".
    end

    # ── The sanctioned path is never collateral damage ──────────────────────

    test "after a refusal, Barkpark.Tasks.close/3 with the right worker+epoch still succeeds",
         %{conn: conn} do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      create_task(conn, "cchw2-sanctioned")

      {:ok, claimed} =
        Barkpark.Tasks.claim_by_id("cchw2-sanctioned", "honest-worker",
          workspace_id: ws.id,
          project_id: project.id
        )

      epoch = claimed.content["claim"]["epoch"]

      # The back door is shut…
      assert mutate(conn, [
               %{"patch" => %{"id" => "cchw2-sanctioned", "type" => "task", "unset" => ["claim"]}}
             ]).status == 422

      # …and the front door still opens, with attribution intact. (`Tasks.*`
      # never routes through `Content.apply_mutations`, which is why the guard
      # cannot reach it — proven here rather than argued.)
      assert {:ok, %Barkpark.Content.Document{} = closed} =
               Barkpark.Tasks.close(claimed.id, "honest-worker", observed_epoch: epoch)

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["claim"]["closed_by"] == "honest-worker"
    end

    # ── Replication, and the side effect of `blocked` being terminal ────────

    test "replication is exempt from the claim fence, and the exemption is not vacuous",
         %{conn: conn} do
      create_claimed_task(conn, "cchw2-sync")

      # The `Sync.Applier.apply_upsert` shape (applier.ex:172-181): a
      # createOrReplace carrying the FULL remote document, which has no `claim`
      # because the claim happened LOCALLY after the last push. Refusing this
      # rolls back the ENTIRE sync batch (one transaction) and wedges the
      # replica on that row with no operator recourse.
      assert {:ok, {_tx, [%{operation: "createOrReplace"}]}} =
               Content.apply_mutations(
                 [%{"createOrReplace" => task_doc("cchw2-sync", %{})}],
                 "test",
                 source: :sync
               )

      assert task_content("cchw2-sync")["claim"] == nil

      # Control on a FRESH claimed row, so the assertion above cannot pass for
      # the wrong reason (a fence that never fires at all): the SAME mirror
      # write from the API source is refused. `:source` is server-set —
      # MutateController prepends `source: :api` — so this exemption is not
      # reachable from a request body.
      # `distinct_from` is the Tasks.Dedup escape hatch — the two fixtures share
      # a title stem by design (they are the same shape, one per source), and
      # the find-or-create gate would otherwise 409 the second birth.
      create_claimed_task(conn, "cchw2-sync-control", %{"distinct_from" => ["cchw2-sync"]})

      assert {:error, {:invalid_task_content, %{"claim" => _}}} =
               Content.apply_mutations(
                 [%{"createOrReplace" => task_doc("cchw2-sync-control", %{})}],
                 "test",
                 source: :api
               )

      assert task_content("cchw2-sync-control")["claim"]["worker"] == "honest-worker"
    end

    test "MEASURED SIDE EFFECT: `blocked` is terminal, so createOrReplace now demands a rev for it",
         %{conn: conn} do
      create_task(conn, "cchw2-blocked")

      # INTENDED, not incidental: `blocked` sits in close.ex's
      # @closed_lifecycle_statuses, and the patch door has required a revision
      # for it since round 1 (the drift-tripwire test above asserts exactly
      # that). Extending the guard to two more ops makes the doors agree; a
      # `blocked` that skipped the fence on createOrReplace would be the same
      # unattributed terminal write under a different name.
      assert mutate(conn, [
               %{
                 "createOrReplace" =>
                   task_doc("cchw2-blocked", %{"lifecycle_status" => "blocked"})
               }
             ]).status == 422

      assert task_content("cchw2-blocked")["lifecycle_status"] == "open"

      # …and the revision precondition is the escape. PROTECTIVE under the
      # writer-seam transition gate (D7a): `open → blocked` is LEGAL in the
      # charter-D7 table, so unlike the illegal `open → done` (whose rev escape
      # the gate superseded — see the D7a test above) this MUST STAY 200. The
      # survey claim that "both escapes flip" was verified WRONG; this
      # assertion is what keeps the gate from over-refusing legal transitions.
      attrs =
        "cchw2-blocked"
        |> task_doc(%{"lifecycle_status" => "blocked"})
        |> Map.put("ifRevisionID", task_rev("cchw2-blocked"))

      assert mutate(conn, [%{"createOrReplace" => attrs}]).status == 200
      assert task_content("cchw2-blocked")["lifecycle_status"] == "blocked"
    end

    # ── cch-w3 (D52 residue): theft-by-OVERWRITE, not just erasure ──────────

    # MEASURED on pristine main before the fence was extended (see the task
    # ledger for the quoted probe): patch `set:{"claim":{"worker":"attacker",…}}`
    # on a claimed task returned HTTP 200, the stored claim BECAME the attacker's,
    # and the honest holder of epoch 1 then got `{:error, :fenced_off}` from
    # `Barkpark.Tasks.close` — locked out of its own row. wave 2's guard returned
    # :ok on any non-nil `merged["claim"]`, so a foreign claim satisfied it. The
    # fence now refuses ANY api-door change to a live claim.
    test "SUBSTITUTION: set:{\"claim\":{foreign}} through mutate is refused, and the honest owner can still close",
         %{conn: conn} do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      create_task(conn, "cchw3-sub")

      {:ok, claimed} =
        Barkpark.Tasks.claim_by_id("cchw3-sub", "honest-worker",
          workspace_id: ws.id,
          project_id: project.id
        )

      epoch = claimed.content["claim"]["epoch"]

      # The attack: overwrite the claim with a foreign map. No lifecycle change,
      # so the close guard's first cond branch returns :ok before it — only the
      # claim fence's `now == was` predicate catches this.
      resp =
        mutate(conn, [
          %{
            "patch" =>
              task_patch("cchw3-sub", %{
                "claim" => %{
                  "worker" => "attacker",
                  "epoch" => 99,
                  "ts_iso" => "2026-07-21T00:00:00Z"
                }
              })
          }
        ])

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "validation_failed"
      assert [message] = body["error"]["details"]["claim"]
      assert message =~ "cannot be reassigned"
      assert message =~ "honest-worker"
      assert message =~ "revision precondition does NOT unlock this"

      # The stored claim never changed — the honest worker still owns the row…
      content = task_content("cchw3-sub")
      assert content["claim"]["worker"] == "honest-worker"
      assert content["claim"]["epoch"] == epoch

      # …and the sanctioned front door is NOT collateral damage: the honest owner
      # closes with its real epoch, attribution intact.
      assert {:ok, %Barkpark.Content.Document{} = closed} =
               Barkpark.Tasks.close(claimed.id, "honest-worker", observed_epoch: epoch)

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["claim"]["closed_by"] == "honest-worker"
    end

    test "SUBSTITUTION via createOrReplace carrying a foreign claim is refused even with a correct rev",
         %{conn: conn} do
      create_claimed_task(conn, "cchw3-sub-cor")

      # A whole-document write whose `claim` is a DIFFERENT map. The revision
      # precondition unlocks the lifecycle guard; the claim fence stops the
      # substitution anyway.
      attrs =
        "cchw3-sub-cor"
        |> task_doc(%{
          "claim" => %{"worker" => "attacker", "epoch" => 99, "ts_iso" => "2026-07-21T00:00:00Z"}
        })
        |> Map.put("ifRevisionID", task_rev("cchw3-sub-cor"))

      resp = mutate(conn, [%{"createOrReplace" => attrs}])

      assert resp.status == 422
      assert [message] = Jason.decode!(resp.resp_body)["error"]["details"]["claim"]
      assert message =~ "cannot be reassigned"
      assert task_content("cchw3-sub-cor")["claim"]["worker"] == "honest-worker"
    end

    test "an unrelated patch that leaves the claim byte-identical is NOT fenced", %{conn: conn} do
      create_claimed_task(conn, "cchw3-unrelated")

      # `now == was` — the claim is untouched, so a patch to any other field must
      # pass. This is the guard-rail against over-broad refusal (the collateral
      # the fence must not cause).
      resp =
        mutate(conn, [%{"patch" => task_patch("cchw3-unrelated", %{"priority" => 3})}])

      assert resp.status == 200
      content = task_content("cchw3-unrelated")
      assert content["priority"] == 3
      assert content["claim"]["worker"] == "honest-worker"
    end

    # ── fixtures ───────────────────────────────────────────────────────────

    defp create_claimed_task(conn, id, content_extra \\ %{}) do
      create_task(
        conn,
        id,
        Map.merge(
          %{
            "claim" => %{
              "worker" => "honest-worker",
              "epoch" => 1,
              "ts_iso" => "2026-07-21T00:00:00Z"
            }
          },
          content_extra
        )
      )
    end

    # A whole-document create-family payload for `id` — the shape a
    # createOrReplace/replace caller sends. Note what it does NOT carry:
    # `claim`. That absence IS the door.
    defp task_doc(id, content_extra) do
      %{
        "_id" => id,
        "_type" => "task",
        "title" => "Guard fixture #{id}",
        "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)
      }
    end

    defp task_rev(id) do
      {:ok, doc} = Content.get_document("drafts.#{id}", "task", "test")
      doc.rev
    end

    defp ready_doc_ids(scope), do: scope |> Barkpark.Tasks.ready() |> Enum.map(& &1.doc_id)
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

  # ── cch-w28 / D307+D331: the filing-law door guard at the birth seat ──────
  #
  # Standing Law 0 says a row filed under `cloud-console-hardening-epic`
  # declares WHICH SURFACE it is about. Wave 27 proved by hand that the law can
  # hold; this is the door that makes it hold without a person watching, and
  # these tests exist to prove the door can BOTH refuse and pass — a guard that
  # cannot lose is a sentence with an exit code.
  #
  # Every refusal test below FAILS against the pre-guard tree (verified by
  # reverting the two `with`-chain lines in `writer.ex` and re-running): the
  # refusals return 200 / 201 and the rows persist.
  # ── the merge-gate flag advisory, pinned at the HTTP seam ──
  #
  # The wording nag (PR #12975) fired only into Logger — its sole reader was
  # the server journal, so 669 open rows accumulated the MERGE-GATED wording
  # without the machine-readable flag while every author stayed uninformed.
  # This pins the fix: the advisory rides the mutate SUCCESS envelope as a
  # `warnings` entry, which the bp CLI prints to stderr at the moment the
  # criterion is authored.
  describe "merge-gate flag advisory rides the mutate envelope" do
    setup do
      register_task_schemas!()
      :ok
    end

    defp gate_task_create(id, criteria) do
      %{
        "create" => %{
          "_id" => id,
          "_type" => "task",
          "title" => "Merge-gate advisory fixture #{id}",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "priority" => 2,
            "acceptance_criteria" => criteria
          }
        }
      }
    end

    test "an unflagged MERGE-GATED criterion puts a warning ON THE RESPONSE, not just the journal",
         %{conn: conn} do
      resp =
        mutate(conn, [
          gate_task_create("mg-advisory-unflagged", [
            %{"criterion" => "the suite is green", "met" => false},
            %{
              "criterion" =>
                "[MERGE-GATED] PR merged to main (LEAD closes this criterion on merge).",
              "met" => false
            }
          ])
        ])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert [warning] =
               Enum.filter(body["warnings"] || [], &(&1["code"] == "merge_gate_unflagged"))

      assert warning["severity"] == "warning"
      assert warning["message"] =~ "[1]"
      assert warning["message"] =~ "merge_gate\": true"

      # Advisory, never a gate: the write itself landed (as the draft row —
      # a mutate `create` is draft-first, so the result id carries the prefix).
      assert [%{"id" => "drafts.mg-advisory-unflagged"}] = body["results"]
    end

    test "the same criterion CARRYING the flag draws no merge-gate warning", %{conn: conn} do
      resp =
        mutate(conn, [
          gate_task_create("mg-advisory-flagged", [
            %{
              "criterion" =>
                "[MERGE-GATED] PR merged to main (LEAD closes this criterion on merge).",
              "met" => false,
              "merge_gate" => true
            }
          ])
        ])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Enum.filter(body["warnings"] || [], &(&1["code"] == "merge_gate_unflagged")) == []
    end
  end

  describe "filing-law door guard (cch-w28, D307/D331)" do
    @epic "cloud-console-hardening-epic"

    test "an OFF-VOCABULARY surface on a create under the epic is REFUSED 422", %{conn: conn} do
      resp = file_row(conn, "cchw28-offvocab", %{"surface" => "dashboard"})

      assert resp.status == 422
      error = Jason.decode!(resp.resp_body)["error"]
      assert error["code"] == "validation_failed"

      # The refusal TEACHES: it names the closed vocabulary and the escape.
      assert [message] = error["details"]["surface"]
      assert message =~ ~s("console")
      assert message =~ ~s("instrument")
      assert message =~ ~s("ledger")

      # Side-effect-free: the refused row was never filed.
      assert missing?("cchw28-offvocab")
    end

    test "EXACT CASE: a differently-cased term is off-vocabulary too", %{conn: conn} do
      resp = file_row(conn, "cchw28-cased", %{"surface" => "Console"})

      assert resp.status == 422
      assert missing?("cchw28-cased")
    end

    test "each of the three sanctioned terms PASSES and reads back from storage",
         %{conn: conn} do
      for term <- ~w(console instrument ledger) do
        resp = file_row(conn, "cchw28-ok-#{term}", %{"surface" => term})

        assert resp.status == 200
        assert task_content("cchw28-ok-#{term}")["surface"] == term
      end
    end

    test "an ABSENT surface is WARNED, not refused — the backfill is not producible",
         %{conn: conn} do
      # 5 of 56 live orphans carry a surface; arming presence today would refuse
      # 91% of legitimate filings. This is the deliberate soft tier.
      resp = file_row(conn, "cchw28-absent", %{})

      assert resp.status == 200
      content = task_content("cchw28-absent")
      assert content["parent_id"] == @epic
      refute Map.has_key?(content, "surface")
    end

    test "a BLANK surface takes the warn tier, not the refusal tier", %{conn: conn} do
      resp = file_row(conn, "cchw28-blank", %{"surface" => "   "})

      assert resp.status == 200
      assert task_content("cchw28-blank")["surface"] == "   "
    end

    test "THE SCOPING: the same off-vocabulary term passes outside the epic", %{conn: conn} do
      # The load-bearing leg. Without it this guard is a filing law armed over
      # the WHOLE roster and every task fixture in the repository 422s.
      resp =
        create_row(conn, "cchw28-other-epic", %{
          "parent_id" => "some-other-epic",
          "surface" => "dashboard"
        })

      assert resp.status == 200
      assert task_content("cchw28-other-epic")["surface"] == "dashboard"

      resp = create_row(conn, "cchw28-no-parent", %{"surface" => "dashboard"})
      assert resp.status == 200
      assert task_content("cchw28-no-parent")["surface"] == "dashboard"
    end

    test "a `drafts.`-prefixed parent_id cannot dodge the guard", %{conn: conn} do
      resp =
        create_row(conn, "cchw28-draft-parent", %{
          "parent_id" => "drafts." <> @epic,
          "surface" => "dashboard"
        })

      assert resp.status == 422
      assert missing?("cchw28-draft-parent")
    end

    test "the guard is a BIRTH guard: an UPDATE to a live epic row is untouched",
         %{conn: conn} do
      assert file_row(conn, "cchw28-live", %{"surface" => "console"}).status == 200

      # A patch that puts an off-vocabulary term on an EXISTING row is not this
      # guard's business — `prev_doc` is non-nil, so it head-matches away. Said
      # out loud because it is the guard's honest residual harm.
      resp =
        mutate(conn, [
          %{
            "patch" => %{
              "id" => "cchw28-live",
              "type" => "task",
              "set" => %{"surface" => "dashboard"}
            }
          }
        ])

      assert resp.status == 200
      assert task_content("cchw28-live")["surface"] == "dashboard"
    end

    # ── THE UPSERT BYPASS (do_upsert_document's own INSERT branch) ──────────
    #
    # `POST /api/documents/task` (LegacyController.create) reaches
    # `Content.upsert_document`, whose insert branch called NEITHER birth guard.
    # Measured on the pre-guard tree: 201 for an epic filing with an
    # off-vocabulary surface. This is that window, closed.

    test "the LEGACY create door refuses an off-vocabulary epic filing (was 201)",
         %{conn: conn} do
      resp = legacy_file(conn, "cchw28-legacy-offvocab", %{"surface" => "dashboard"})

      refute resp.status == 201
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "the LEGACY create door still files a sanctioned and an absent surface",
         %{conn: conn} do
      assert legacy_file(conn, "cchw28-legacy-ok", %{"surface" => "ledger"}).status == 201
      assert legacy_file(conn, "cchw28-legacy-absent", %{}).status == 201
    end

    # ── fixtures ───────────────────────────────────────────────────────────

    defp create_row(conn, id, content_extra) do
      mutate(conn, [
        %{
          "create" => %{
            "_id" => id,
            "_type" => "task",
            "title" => "Filing-law fixture #{id}",
            "content" =>
              Map.merge(
                %{"kind" => "task", "lifecycle_status" => "open", "priority" => 1},
                content_extra
              )
          }
        }
      ])
    end

    defp file_row(conn, id, content_extra),
      do: create_row(conn, id, Map.put(content_extra, "parent_id", @epic))

    # The legacy door folds every non-reserved top-level key into `content`,
    # and hardcodes dataset "production" — so this fixture reads back through
    # that dataset, not "test".
    defp legacy_file(conn, id, content_extra) do
      body =
        Map.merge(
          %{
            "id" => id,
            "title" => "Filing-law fixture #{id}",
            "kind" => "task",
            "lifecycle_status" => "open",
            "priority" => 1,
            "parent_id" => @epic
          },
          content_extra
        )

      conn |> authed() |> post("/api/documents/task", Jason.encode!(body))
    end

    defp missing?(id),
      do: match?({:error, _}, Content.get_document("drafts.#{id}", "task", "test"))
  end
end
