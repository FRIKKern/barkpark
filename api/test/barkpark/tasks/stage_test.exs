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
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

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
        task = mk_task!(doc_id, scope, %{"lifecycle_status" => state})

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
      end
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
                   "content" => %{"kind" => "task", "lifecycle_status" => "marinating"}
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
