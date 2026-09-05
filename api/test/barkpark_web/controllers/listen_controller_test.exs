defmodule BarkparkWeb.ListenControllerTest do
  @moduledoc """
  SSE field-visibility leak-guard (Phase 3, core-auth).

  The live `receive` loop is not directly assertable from a test (the HTTP
  connection is long-lived), so the redaction step is exercised through the
  `ListenController.redacted_result/4` testing seam — the same `@doc false`
  public-seam convention this controller already uses for `replay_since/3`,
  `format_event/2` and `forward_event?/3`. Both the LIVE broadcast path and the
  Last-Event-ID REPLAY path funnel through that one function, so asserting it
  proves the invariant for both surfaces.

  Invariant: a non-encrypted `private` field must NEVER reach a non-admin
  subscriber; an admin subscriber sees it. The former `nil`-caller verbatim
  forward (a fail-OPEN back-compat seam) was REMOVED (ctx-s3) — an anonymous
  subscriber now re-renders through the fail-closed `%CallerContext{}` clause.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, MutationEvent}
  alias Barkpark.Crypto.FieldCipher
  alias BarkparkWeb.ListenController
  alias BarkparkWeb.Plugs.AcceptBarkparkVendor

  @dataset "ssetest"

  setup do
    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "body", "type" => "string"},
          %{"name" => "ssn", "type" => "string", "private" => true}
        ]
      },
      @dataset
    )

    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "drafts.l1",
          "title" => "L1",
          "content" => %{"body" => "ok", "ssn" => "111-22-3333"}
        },
        @dataset
      )

    %{doc: doc}
  end

  defp admin, do: %CallerContext{principal_type: :api_token, is_admin: true}
  defp reader, do: %CallerContext{principal_type: :api_token, token_id: "tok-r"}

  test "replay path: stored snapshot leaks the private field; a non-admin is redacted, admin is not" do
    ev =
      ListenController.replay_since(@dataset, 0)
      |> Enum.find(&(&1.doc_id == "drafts.l1"))

    assert ev, "expected a replayable mutation event for the seeded doc"
    # The stored mutation_events.document snapshot IS the leak surface — it holds
    # the private plaintext. Proving redaction happens at emit time, not at write.
    assert ev.document["ssn"] == "111-22-3333"

    redacted = ListenController.redacted_result(ev, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
    assert redacted["_id"] == "drafts.l1"

    assert ListenController.redacted_result(ev, @dataset, admin(), [])["ssn"] == "111-22-3333"
  end

  describe "keyset-paginated replay (bounded memory)" do
    test "returns ALL events across batch boundaries in strictly ascending id order" do
      # setup/0 already wrote drafts.l1; add 5 more so replay spans >2 batches
      # at batch: 2. A single-batch bug (stop after the first Repo.all) would
      # return only 2 of them.
      for i <- 1..5 do
        {:ok, _} =
          Content.create_document(
            "post",
            %{"doc_id" => "drafts.k#{i}", "title" => "K#{i}", "content" => %{"body" => "b"}},
            @dataset
          )
      end

      events = ListenController.replay_since(@dataset, 0, nil, batch: 2) |> Enum.to_list()

      k_ids =
        events |> Enum.map(& &1.doc_id) |> Enum.filter(&String.starts_with?(&1, "drafts.k"))

      # Every new doc surfaces — proves the loop kept fetching past batch 1.
      assert length(Enum.uniq(k_ids)) == 5

      # Strictly ascending, no dupes — proves the cursor advanced across
      # boundaries rather than re-reading or skipping a batch.
      ids = Enum.map(events, & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
    end

    test "workspace-scoped variant filters correctly ACROSS a batch boundary" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # Interleave A and B writes so A's events straddle >1 batch and a B row
      # sits between them — a per-batch join filter must drop every B row even
      # when it falls on a page boundary.
      for i <- 1..3 do
        {:ok, _} =
          create_document_in!(
            ws_a,
            proj_a,
            "post",
            %{"doc_id" => "a#{i}", "title" => "A#{i}"},
            @dataset
          )

        {:ok, _} =
          create_document_in!(
            ws_b,
            proj_b,
            "post",
            %{"doc_id" => "b#{i}", "title" => "B#{i}"},
            @dataset
          )
      end

      events = ListenController.replay_since(@dataset, 0, ws_a.id, batch: 2) |> Enum.to_list()
      doc_ids = Enum.map(events, & &1.doc_id)

      for i <- 1..3, do: assert("drafts.a#{i}" in doc_ids)

      refute Enum.any?(doc_ids, &String.starts_with?(&1, "drafts.b")),
             "CROSS-TENANT LEAK across a batch boundary: #{inspect(doc_ids)}"

      ids = Enum.map(events, & &1.id)
      assert ids == Enum.sort(ids)
    end
  end

  test "live path: re-renders the CURRENT document under the subscriber", %{doc: doc} do
    # A live broadcast forwards a pre-rendered, unredacted envelope.
    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    assert msg.document["ssn"] == "111-22-3333"

    redacted = ListenController.redacted_result(msg, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
    assert redacted["_id"] == doc.doc_id

    assert ListenController.redacted_result(msg, @dataset, admin(), [])["ssn"] == "111-22-3333"
  end

  test "anonymous re-render fails closed; removed nil seam forwards nothing", %{doc: doc} do
    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    assert msg.document["ssn"] == "111-22-3333"

    # The deleted `nil` clause used to forward `msg.document` verbatim (fail-OPEN
    # leak). An anonymous %CallerContext{} re-renders from the DB and drops the
    # private field — the exact chokepoint a real anonymous SSE subscriber rides.
    redacted = ListenController.redacted_result(msg, @dataset, CallerContext.anonymous(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["_id"] == doc.doc_id
  end

  describe "live-leg admin fast-path (efficiency: get_document elided) — task-4469f80374b0bd24" do
    # A broadcast snapshot that DIFFERS from the stored DB row by a sentinel key
    # the row does NOT have. The sentinel can ONLY survive if the live leg
    # forwards `msg.document` verbatim; a re-fetch + re-render from the DB would
    # never reproduce it. So its presence PROVES the per-event Content.get_document
    # round-trip was elided; its absence PROVES a re-fetch happened.
    defp tainted_msg(doc) do
      snapshot =
        doc
        |> Envelope.render(nil, :internal)
        |> Map.put("_forwarded_only_marker", "sentinel")

      %{doc_id: doc.doc_id, type: "post", document: snapshot}
    end

    test "an admin caller forwards the broadcast snapshot WITHOUT re-fetching", %{doc: doc} do
      msg = tainted_msg(doc)

      result = ListenController.live_result(msg, @dataset, admin(), caller_context: admin())

      # Byte-identical to the in-hand snapshot → no DB fetch, no re-render.
      assert result == msg.document
      assert result["_forwarded_only_marker"] == "sentinel"
    end

    test "a redacting (non-admin) caller STILL re-derives from the DB — leak guard intact",
         %{doc: doc} do
      msg = tainted_msg(doc)

      result = ListenController.live_result(msg, @dataset, reader(), caller_context: reader())

      # The sentinel is GONE → the DB was re-fetched + re-rendered (not forwarded).
      refute Map.has_key?(result, "_forwarded_only_marker"),
             "non-admin caller forwarded the broadcast snapshot — redundant-fetch fix leaked past the admin guard"

      # And the private field is still dropped → field-visibility redaction preserved.
      refute Map.has_key?(result, "ssn")
      assert result["body"] == "ok"
      assert result["_id"] == doc.doc_id
    end

    test "a non-admin api_token that BYPASSES owner scoping is still NOT forwarded (fail closed)",
         %{doc: doc} do
      # `reader()` is a plain api_token: Scope.scope_to_owner leaves its query
      # untouched (ownership bypass), yet Envelope.render STILL redacts its
      # private fields. The fast-path must key on is_admin, NOT on the ownership
      # bypass — otherwise a read-token subscriber would receive private fields.
      msg = tainted_msg(doc)
      result = ListenController.live_result(msg, @dataset, reader(), caller_context: reader())

      refute Map.has_key?(result, "_forwarded_only_marker")
      refute Map.has_key?(result, "ssn")
    end
  end

  test "delete event (document gone) redacts the FROZEN snapshot, not a re-render" do
    # No live document exists for this id — only the stored snapshot remains.
    snapshot = %{
      "_id" => "drafts.gone",
      "_type" => "post",
      "title" => "G",
      "body" => "ok",
      "ssn" => "999-99-9999"
    }

    ev = %{doc_id: "drafts.gone", type: "post", document: snapshot}

    redacted = ListenController.redacted_result(ev, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["title"] == "G"
    assert redacted["_id"] == "drafts.gone"
    # Admin still sees the snapshot whole.
    assert ListenController.redacted_result(ev, @dataset, admin(), [])["ssn"] == "999-99-9999"
  end

  describe "owner-row ACL on the SSE stream (Phase 4)" do
    @owned_type "secret_note"

    setup do
      Content.upsert_schema(
        %{
          "name" => @owned_type,
          "title" => "Secret Note",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "string"}]
        },
        @dataset
      )

      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()

      {:ok, doc} =
        Content.create_document(
          @owned_type,
          %{"doc_id" => "drafts.owned-a", "title" => "A-secret", "content" => %{"body" => "ok"}},
          @dataset,
          caller_context: CallerContext.from_user(user_a)
        )

      %{owned: doc, user_a: user_a, user_b: user_b}
    end

    test "a non-owner is DROPPED, not handed the frozen snapshot of another user's owned row",
         %{owned: doc, user_a: a, user_b: b} do
      msg = %{doc_id: doc.doc_id, type: @owned_type, document: Envelope.render(doc)}

      # User B (non-owner, same dataset) must receive NOTHING for A's owned row,
      # over both the live and the replay leg (one function, both surfaces).
      assert :drop ==
               ListenController.redacted_result(
                 msg,
                 @dataset,
                 CallerContext.from_user(b),
                 caller_context: CallerContext.from_user(b)
               )

      # The owner A still gets a re-render of their own row.
      a_result =
        ListenController.redacted_result(
          msg,
          @dataset,
          CallerContext.from_user(a),
          caller_context: CallerContext.from_user(a)
        )

      assert a_result["_id"] == doc.doc_id

      # An admin (token) sees all — never dropped.
      admin_result =
        ListenController.redacted_result(msg, @dataset, admin(), caller_context: admin())

      assert admin_result["_id"] == doc.doc_id
    end

    test "a genuine delete (row gone) of an owner_scoped doc still redacts the snapshot, not :drop",
         %{user_b: b} do
      snapshot = %{"_id" => "drafts.gone-owned", "_type" => @owned_type, "title" => "G"}
      ev = %{doc_id: "drafts.gone-owned", type: @owned_type, document: snapshot}

      # No row exists for this id → it's a delete, not an ACL denial → redact +
      # forward (owner_scoped_denied?/3 requires the row to still be present).
      result =
        ListenController.redacted_result(
          ev,
          @dataset,
          CallerContext.from_user(b),
          caller_context: CallerContext.from_user(b)
        )

      assert result["title"] == "G"
    end
  end

  test "encrypted field never streams plaintext to a non-admin (schema-free guard)" do
    enc = FieldCipher.encrypt("ssn-enc", "dataset:#{@dataset}")

    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.l2", "title" => "L2", "content" => %{"ssn" => enc, "body" => "ok"}},
        @dataset
      )

    msg = %{doc_id: doc.doc_id, type: "post", document: Envelope.render(doc)}
    redacted = ListenController.redacted_result(msg, @dataset, reader(), [])
    refute Map.has_key?(redacted, "ssn")
    assert redacted["body"] == "ok"
  end

  describe "SSE Accept negotiation (spec-compliant text/event-stream)" do
    # The listen action send_chunked's then blocks in a long-lived receive loop,
    # so a full `get/2` would hang — the 406 vs accept contract is proven at the
    # AcceptBarkparkVendor + `:accepts` negotiation seam the listen pipelines run
    # (`plug AcceptBarkparkVendor` then `plug :accepts ["json"]`), same reason
    # this controller is otherwise tested through seams (see @moduledoc).

    test "a bare `text/event-stream` Accept 406s under `:accepts [\"json\"]` (pre-fix behavior)" do
      conn = build_conn() |> put_req_header("accept", "text/event-stream")

      assert_raise Phoenix.NotAcceptableError, fn ->
        Phoenix.Controller.accepts(conn, ["json"])
      end
    end

    test "AcceptBarkparkVendor rewrites `text/event-stream` so `:accepts` negotiates json (200-able)" do
      conn =
        build_conn()
        |> put_req_header("accept", "text/event-stream")
        |> AcceptBarkparkVendor.call(AcceptBarkparkVendor.init([]))

      # Appended, NOT replaced — the streaming type survives; json is negotiable.
      assert get_req_header(conn, "accept") == ["text/event-stream, application/json"]

      # The exact negotiation the listen pipelines run no longer raises → the
      # request reaches ListenController (which sets its own text/event-stream
      # response content-type + 200), instead of 406-ing in the pipeline.
      negotiated = Phoenix.Controller.accepts(conn, ["json"])
      refute negotiated.halted
      # NOT flagged as a vendor response — the controller owns its content-type.
      refute negotiated.assigns[:barkpark_vendor_accept]
    end
  end

  test "live event carries previousRev from the broadcast, matching the replay serialization" do
    # A live broadcast msg (content/broadcast.ex shape) carrying a REAL
    # previous_rev — the value a rev/CAS chain is built from.
    msg = %{
      event_id: 42,
      mutation: "update",
      type: "post",
      doc_id: "drafts.l1",
      rev: "rev-new",
      previous_rev: "rev-old",
      document: %{"_id" => "drafts.l1", "body" => "ok"}
    }

    live_json =
      msg
      |> ListenController.live_event(msg.document)
      |> ListenController.format_event(@dataset)
      |> frame_data()

    # Pre-fix the live loop hardcoded previous_rev: nil → this was null.
    assert live_json["previousRev"] == "rev-old"

    # The SAME event over the Last-Event-ID replay leg (a %MutationEvent{}) must
    # serialize previousRev identically — the live/replay parity the fix restores.
    replay_json =
      %MutationEvent{
        id: 42,
        mutation: "update",
        type: "post",
        doc_id: "drafts.l1",
        rev: "rev-new",
        previous_rev: "rev-old",
        document: msg.document
      }
      |> ListenController.format_event(@dataset)
      |> frame_data()

    assert replay_json["previousRev"] == live_json["previousRev"]
  end

  # ---------------------------------------------------------------------------
  # Listener egress guard (PDF-D18): a `type:"listener"` presence broadcast NEVER
  # rides the SSE fan-out — not even to an unscoped (nil-workspace) subscriber,
  # which is the exact live leak (eventId 70357). Mirrors the Sync.Outbox
  # exclusion (#5626). MUTATION-PROOF: remove the `%{type: "listener"}` clause in
  # forward_event?/2 and the first two assertions below flip to `true` and fail.
  # ---------------------------------------------------------------------------
  describe "forward_event?/2 — listener presence never fans out" do
    test "dropped for an UNSCOPED (nil-workspace) subscriber — the live leak" do
      refute ListenController.forward_event?(%{type: "listener", workspace_id: nil}, nil)
    end

    test "dropped for a same-workspace subscriber that would otherwise match" do
      refute ListenController.forward_event?(
               %{type: "listener", workspace_id: "ws-1"},
               "ws-1"
             )
    end

    test "a non-listener event is still forwarded (guard is type-narrow)" do
      assert ListenController.forward_event?(%{type: "post", workspace_id: nil}, nil)

      assert ListenController.forward_event?(
               %{type: "post", workspace_id: "ws-1"},
               "ws-1"
             )
    end
  end

  # Parse the JSON payload out of an SSE frame ("id: ..\nevent: ..\ndata: {json}\n\n").
  defp frame_data(frame) do
    frame
    |> String.split("data: ", parts: 2)
    |> List.last()
    |> String.trim_trailing("\n")
    |> Jason.decode!()
  end
end
