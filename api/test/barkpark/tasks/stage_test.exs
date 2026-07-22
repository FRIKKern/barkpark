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
      assert row1.content["engagement"]["note"] == "weighing"
      assert is_binary(row1.content["engagement"]["ts"])

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
