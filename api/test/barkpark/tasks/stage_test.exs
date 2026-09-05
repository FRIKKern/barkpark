defmodule Barkpark.Tasks.StageTest do
  @moduledoc """
  Endpoint + primitive tests for the sanctioned `POST /v1/tasks/:doc_id/stage`
  transition verb (charter D8). Kept in its OWN file (not
  tasks_controller_test.exs) so it is file-disjoint from the S6 slice.

  Proves:
    * the happy-path thought round-trip open → considering → researching → open,
      with `content.engagement` written on the thought states and CLEARED on
      the return to open;
    * an illegal stage (→ done) is a 422 naming `from` and `to`;
    * a `task.staged` mutation_event is emitted on a successful stage;
    * an invalid engagement object is a 400.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @token "barkpark-test-stage-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-stage", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp stage(conn, doc_id, body) do
    conn |> authed() |> post("/v1/tasks/#{doc_id}/stage", Jason.encode!(body))
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  # A REAL engagement lease, minted by the REAL verb (PDS wave 27). The lease
  # fixture is never hand-written: a scratch open row is staged to
  # `considering` through `Tasks.stage/3` and the map it wrote is returned
  # byte-for-byte, so "the lease survived byte-identical" is a claim about the
  # shape the minter actually produces (object/ts/lapse_ttl_seconds/lapses_at/
  # holder), not about a literal that could drift away from it.
  defp mint_lease!(scope, opts \\ []) do
    seed = mk_task!(uniq("stage-lease-mint"), scope)

    {:ok, doc} =
      Tasks.stage(seed.id, "considering",
        object: Keyword.get(opts, :object, "build"),
        holder: Keyword.get(opts, :holder, "thinker-1")
      )

    lease = doc.content["engagement"]
    assert is_map(lease), "mint_lease!/2 did not mint a lease"
    lease
  end

  # The task.stage verb summary as `/v1/capabilities` (and `bp task stage
  # --help`) advertise it — the single source we assert the reopen edges into.
  defp stage_verb_summary do
    Barkpark.Plugins.Tasks.cli_commands()
    |> Enum.find(&(&1.id == "task.stage"))
    |> Map.fetch!(:summary)
  end

  describe "POST /v1/tasks/:doc_id/stage — thought round-trip" do
    test "open → considering → researching → open writes then clears engagement",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-rt")
      task = mk_task!(doc_id, scope)

      # open → considering: engagement written, object=build.
      r1 =
        stage(conn, doc_id, %{
          state: "considering",
          object: "build",
          worker: "cycle-1",
          note: "weighing"
        })

      assert r1.status == 200
      p1 = Jason.decode!(r1.resp_body)
      assert p1["ok"] == true
      assert p1["doc"]["lifecycle_status"] == "considering"

      row1 = reload(task)
      assert row1.content["lifecycle_status"] == "considering"
      assert row1.content["engagement"]["object"] == "build"
      assert row1.content["engagement"]["holder"] == "cycle-1"
      assert is_binary(row1.content["engagement"]["ts"])
      # The note is DURABLE, so it does not ride the ephemeral lease.
      refute Map.has_key?(row1.content["engagement"], "note")
      assert row1.content["disposition_reason"] == "weighing"

      # considering → researching: engagement rewritten, object=research.
      r2 = stage(conn, doc_id, %{state: "researching", object: "research", worker: "cycle-1"})
      assert r2.status == 200
      row2 = reload(task)
      assert row2.content["lifecycle_status"] == "researching"
      assert row2.content["engagement"]["object"] == "research"

      # researching → open: engagement CLEARED.
      r3 = stage(conn, doc_id, %{state: "open", worker: "cycle-1"})
      assert r3.status == 200
      row3 = reload(task)
      assert row3.content["lifecycle_status"] == "open"
      refute Map.has_key?(row3.content, "engagement")
    end

    test "a successful stage emits a task.staged mutation_event", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-ev")
      task = mk_task!(doc_id, scope)

      assert stage(conn, doc_id, %{state: "considering", object: "research"}).status == 200

      events =
        Repo.all(
          from(e in MutationEvent,
            where: e.doc_id == ^task.doc_id and e.mutation == "task.staged"
          )
        )

      assert length(events) == 1
      [ev] = events
      assert ev.document["staged"]["from"] == "open"
      assert ev.document["staged"]["to"] == "considering"
      assert ev.document["staged"]["object"] == "research"
    end
  end

  # ─── The durable/ephemeral split (PDS wave 23) ────────────────────────────
  #
  # A `--note` is a DURABLE adjudication reason. It used to ride
  # `content.engagement`, which `TtlSweeper` deletes wholesale after 900 s — so
  # the verb returned ok:true on text with a 15-minute half-life. The note now
  # lands on `content.disposition_reason`, a key no sweeper owns, and the lease
  # states its own death (`lapse_ttl_seconds` / `lapses_at`).
  describe "POST /v1/tasks/:doc_id/stage — the note is durable, the lease is not" do
    test "a note lands on disposition_reason, NEVER on the swept engagement map",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-durable")
      task = mk_task!(doc_id, scope)

      reason = "parked: blocked on the crown proof, reopen when pds-w20 lands"

      resp =
        stage(conn, doc_id, %{
          state: "considering",
          object: "research",
          worker: "cycle-9",
          note: reason
        })

      assert resp.status == 200
      row = reload(task)

      # DURABLE: on the key the engagement sweep does not touch.
      assert row.content["disposition_reason"] == reason
      assert row.content["disposition_reason"] == row.content[Tasks.Stage.durable_reason_key()]

      # EPHEMERAL: lease fields only — object, holder, ts + the honesty pair.
      engagement = row.content["engagement"]
      refute Map.has_key?(engagement, "note")

      assert Enum.sort(Map.keys(engagement)) ==
               ~w(holder lapse_ttl_seconds lapses_at object ts)

      # …and the receipt STATES the half-life instead of implying permanence.
      ttl = Tasks.Stage.engagement_ttl_seconds()
      assert engagement["lapse_ttl_seconds"] == ttl
      {:ok, ts, _} = DateTime.from_iso8601(engagement["ts"])
      {:ok, lapses_at, _} = DateTime.from_iso8601(engagement["lapses_at"])
      assert DateTime.diff(lapses_at, ts, :second) == ttl

      # The rendered receipt (what `bp task stage` prints) carries both, so the
      # verb no longer returns a bare ok on a field it knows will be deleted.
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["doc"]["content"]["disposition_reason"] == reason
      assert body["doc"]["content"]["engagement"]["lapses_at"] == engagement["lapses_at"]
      assert body["doc"]["content"]["engagement"]["lapse_ttl_seconds"] == ttl
    end

    test "a note on a → open stage is recorded even though engagement is cleared",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-open-note")
      task = mk_task!(doc_id, scope, %{"lifecycle_status" => "considering"})

      assert stage(conn, doc_id, %{state: "open", note: "resolved: it is ready backlog now"}).status ==
               200

      row = reload(task)
      refute Map.has_key?(row.content, "engagement")
      assert row.content["disposition_reason"] == "resolved: it is ready backlog now"
    end

    test "a stage WITHOUT a note never erases an existing durable reason",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-keep-reason")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => "parked by the wave-22 triage"})

      assert stage(conn, doc_id, %{state: "considering", worker: "cycle-3"}).status == 200
      assert reload(task).content["disposition_reason"] == "parked by the wave-22 triage"

      # A blank note is no note — it must not blank the reason either.
      assert stage(conn, doc_id, %{state: "researching", note: "   "}).status == 200
      assert reload(task).content["disposition_reason"] == "parked by the wave-22 triage"
    end

    test "task.staged NAMES the key the note was routed to", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-notekey")
      task = mk_task!(doc_id, scope)

      assert stage(conn, doc_id, %{state: "considering", note: "why I parked it"}).status == 200

      [ev] =
        Repo.all(
          from(e in MutationEvent,
            where: e.doc_id == ^task.doc_id and e.mutation == "task.staged"
          )
        )

      assert ev.document["staged"]["note"] == "why I parked it"
      assert ev.document["staged"]["note_key"] == "disposition_reason"
      assert is_binary(ev.document["staged"]["lapses_at"])
      # Nothing was superseded here — the row carried no reason to begin with.
      refute ev.document["staged"]["superseded_note"]
    end

    # A NOTE REPLACES, IT DOES NOT APPEND — and the replaced text must not
    # vanish without a receipt. Measured on the live ledger before this arm
    # existed: two stages on one row left only the second note (69 chars ->
    # 58 chars), the first gone from the row with no trace in it. That is the
    # intended shape of a field holding ONE reason for ONE disposition, and the
    # wrong shape for how callers use it — cautions reading "do not execute this
    # row as written" were written here and were erasable by the next agent to
    # re-adjudicate. The row still holds one reason; the EVENT now carries the
    # one it displaced.
    test "task.staged carries the note it SUPERSEDED, so an overwrite leaves a receipt",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-supersede")
      task = mk_task!(doc_id, scope)

      assert stage(conn, doc_id, %{state: "considering", note: "FIRST: do not execute as written"}).status ==
               200

      assert stage(conn, doc_id, %{state: "researching", note: "SECOND: a different caution"}).status ==
               200

      # The row keeps ONE reason — the newest. That is unchanged and intended.
      assert reload(task).content["disposition_reason"] == "SECOND: a different caution"

      evs =
        Repo.all(
          from(e in MutationEvent,
            where: e.doc_id == ^task.doc_id and e.mutation == "task.staged",
            order_by: [asc: e.id]
          )
        )

      assert length(evs) == 2
      [first, second] = evs

      # The first stage superseded nothing.
      refute first.document["staged"]["superseded_note"]

      # The second names BOTH texts, so one event answers "what did I overwrite".
      assert second.document["staged"]["note"] == "SECOND: a different caution"
      assert second.document["staged"]["superseded_note"] == "FIRST: do not execute as written"
    end

    # The control that gives the arm above its meaning: a stage that writes NO
    # note supersedes nothing, so it must not report a supersession just because
    # the row happened to carry a reason already. Without this, the field could
    # be populated unconditionally and the arm above would still pass.
    test "a stage without a note reports NO supersession even when a reason exists",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-supersede-control")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => "an existing reason"})

      assert stage(conn, doc_id, %{state: "considering", worker: "cycle-9"}).status == 200

      [ev] =
        Repo.all(
          from(e in MutationEvent,
            where: e.doc_id == ^task.doc_id and e.mutation == "task.staged"
          )
        )

      refute ev.document["staged"]["superseded_note"]
      assert reload(task).content["disposition_reason"] == "an existing reason"
    end
  end

  describe "POST /v1/tasks/:doc_id/stage — illegal transitions 422" do
    test "staging to done is a 422 naming from and to", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-done")
      task = mk_task!(doc_id, scope)

      resp = stage(conn, doc_id, %{state: "done", worker: "cycle-1"})
      assert resp.status == 422

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "illegal_transition"
      assert payload["from"] == "open"
      assert payload["to"] == "done"
      assert payload["message"] =~ "considering|researching|open"

      # The row was NOT mutated.
      assert reload(task).content["lifecycle_status"] == "open"
    end

    test "staging to in_progress (claim's job) is a 422", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-inprog")
      _task = mk_task!(doc_id, scope)

      resp = stage(conn, doc_id, %{state: "in_progress", worker: "cycle-1"})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["reason"] == "illegal_transition"
    end

    test "staging to cancelled (close's job) is a 422", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-cancel")
      _task = mk_task!(doc_id, scope)

      resp = stage(conn, doc_id, %{state: "cancelled", worker: "cycle-1"})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["reason"] == "illegal_transition"
    end
  end

  describe "POST /v1/tasks/:doc_id/stage — terminal-reopen truth (S1)" do
    # The manifest description (bp task stage --help) MUST enumerate the reopen
    # edges the enforced gate (Transitions.legal?/2 for a stageable target)
    # sanctions. If a well-meaning edit trims one of these from the string, this
    # reds — the mutation-proof that the help text can no longer lie.
    test "manifest description names every terminal/blocked reopen edge" do
      summary = stage_verb_summary()

      for edge <- ~w(done→open cancelled→open blocked→open in_progress→open) do
        assert summary =~ edge,
               "task.stage manifest description omits the sanctioned reopen edge #{edge} — " <>
                 "bp task stage --help would lie about the enforced legal set"
      end

      # …and it still teaches the guarded truth: done/in_progress are NOT
      # user-stageable inbound; they are reached only through close/claim.
      assert summary =~ "done is reached ONLY through"
      assert summary =~ "in_progress ONLY through"
    end

    test "the four named reopen edges are exactly what Transitions.legal?/2 sanctions to a stageable target" do
      # Ground-truth: for every stageable target, which from-states are legal?
      # `open` is the only stageable target with terminal/blocked inbounds, and
      # they are precisely done, cancelled, blocked, in_progress (plus the
      # thought edges already advertised).
      statuses = Barkpark.Tasks.Transitions.statuses()
      # Cross-state inbounds to `open` (excluding the open→open same→same no-op).
      reopen_froms =
        for f <- statuses, f != "open", Barkpark.Tasks.Transitions.legal?(f, "open"), do: f

      assert Enum.sort(reopen_froms) ==
               Enum.sort(~w(considering researching blocked in_progress done cancelled))
    end

    test "stage(done-task-with-claim, open) SUCCEEDS and KEEPS the claim untouched",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-reopen")
      # A terminally-done task that still carries a claim map (the false-done
      # reopen recipe: a task marked done while a stale claim sits on it).
      claim = %{
        "worker" => "ghost-worker",
        "epoch" => 7,
        "ts_iso" => "2026-07-01T00:00:00Z",
        "now" => %{"text" => "stranded", "ts" => "2026-07-01T00:00:00Z"}
      }

      task =
        mk_task!(doc_id, scope, %{"lifecycle_status" => "done", "claim" => claim})

      resp = stage(conn, doc_id, %{state: "open", worker: "reconciler"})
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["doc"]["lifecycle_status"] == "open"

      row = reload(task)
      assert row.content["lifecycle_status"] == "open"
      # The claim survives verbatim — stage reopens without epoch machinery and
      # never rewrites the claim. Nobody may "fix" this sanctioned edge.
      assert row.content["claim"] == claim
    end
  end

  # ─── The terminal same-state adjudication edge (PDS wave 25 / D348) ───────
  #
  # `stage` is the ONLY sanctioned writer of content.disposition (the raw
  # /v1/data/mutate door refuses a disposition change on a type:task and names
  # this verb). While `check_stageable/2` gated the TARGET alone, a done row was
  # therefore UNWRITABLE: it could be adjudicated only by first being reopened,
  # which trades an off-vocabulary lie for a LIFECYCLE lie (a row saying `open`
  # while carrying claim.closed_by, back in `bp task ready`).
  #
  # The widening is `to in @stageable or from == to`. These fixtures pin BOTH
  # halves — that the adjudication door opened, and that the MOVEMENT door did
  # not. Revert the `or from == to` clause and the first test reds with
  # {:illegal_transition, "done", "done"}; delete the `and Transitions.legal?/2`
  # AND-guard and the open→done fixtures red instead.
  describe "POST /v1/tasks/:doc_id/stage — terminal same-state adjudication (PDS wave 25)" do
    test "done → done WITH a disposition succeeds, stays done, and leaves the claim byte-identical",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-done-done")

      # A properly CLOSED row: lifecycle done, with the close attribution the
      # adjudication must not disturb.
      claim = %{
        "worker" => "cycle-42",
        "epoch" => 3,
        "ts_iso" => "2026-07-01T00:00:00Z",
        "closed_by" => "cycle-42",
        "closed_at" => "2026-07-02T09:00:00Z",
        "now" => %{"text" => "shipped", "ts" => "2026-07-02T09:00:00Z"}
      }

      task = mk_task!(doc_id, scope, %{"lifecycle_status" => "done", "claim" => claim})

      resp =
        stage(conn, doc_id, %{
          state: "done",
          worker: "reconciler",
          disposition: "closed",
          note: "closed by #4711, verified against origin/main by content"
        })

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["doc"]["lifecycle_status"] == "done"

      row = reload(task)
      # NOT resurrected — it is still a finished row.
      assert row.content["lifecycle_status"] == "done"
      # The adjudication triple landed on the durable keys.
      assert row.content["disposition"] == "closed"

      assert row.content["disposition_reason"] ==
               "closed by #4711, verified against origin/main by content"

      # THE POINT: do_stage's write set excludes content.claim, so close
      # attribution survives an in-place adjudication byte-for-byte.
      assert row.content["claim"] == claim
      assert row.content["claim"]["closed_by"] == "cycle-42"
      assert row.content["claim"]["epoch"] == 3
    end

    test "the PRIMITIVE returns {:ok, doc} for done → done (the mutation quote)",
         %{scope: scope} do
      # Asserted at the primitive so the mutation proof reads in one line: with
      # the `or from == to` clause reverted this fails with the literal
      # `{:error, {:illegal_transition, "done", "done"}}` on the right.
      doc_id = uniq("stage-done-primitive")
      task = mk_task!(doc_id, scope, %{"lifecycle_status" => "done"})

      assert {:ok, %Document{} = doc} =
               Tasks.stage(task.id, "done", disposition: "closed", note: "adjudicated in place")

      assert doc.content["lifecycle_status"] == "done"
      assert doc.content["disposition"] == "closed"
    end

    test "the widening admits blocked → blocked and in_progress → in_progress too",
         %{conn: conn, scope: scope} do
      # Stated out loud rather than discovered later: `from == to` is not
      # done-specific. A live-claimed or blocked row can also carry a verdict in
      # place — and still cannot be MOVED anywhere new by this door.
      for state <- ~w(blocked in_progress) do
        doc_id = uniq("stage-same-#{state}")

        # PDS wave 27: the row carries a LIVE engagement lease into the
        # adjudication door. Wave 25 widened `check_stageable/2` without
        # revisiting `apply_engagement/5`, whose catch-all returned
        # `{Map.delete(content, "engagement"), nil}` for every non-thought
        # target — so this same-state stage DESTROYED the lease. RED WITHOUT
        # THE FIX: the engagement assertion below fails with `nil` on the left.
        lease = mint_lease!(scope, holder: "thinker-#{state}")
        task = mk_task!(doc_id, scope, %{"lifecycle_status" => state, "engagement" => lease})

        resp =
          stage(conn, doc_id, %{
            state: state,
            worker: "reconciler",
            disposition: "parked",
            note: "parked pending the ARM runner",
            "reopen-trigger": "when an ARM CI runner exists"
          })

        assert resp.status == 200, "same-state stage on #{state} was refused"

        row = reload(task)
        assert row.content["lifecycle_status"] == state
        assert row.content["disposition"] == "parked"
        assert row.content["reopen_trigger"] == "when an ARM CI runner exists"

        # THE RULING (PDS wave 27): a same-state stage ADJUDICATES, it does not
        # MOVE — so the lease survives BYTE-IDENTICAL, exactly as the claim map
        # does one test above. Not "still present": the same map, key for key.
        assert row.content["engagement"] == lease,
               "same-state adjudication on #{state} ALTERED the lease: " <>
                 inspect(row.content["engagement"])
      end
    end

    # ─── The reachability, exercised END TO END (PDS wave 27, criterion 2) ───
    #
    # Not argued — RUN. Every transition below goes through a sanctioned verb;
    # nothing writes `content` behind the primitives' backs except the initial
    # fixture, whose lease is itself minted by `Tasks.stage/3` (`mint_lease!/2`).
    #
    # THE CHAIN: `blocked` is claimable (`Validation.claimable_statuses/0` ==
    # ~w(open blocked)) and `claim.ex` never mentions `engagement` — so a lease
    # on a blocked row rides the REAL claim into `in_progress` untouched, and
    # lands on the adjudication door still live. That is the destroy path.
    test "END TO END: a lease rides a real claim into in_progress and survives the adjudication there",
         %{conn: conn, scope: scope} do
      lease = mint_lease!(scope, object: "build", holder: "thinker-e2e")
      doc_id = uniq("stage-lease-e2e")

      task =
        mk_task!(doc_id, scope, %{"lifecycle_status" => "blocked", "engagement" => lease})

      # 1. THE REAL CLAIM VERB — no engagement handling anywhere in it.
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "builder-e2e", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"
      assert claimed.content["claim"]["worker"] == "builder-e2e"

      assert claimed.content["engagement"] == lease,
             "the claim verb altered the lease: " <> inspect(claimed.content["engagement"])

      epoch = claimed.content["claim"]["epoch"]

      # 2. THE REAL STAGE VERB, same-state, on the live-claimed row. This is
      #    the door PDS-D348 asserted "mints or alters no claim or LEASE". The
      #    claim half was true; the lease half was not, until wave 27.
      resp =
        stage(conn, doc_id, %{
          state: "in_progress",
          worker: "reconciler",
          disposition: "parked",
          note: "parked mid-flight; the lease is the holder's, not the adjudicator's",
          "reopen-trigger": "when the builder returns"
        })

      assert resp.status == 200

      row = reload(task)
      assert row.content["lifecycle_status"] == "in_progress"
      assert row.content["disposition"] == "parked"

      assert row.content["engagement"] == lease,
             "the in_progress adjudication ate the lease a real claim carried in: " <>
               inspect(row.content["engagement"])

      # …and the claim the REAL verb minted is still byte-identical, so this
      # test also re-pins the half of PDS-D348 that always held.
      assert row.content["claim"]["worker"] == "builder-e2e"
      assert row.content["claim"]["epoch"] == epoch
    end

    test "the MOVEMENT door still clears the lease — the fix is scoped to from == to",
         %{scope: scope} do
      # The other side of the ruling, stated so a future edit cannot quietly
      # widen it: `considering → open` MOVES the row, resolves the thought, and
      # must still CLEAR the lease. Delete the `when from == to` guard from the
      # new clause and this reds.
      seed = mk_task!(uniq("stage-lease-movement"), scope)
      {:ok, thinking} = Tasks.stage(seed.id, "considering", object: "research")
      assert is_map(thinking.content["engagement"])

      {:ok, opened} = Tasks.stage(seed.id, "open", note: "promoted to backlog")
      assert opened.content["lifecycle_status"] == "open"
      refute Map.has_key?(opened.content, "engagement")
    end

    test "the adjudication door is not a movement door: open → done is STILL a 422",
         %{conn: conn, scope: scope} do
      # `from` is read from the locked row, never from caller input, so
      # `from == to` cannot be satisfied by a row that is not already there.
      doc_id = uniq("stage-open-to-done")
      task = mk_task!(doc_id, scope)

      resp = stage(conn, doc_id, %{state: "done", worker: "forger", disposition: "closed"})
      assert resp.status == 422

      payload = Jason.decode!(resp.resp_body)
      assert payload["reason"] == "illegal_transition"
      assert payload["from"] == "open"
      assert payload["to"] == "done"

      # Nothing was written — not the status, not the disposition.
      row = reload(task)
      assert row.content["lifecycle_status"] == "open"
      refute Map.has_key?(row.content, "disposition")
    end

    test "a same-state no-op on an UNKNOWN status is still refused (legal?/2 still gates)",
         %{scope: scope} do
      # `from == to` alone must NOT be sufficient — the AND with
      # Transitions.legal?/2 is what keeps a junk status string out of the door.
      refute Barkpark.Tasks.Transitions.legal?("marinating", "marinating")

      # Belt AND braces: such a row cannot even be persisted — the task schema
      # constrains lifecycle_status to the seven statuses — so the widened
      # clause has no reachable input outside that closed set.
      assert {:error, {:invalid_task_content, errors}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => uniq("stage-junk-state"),
                   "title" => "junk",
                   "content" => %{
                     "kind" => "task",
                     "acceptance_criteria" => [
                       %{
                         "criterion" => "the fixture states its bar",
                         "met" => false,
                         "evidence" => ""
                       }
                     ],
                     "lifecycle_status" => "marinating"
                   }
                 },
                 @dataset,
                 scope
               )

      assert errors["lifecycle_status"]
    end

    test "the manifest description NAMES the terminal same-state adjudication edge" do
      summary = stage_verb_summary()

      for edge <- ~w(done→done blocked→blocked in_progress→in_progress) do
        assert summary =~ edge,
               "task.stage manifest description omits the same-state adjudication edge #{edge}"
      end

      assert summary =~ "TERMINAL SAME-STATE ADJUDICATION EDGE"
      # …and it still says the widening does not forge a claim.
      assert summary =~ "content.claim"
    end
  end

  # ─── The reason carries its own falsifier (PDS wave 28 / D387, D390, D391b) ──
  #
  # `content.disposition_rerun` is the fourth durable key: one command an
  # auditor can run to try to prove the durable reason WRONG. These fixtures pin
  # four separable properties, and each fails on a DIFFERENT edit:
  #
  #   * the key is written by this one verb, in the same CAS update (drop the
  #     `apply_adjudication_key(@rerun_key, …)` line → the read-back reds);
  #   * the screen REFUSES a rerun that cannot fail, and writes nothing (delete
  #     a `@forbidden_rerun_shapes` row → that spelling's fixture reds);
  #   * absence is a PASS, never a refusal (make the field mandatory → the
  #     optional fixture reds);
  #   * NO distinctness (add a cross-row uniqueness check → SHAREDRERUN reds).
  describe "POST /v1/tasks/:doc_id/stage — the rerun that could prove the reason wrong" do
    test "a legal rerun lands on the DURABLE content.disposition_rerun, in the same write",
         %{conn: conn, scope: scope} do
      doc_id = uniq("stage-rerun-ok")
      task = mk_task!(doc_id, scope)

      rerun = "git cat-file -e origin/main:api/lib/barkpark/tasks/stage.ex"

      resp =
        stage(conn, doc_id, %{
          state: "considering",
          disposition: "parked",
          note: "parked: the sanctioned writer already owns this key",
          "reopen-trigger": "when wave 29 opens",
          rerun: rerun
        })

      assert resp.status == 200

      row = reload(task)
      assert row.content["disposition_rerun"] == rerun
      assert row.content[Tasks.Stage.disposition_rerun_key()] == rerun
      # ONE CAS update or none: the rest of the adjudication landed with it.
      assert row.content["disposition"] == "parked"
      assert row.content["disposition_reason"] =~ "sanctioned writer"
      assert row.content["reopen_trigger"] == "when wave 29 opens"

      body = Jason.decode!(resp.resp_body)
      assert body["doc"]["content"]["disposition_rerun"] == rerun
    end

    test "each of the three named legal substitutes is accepted verbatim",
         %{conn: conn, scope: scope} do
      # The refusal message NAMES these. A refusal that names an unwritable
      # substitute is a lie about its own remedy — so the accepted set and the
      # advertised set are asserted to be the same thing.
      for template <- Tasks.Stage.legal_rerun_substitutes() do
        rerun =
          template
          |> String.replace("<sha>", "12f108f87")
          |> String.replace("<path>", "api/lib/barkpark/tasks/stage.ex")
          |> String.replace("<token>", "disposition_rerun")

        doc_id = uniq("stage-rerun-legal")
        task = mk_task!(doc_id, scope)

        resp = stage(conn, doc_id, %{state: "considering", note: "checkable", rerun: rerun})

        assert resp.status == 200, "the advertised substitute #{inspect(rerun)} was REFUSED"
        assert reload(task).content["disposition_rerun"] == rerun
      end
    end

    test "the four forbidden spellings are REFUSED and the row stays BYTE-IDENTICAL",
         %{conn: conn, scope: scope} do
      forbidden = [
        {"git -C log push origin main", "repo_redirect"},
        {"test -f README.md", "filesystem_predicate"},
        # Two defects at once (a `test` predicate AND a substitution); the
        # screen's first-match order names the substitution, which is the one
        # that actually swallows the probe's exit code.
        {"test 0 -eq $(git grep -c x -- y)", "command_substitution"},
        {"git merge-base --is-ancestor a b", "merge_base_ancestor"}
      ]

      for {rerun, shape} <- forbidden do
        doc_id = uniq("stage-rerun-bad")
        task = mk_task!(doc_id, scope)
        before = reload(task)

        resp =
          stage(conn, doc_id, %{
            state: "considering",
            note: "a reason with an uncheckable check",
            rerun: rerun
          })

        assert resp.status == 422, "#{inspect(rerun)} was ACCEPTED"
        payload = Jason.decode!(resp.resp_body)
        assert payload["ok"] == false
        assert payload["reason"] == "unfalsifiable_rerun"
        # It NAMES the field…
        assert payload["field"] == "disposition_rerun"
        assert payload["shape"] == shape
        # …and a legal substitute the caller can actually write.
        assert Enum.any?(
                 Tasks.Stage.legal_rerun_substitutes(),
                 &String.contains?(payload["message"], &1)
               ),
               "the refusal of #{inspect(rerun)} names no legal substitute"

        # NOTHING WAS WRITTEN: same rev, same content, byte for byte. Not even
        # the lifecycle transition or the note that rode along with it.
        after_row = reload(task)
        assert after_row.rev == before.rev
        assert after_row.content == before.content
        refute Map.has_key?(after_row.content, "disposition_rerun")
        assert after_row.content["lifecycle_status"] == "open"
      end
    end

    test "a pipe-masked formatting tail is refused — and the pipeline really does exit 0",
         %{conn: conn, scope: scope} do
      # THE UNDERLYING FACT FIRST, measured on this checkout rather than
      # asserted: a pipeline reports its LAST stage's exit code, so a formatter
      # launders a hard failure into a pass.
      gone =
        "origin/main:api/lib/barkpark/tasks/no_such_file_#{System.unique_integer([:positive])}.ex"

      {_, bare_rc} = System.cmd("sh", ["-c", "git show #{gone}"], stderr_to_stdout: true)

      {_, piped_rc} =
        System.cmd("sh", ["-c", "git show #{gone} | head -1"], stderr_to_stdout: true)

      assert bare_rc == 128, "expected the bare `git show` of a deleted path to fail"

      assert piped_rc == 0,
             "expected `| head -1` to launder the failure into a pass — if this ever reds, " <>
               "the screen's justification changed and the message must change with it"

      doc_id = uniq("stage-rerun-pipe")
      task = mk_task!(doc_id, scope)
      before = reload(task)

      resp =
        stage(conn, doc_id, %{
          state: "considering",
          note: "cited api/lib/barkpark/tasks/stage.ex",
          rerun: "git show origin/main:api/lib/barkpark/tasks/stage.ex | head -1"
        })

      assert resp.status == 422
      payload = Jason.decode!(resp.resp_body)
      assert payload["reason"] == "unfalsifiable_rerun"
      assert payload["shape"] == "pipe_masked"
      # The refusal EXPLAINS the fact just measured above.
      assert payload["message"] =~ "exit"
      assert payload["message"] =~ "head"

      assert reload(task).content == before.content
    end

    test "a comparing tail after a pipe is NOT pipe-masked", %{conn: conn, scope: scope} do
      # The screen refuses formatters, not pipes. `| grep -qx 0` is the
      # flagship legal shape and MUST survive the pipe rule.
      doc_id = uniq("stage-rerun-grep")
      task = mk_task!(doc_id, scope)

      rerun = "git rev-list --count origin/main..12f108f87 | grep -qx 0"

      assert stage(conn, doc_id, %{state: "considering", note: "ancestry", rerun: rerun}).status ==
               200

      assert reload(task).content["disposition_rerun"] == rerun
    end

    # SHAREDRERUN (PDS-D391b, mirroring D336(a)'s SHAREDTRIG). A single command
    # can falsify a whole FAMILY of rows. If a later wave "tightens" this field
    # with a distinctness clause — the mistake D336(a) already ruled out once
    # under a different field name — this fixture reds.
    test "SHAREDRERUN: two DISTINCT rows may carry the SAME rerun", %{conn: conn, scope: scope} do
      shared = "git grep -n disposition_rerun origin/main -- api/lib/barkpark/tasks/stage.ex"

      a = uniq("stage-rerun-shared-a")
      b = uniq("stage-rerun-shared-b")
      task_a = mk_task!(a, scope)
      task_b = mk_task!(b, scope)

      assert stage(conn, a, %{
               state: "considering",
               note: "row A: the key exists on the sanctioned writer",
               rerun: shared
             }).status == 200

      assert stage(conn, b, %{
               state: "considering",
               note: "row B: a DIFFERENT reason, falsified by the SAME command",
               rerun: shared
             }).status == 200

      row_a = reload(task_a)
      row_b = reload(task_b)

      # The reasons are distinct (the prose clause still bites)…
      refute row_a.content["disposition_reason"] == row_b.content["disposition_reason"]
      # …and the rerun is deliberately NOT.
      assert row_a.content["disposition_rerun"] == shared
      assert row_b.content["disposition_rerun"] == shared
    end

    test "the rerun is OPTIONAL: a reason may refuse to be checkable and still pass",
         %{conn: conn, scope: scope} do
      # Truth-grip D3: demoted, never rejected. An absent rerun lands at L6 —
      # it must never be a refusal, or the field would force authors to invent
      # a check, which is the exact defect this wave exists to close.
      doc_id = uniq("stage-rerun-absent")
      task = mk_task!(doc_id, scope)

      resp =
        stage(conn, doc_id, %{
          state: "considering",
          disposition: "parked",
          note: "parked on a vendor licence nobody here can run a check against",
          "reopen-trigger": "when the licence is granted"
        })

      assert resp.status == 200
      row = reload(task)
      assert row.content["disposition"] == "parked"
      # ABSENT, not "" — an empty string would be a rerun that trivially passes.
      refute Map.has_key?(row.content, "disposition_rerun")

      # A blank rerun is no rerun either, and must not blank an existing one.
      assert stage(conn, doc_id, %{state: "researching", rerun: "   "}).status == 200
      refute Map.has_key?(reload(task).content, "disposition_rerun")
    end

    test "a stage WITHOUT a rerun never erases an existing one", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-rerun-keep")

      task =
        mk_task!(doc_id, scope, %{
          "disposition_rerun" => "git cat-file -e origin/main:api/mix.exs"
        })

      assert stage(conn, doc_id, %{state: "considering", note: "still parked"}).status == 200

      assert reload(task).content["disposition_rerun"] ==
               "git cat-file -e origin/main:api/mix.exs"
    end

    test "task.staged NAMES the key the rerun was routed to", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-rerun-event")
      task = mk_task!(doc_id, scope)
      rerun = "git cat-file -e origin/main:api/mix.exs"

      assert stage(conn, doc_id, %{state: "considering", note: "why", rerun: rerun}).status == 200

      [ev] =
        Repo.all(
          from(e in MutationEvent,
            where: e.doc_id == ^task.doc_id and e.mutation == "task.staged"
          )
        )

      assert ev.document["staged"]["disposition_rerun"] == rerun
      assert ev.document["staged"]["disposition_rerun_key"] == "disposition_rerun"
    end

    test "the RAW /v1/data/mutate door refuses content.disposition_rerun and names the verb",
         %{scope: scope} do
      # The sanctioned-writer property is decoration unless the raw door is shut
      # too: a screen at the verb's write seam is one a raw patch walks past.
      doc_id = uniq("stage-rerun-raw")
      _task = mk_task!(doc_id, scope, %{"disposition_reason" => "already reasoned"})

      set = %{
        "patch" => %{
          "id" => doc_id,
          "type" => "task",
          "set" => %{"disposition_rerun" => "test -f README.md"}
        }
      }

      assert {:error, {:invalid_task_content, errors}} =
               Content.apply_mutations([set], @dataset, [source: :api] ++ scope)

      [message] = errors["disposition_rerun"]
      assert message =~ "/v1/data/mutate"
      assert message =~ "bp task stage"
      assert message =~ "--rerun"

      {:ok, doc} = Content.get_document("drafts." <> doc_id, "task", @dataset, scope)
      refute Map.has_key?(doc.content, "disposition_rerun")
    end

    test "the manifest flag NAMES the legal and the forbidden spellings" do
      flag =
        Barkpark.Plugins.Tasks.cli_commands()
        |> Enum.find(&(&1.id == "task.stage"))
        |> Map.fetch!(:flags)
        |> Enum.find(&(&1.name == "rerun"))

      assert flag, "task.stage advertises no --rerun flag — bp task stage --help would omit it"

      for legal <- Tasks.Stage.legal_rerun_substitutes() do
        assert flag.summary =~ legal,
               "the --rerun help omits the legal substitute #{inspect(legal)}"
      end

      for forbidden <- ["git -C", "test", "$(", "merge-base --is-ancestor", "head"] do
        assert flag.summary =~ forbidden,
               "the --rerun help omits the forbidden spelling #{inspect(forbidden)}"
      end

      # …and it states the two properties a future wave is most likely to break.
      assert flag.summary =~ "OPTIONAL"
      assert flag.summary =~ "Distinctness is NOT applied"
    end
  end

  describe "POST /v1/tasks/:doc_id/stage — validation" do
    test "an invalid engagement object is a 400", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-obj")
      _task = mk_task!(doc_id, scope)

      resp = stage(conn, doc_id, %{state: "considering", object: "nonsense"})
      assert resp.status == 400
      assert Jason.decode!(resp.resp_body)["ok"] == false
    end

    test "missing state is a 400", %{conn: conn, scope: scope} do
      doc_id = uniq("stage-nostate")
      _task = mk_task!(doc_id, scope)

      resp = conn |> authed() |> post("/v1/tasks/#{doc_id}/stage", Jason.encode!(%{worker: "x"}))
      assert resp.status == 400
    end

    test "staging an unknown task is a 404", %{conn: conn} do
      resp =
        stage(conn, "no-such-task-#{System.unique_integer([:positive])}", %{state: "considering"})

      assert resp.status == 404
    end

    test "stage without a token is a 401", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/tasks/whatever/stage", Jason.encode!(%{state: "open"}))

      assert resp.status == 401
    end
  end
end
