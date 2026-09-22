defmodule BarkparkWeb.TasksFlightRecorderTest do
  @moduledoc """
  task-a42dccec2fe4a406, criteria 0 and 1 — THE FLIGHT RECORDER ON THE WIRE.

  The CLI has written a schema=1 priming manifest to a LOCAL directory since
  PR #19114. This proves the ledger half: the manifest reaches the row at claim,
  the agent's compact reaches it at close, both read back through `bp task get`'s
  own door (`GET /v1/tasks/:doc_id`), and the bound refuses with a NAMED code
  without writing anything.

  ## The two directions, and why the negative one is load-bearing

  A write is easy to assert and easy to make vacuous. The half that makes the key
  MEAN something is the control: a claim carrying NO manifest must store nothing
  and read back with the key ABSENT — not `null`, not `{}`. Three-state law:
  absent is UNMEASURED, and a placeholder would convert "nobody looked" into a
  measurement of nothing. So the byte-identity of a manifest-less claim gets its
  own test, and it compares the WHOLE claim map against a claim issued on an
  identical row without the key — not just `refute Map.has_key?`, because a key
  added elsewhere in the map would slip past that.

  ## The bound

  `context_compact` is agent prose bounded at 16 KB. Both arms are here:
  under-bound STORED, over-bound REFUSED — and the refusal is measured by what it
  did NOT do: the row's `rev` is compared before and after, so "nothing was
  written" is a read of the store rather than a reading of the status code.

  ## MUTATION PROOF (pasted in the PR body)

    * delete `FlightRecorder.put_priming_start/2`'s Map.put arm (make both arms
      return `claim`) -> the claim-stores-it test REDS, the control stays green.
    * delete the `byte_size(value) > @max_bytes` clause in
      `validate_context_compact/1` -> the over-bound test REDS (200 instead of
      422, and the rev moves), the under-bound test stays green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.FlightRecorder

  @token "barkpark-test-flight-recorder"
  @dataset "production"
  @worker "api-flight-w1"

  # The schema=1 manifest EXACTLY as internal/cli/tasks_priming_manifest.go
  # serializes it — pointers become JSON nulls, and the nulls are the three-state
  # law travelling on the wire. It is stored verbatim; this door does not police
  # the manifest's internal shape (the schema version travels inside it).
  @manifest %{
    "schema" => 1,
    "doc_id" => "task-x",
    "worker" => @worker,
    "claimed_at" => "2026-09-18T09:00:00Z",
    "model" => "opus-5",
    "effort" => "medium",
    "worktree" => "/Volumes/SATECHI/github/barkpark",
    "head" => "90d237d36825ce1b413aff91a6255bfdd77494b5",
    "dirty_tree" => false,
    "primers" => [
      %{"path" => "CLAUDE.md", "sha256" => String.duplicate("a", 64), "bytes" => 4096}
    ],
    "primed" => true,
    "digest" => String.duplicate("b", 64)
  }

  setup do
    {:ok, _} = Auth.create_token(@token, "test-flight-recorder", "test", ["read", "write"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # One met criterion keeps the PDS-D291 close-artifact gate and the D289
  # criteria gate out of every measurement here — neither is what this file is
  # about, and a row that trips them would red these tests for the wrong reason.
  defp task!(scope) do
    doc_id = uniq("flight")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{"criterion" => "built", "met" => true, "evidence" => "PR #19114"}
            ]
          }
        },
        @dataset,
        scope
      )

    # The BIRTH doc_id, not the one handed to create_document: the birth fence
    # publishes a task as its `drafts.` twin, so a lookup by the bare slug finds
    # nothing. Every URL and every read below rides what the store actually
    # holds.
    doc
  end

  defp claim(conn, %Document{doc_id: doc_id}, body),
    do:
      conn
      |> authed()
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(Map.put(body, :worker_id, @worker)))

  defp close(conn, %Document{doc_id: doc_id}, body),
    do: conn |> authed() |> post("/v1/tasks/#{doc_id}/close", Jason.encode!(body))

  defp show(conn, %Document{doc_id: doc_id}),
    do: conn |> authed() |> get("/v1/tasks/#{doc_id}") |> json_response(200)

  # THE STORED ROW, never the returned envelope — by PRIMARY KEY, so no slug
  # spelling can make this read the wrong row.
  defp row(%Document{id: id}), do: Repo.get!(Document, id)
  defp stored_claim(doc), do: row(doc).content["claim"] || %{}

  describe "criterion 0 — priming_start at claim" do
    test "a claim carrying the manifest stores it under claim.priming_start and bp task get shows it",
         %{conn: conn, scope: scope} do
      doc_id = task!(scope)

      body = conn |> claim(doc_id, %{priming_start: @manifest}) |> json_response(200)
      assert body["ok"] == true

      # 1. the STORE holds it, verbatim, nulls and all.
      assert stored_claim(doc_id)["priming_start"] == @manifest

      # 2. and the READ DOOR `bp task get <id> -o json` uses shows it under the
      #    SAME one documented key. A write nobody can read back is not a record.
      shown = show(conn, doc_id)

      assert get_in(shown, ["doc", "claim", "priming_start"]) == @manifest
      assert get_in(shown, ["doc", "claim", "priming_start", "schema"]) == 1

      # CONTROL ON THE READ: this is the claim THIS call wrote, so a foreign or
      # empty map cannot masquerade as a pass.
      assert get_in(shown, ["doc", "claim", "worker"]) == @worker
      assert get_in(shown, ["doc", "claim", "epoch"]) == 1
    end

    test "THE CONTROL: a claim with NO manifest is byte-identical to today's, key ABSENT",
         %{conn: conn, scope: scope} do
      with_id = task!(scope)
      without_id = task!(scope)

      assert %{"ok" => true} =
               conn |> claim(with_id, %{priming_start: @manifest}) |> json_response(200)

      assert %{"ok" => true} = conn |> claim(without_id, %{}) |> json_response(200)

      bare = stored_claim(without_id)
      primed = stored_claim(with_id)

      # THE KEY SET, not `refute Map.has_key?` alone. The claim map a
      # manifest-less claim writes must carry EXACTLY the pre-feature keys —
      # enumerated here, the same five `claim_override_persisted_test.exs`
      # measured on a live row — so a stray key added anywhere else in the map
      # reds this too, which a single-key assertion would not.
      #
      # The VALUES cannot be compared across two rows (ts_iso and the
      # title-derived work digests differ by construction); the shape is what
      # byte-identity means here, and the shape is what is asserted.
      assert Enum.sort(Map.keys(bare)) ==
               ~w(epoch ts_iso work_digest work_field_digests worker)

      assert Enum.sort(Map.keys(primed)) ==
               ~w(epoch priming_start ts_iso work_digest work_field_digests worker)

      refute Map.has_key?(bare, "priming_start"),
             "absent means the KEY is absent — not null, not %{}"

      # And the read door agrees: no key, rather than a null the caller would
      # have to tell apart from a measured nothing.
      shown = show(conn, without_id)
      refute Map.has_key?(shown["doc"]["claim"], "priming_start")
    end

    test "an oversized manifest is refused with its OWN named code and nothing is written",
         %{conn: conn, scope: scope} do
      doc_id = task!(scope)
      before = row(doc_id)

      fat = Map.put(@manifest, "primers", [%{"path" => String.duplicate("p", 20_000)}])

      body = conn |> claim(doc_id, %{priming_start: fat}) |> json_response(422)
      assert body["reason"] == "priming_start_too_large"
      assert body["limit_bytes"] == FlightRecorder.max_bytes()

      after_row = row(doc_id)
      assert after_row.rev == before.rev, "a refused claim must not move the row's rev"
      assert after_row.content["lifecycle_status"] == "open"
      refute Map.has_key?(after_row.content, "claim")
    end
  end

  describe "criterion 1 — context_compact at close, bounded at 16 KB" do
    test "an under-bound compact is stored and shown by bp task get",
         %{conn: conn, scope: scope} do
      doc_id = task!(scope)

      %{"doc" => %{"claim" => %{"epoch" => epoch}}} =
        conn |> claim(doc_id, %{}) |> json_response(200)

      compact =
        "read claim.ex + close.ex; the seam is do_claim_resolved/8. 16 KB bound is byte_size."

      assert %{"ok" => true} =
               conn
               |> close(doc_id, %{
                 worker_id: @worker,
                 observed_epoch: epoch,
                 reason: "landed #19114 @ 90d237d368 — the recorder reaches the ledger"
               })
               |> json_response(200)

      # The close above carried NO compact — the control for this arm, proving
      # the stored value below came from the compact and not from the close.
      refute Map.has_key?(stored_claim(doc_id), "context_compact")

      # Now the same shape WITH one, on a fresh row.
      doc2 = task!(scope)
      %{"doc" => %{"claim" => %{"epoch" => e2}}} = conn |> claim(doc2, %{}) |> json_response(200)

      assert %{"ok" => true} =
               conn
               |> close(doc2, %{
                 worker_id: @worker,
                 observed_epoch: e2,
                 reason: "landed #19114 @ 90d237d368 — the recorder reaches the ledger",
                 context_compact: compact
               })
               |> json_response(200)

      assert stored_claim(doc2)["context_compact"] == compact

      shown = show(conn, doc2)
      assert get_in(shown, ["doc", "claim", "context_compact"]) == compact
      assert get_in(shown, ["doc", "lifecycle_status"]) == "done"
    end

    test "an OVER-bound compact is refused by name and the row's rev is UNCHANGED",
         %{conn: conn, scope: scope} do
      doc_id = task!(scope)

      %{"doc" => %{"claim" => %{"epoch" => epoch}}} =
        conn |> claim(doc_id, %{}) |> json_response(200)

      before = row(doc_id)
      over = String.duplicate("x", FlightRecorder.max_bytes() + 1)

      body =
        conn
        |> close(doc_id, %{
          worker_id: @worker,
          observed_epoch: epoch,
          reason: "landed #19114 @ 90d237d368",
          context_compact: over
        })
        |> json_response(422)

      assert body["ok"] == false
      assert body["reason"] == "context_compact_too_large"
      assert body["limit_bytes"] == FlightRecorder.max_bytes()
      assert body["message"] =~ "rev is unchanged"

      # NOTHING WAS WRITTEN — read from the store, not inferred from the status.
      after_row = row(doc_id)
      assert after_row.rev == before.rev
      assert after_row.content["lifecycle_status"] == "in_progress"
      refute Map.has_key?(after_row.content["claim"], "context_compact")
      refute Map.has_key?(after_row.content, "close_reason")

      # And the row is still closeable: the refusal cost the caller nothing but
      # the round trip. A bound that stranded the row would be worse than none.
      assert %{"ok" => true} =
               conn
               |> close(doc_id, %{
                 worker_id: @worker,
                 observed_epoch: epoch,
                 reason: "landed #19114 @ 90d237d368",
                 context_compact: String.slice(over, 0, 128)
               })
               |> json_response(200)
    end

    test "EXACTLY at the bound lands — the wall is `>`, not `>=`",
         %{conn: conn, scope: scope} do
      doc_id = task!(scope)

      %{"doc" => %{"claim" => %{"epoch" => epoch}}} =
        conn |> claim(doc_id, %{}) |> json_response(200)

      at = String.duplicate("y", FlightRecorder.max_bytes())

      assert %{"ok" => true} =
               conn
               |> close(doc_id, %{
                 worker_id: @worker,
                 observed_epoch: epoch,
                 reason: "landed #19114 @ 90d237d368",
                 context_compact: at
               })
               |> json_response(200)

      assert byte_size(stored_claim(doc_id)["context_compact"]) == FlightRecorder.max_bytes()
    end
  end

  describe "the bound is BYTES, not characters" do
    test "a multi-byte compact under the CHARACTER count but over the BYTE count is refused",
         %{conn: conn, scope: scope} do
      # THE LESSON THIS ENCODES: a label saying "bytes" over a character count
      # hides for as long as the input is ASCII. `String.length/1` of this value
      # is max_bytes/3 — comfortably "under" a 16 384 limit read as characters —
      # while `byte_size/1` is over it. The only input that tells the two
      # readings apart is one that is not ASCII, so it is the one that is tested.
      doc_id = task!(scope)

      %{"doc" => %{"claim" => %{"epoch" => epoch}}} =
        conn |> claim(doc_id, %{}) |> json_response(200)

      # "…" is 3 bytes, 1 codepoint.
      multi = String.duplicate("…", div(FlightRecorder.max_bytes(), 3) + 1)
      assert String.length(multi) < FlightRecorder.max_bytes()
      assert byte_size(multi) > FlightRecorder.max_bytes()

      body =
        conn
        |> close(doc_id, %{
          worker_id: @worker,
          observed_epoch: epoch,
          reason: "landed #19114 @ 90d237d368",
          context_compact: multi
        })
        |> json_response(422)

      assert body["reason"] == "context_compact_too_large"
    end
  end
end
