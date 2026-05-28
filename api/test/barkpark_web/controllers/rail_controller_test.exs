defmodule BarkparkWeb.RailControllerTest do
  @moduledoc """
  W7c step 3 (w7-11 / paperflow-158) — contract tests for the rail
  endpoints `GET /v1/rail/{goal-path,event/:id,diff}`.

  Six tests: one happy per endpoint + one error per endpoint.

    * goal-path happy: timeline visible for goal+descendants, desc by id
    * goal-path error: missing `goal` query param → 400
    * event happy: full row returned with html_payload
    * event error: unknown event id → 404
    * diff happy: from/to events returned as hunks (added line shows)
    * diff error: missing query param → 400

  Mirrors the TasksControllerTest setup pattern (auth token + scope
  fixtures + per-test schema registration).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent

  @token "barkpark-test-rail-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-rail", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope, workspace_id: ws.id, project_id: project.id}
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_doc!(type, doc_id, scope, content) do
    content = Map.put(content, "kind", type)

    {:ok, doc} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Manually insert a mutation_events row carrying a payload_html in the
  # document snapshot's `content`. Mirrors the shape `Tasks.insert_mutation_event!/3`
  # writes — minus the lifecycle plumbing the rail doesn't care about.
  defp insert_event!(%{doc_id: doc_id, dataset: dataset, workspace_id: ws_id, project_id: p_id} = doc, kind, payload_html) do
    snapshot = %{
      "doc_id" => doc_id,
      "type" => doc.type,
      "title" => doc.title,
      "status" => doc.status,
      "content" => Map.put(doc.content || %{}, "payload_html", payload_html),
      "rev" => doc.rev
    }

    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: dataset,
        type: doc.type,
        doc_id: doc_id,
        mutation: kind,
        rev: doc.rev || "rev",
        previous_rev: nil,
        document: snapshot,
        workspace_id: ws_id,
        project_id: p_id,
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    ev
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
  end

  # ─── GET /v1/rail/goal-path ───────────────────────────────────────────

  describe "GET /v1/rail/goal-path" do
    test "happy: returns events for goal + descendant phases & tasks, desc by id",
         %{conn: conn, scope: scope} do
      goal = mk_doc!("goal", uniq("goal-rail"), scope, %{"goal_slug" => "rail-test"})

      # parent/parent_id references use the PERSISTED doc_id (which carries
      # the `drafts.` prefix that Content.create_document stamps on new rows).
      phase =
        mk_doc!("phase", uniq("phase-rail"), scope, %{
          "phase_name" => "build",
          "parent" => goal.doc_id
        })

      task =
        mk_doc!("task", uniq("task-rail"), scope, %{
          "parent_id" => phase.doc_id,
          "lifecycle_status" => "open"
        })

      _ = insert_event!(goal, "task.mutated", "<p>goal-opened</p>")
      _ = insert_event!(phase, "task.mutated", "<p>phase-advanced</p>")
      _ = insert_event!(task, "task.claimed", "<p>claimed</p>")
      last = insert_event!(task, "task.closed", "<p>closed</p>")

      resp = conn |> authed() |> get("/v1/rail/goal-path?goal=#{goal.doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["events"])
      assert length(body["events"]) == 4

      # Desc by id → the most recent insert is first.
      first = hd(body["events"])
      assert first["event_id"] == last.id
      assert first["kind"] == "task.closed"
      assert first["doc_id"] == task.doc_id
      assert first["branch"] == "main"
      assert Map.has_key?(first, "ts")
    end

    test "error: missing `goal` param returns 400", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/rail/goal-path")
      assert resp.status == 400
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == false
      assert body["reason"] == "bad_request"
    end

    test "compaction-restore events surface in the rail (regression: task.restored→task.compaction_restored)",
         %{conn: conn, scope: scope} do
      # The Compactor emits `task.compaction_restored` (see
      # Barkpark.Tasks.Compactor.event_kinds().restored), NOT `task.restored`.
      # A stale kind in @event_kinds_default silently dropped these events
      # from the goal-path rail. Assert the real kind is included.
      assert Barkpark.Tasks.Compactor.event_kinds().restored == "task.compaction_restored"

      goal = mk_doc!("goal", uniq("goal-restore"), scope, %{"goal_slug" => "restore-test"})

      phase =
        mk_doc!("phase", uniq("phase-restore"), scope, %{
          "phase_name" => "build",
          "parent" => goal.doc_id
        })

      task =
        mk_doc!("task", uniq("task-restore"), scope, %{
          "parent_id" => phase.doc_id,
          "lifecycle_status" => "done"
        })

      restored_kind = Barkpark.Tasks.Compactor.event_kinds().restored
      _ = insert_event!(task, "task.compacted", "<p>compacted</p>")
      restored = insert_event!(task, restored_kind, "<p>restored</p>")

      resp = conn |> authed() |> get("/v1/rail/goal-path?goal=#{goal.doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true

      kinds = Enum.map(body["events"], & &1["kind"])
      assert restored_kind in kinds, "compaction-restore event must surface in the rail"
      assert "task.compacted" in kinds

      first = hd(body["events"])
      assert first["event_id"] == restored.id
      assert first["kind"] == restored_kind
    end

    test "#7: events surface when parent_id is stored BARE but doc_id is drafts-prefixed",
         %{conn: conn, scope: scope} do
      # The live e2e bug (#7): a phase's `content.parent` is the BARE goal id
      # (`goal-258703`) while the goal's persisted doc_id carries the draft
      # prefix (`drafts.goal-258703`) — and a task's `content.parent_id` is the
      # bare phase id while the phase doc_id is drafts-prefixed. The old `=`
      # join found zero descendants → goal-path returned {events:[]}. The
      # prefix-agnostic join (strip `drafts.` on both sides) must find them.
      goal = mk_doc!("goal", uniq("goal-bare"), scope, %{"goal_slug" => "bare-test"})

      # Bare ids = the persisted doc_ids with the `drafts.` prefix stripped.
      bare_goal = String.replace_prefix(goal.doc_id, "drafts.", "")

      phase =
        mk_doc!("phase", uniq("phase-bare"), scope, %{
          "phase_name" => "build",
          # parent stored BARE — the #7 mismatch.
          "parent" => bare_goal
        })

      bare_phase = String.replace_prefix(phase.doc_id, "drafts.", "")

      task =
        mk_doc!("task", uniq("task-bare"), scope, %{
          # parent_id stored BARE — the #7 mismatch.
          "parent_id" => bare_phase,
          "lifecycle_status" => "done"
        })

      _ = insert_event!(task, "task.claimed", "<p>claimed</p>")
      closed = insert_event!(task, "task.closed", "<p>closed</p>")

      resp = conn |> authed() |> get("/v1/rail/goal-path?goal=#{goal.doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true

      # Before the fix this was []; now the descendant task's events surface.
      assert length(body["events"]) == 2
      kinds = Enum.map(body["events"], & &1["kind"])
      assert "task.claimed" in kinds
      assert "task.closed" in kinds

      first = hd(body["events"])
      assert first["event_id"] == closed.id
      assert first["doc_id"] == task.doc_id
    end
  end

  # ─── GET /v1/rail/event/:event_id ─────────────────────────────────────

  describe "GET /v1/rail/event/:event_id" do
    test "happy: returns the full event with html_payload", %{conn: conn, scope: scope} do
      goal = mk_doc!("goal", uniq("goal-evt"), scope, %{"goal_slug" => "evt"})
      ev = insert_event!(goal, "task.mutated", "<p>hello world</p>")

      resp = conn |> authed() |> get("/v1/rail/event/#{ev.id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["event"]["event_id"] == ev.id
      assert body["event"]["kind"] == "task.mutated"
      assert body["event"]["doc_id"] == goal.doc_id
      assert body["event"]["html_payload"] == "<p>hello world</p>"
    end

    test "error: unknown event id returns 404", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/rail/event/999999999")
      assert resp.status == 404
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == false
      assert body["reason"] == "not_found"
    end
  end

  # ─── GET /v1/rail/diff?from=…&to=… ────────────────────────────────────

  describe "GET /v1/rail/diff" do
    test "happy: returns hunks marking the changed line", %{conn: conn, scope: scope} do
      goal = mk_doc!("goal", uniq("goal-diff"), scope, %{"goal_slug" => "diff"})

      from_ev = insert_event!(goal, "task.mutated", "line a\nline b\nline c")
      to_ev = insert_event!(goal, "task.mutated", "line a\nline b CHANGED\nline c")

      resp = conn |> authed() |> get("/v1/rail/diff?from=#{from_ev.id}&to=#{to_ev.id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["from"] == to_string(from_ev.id)
      assert body["to"] == to_string(to_ev.id)
      assert is_list(body["hunks"])

      ops = Enum.map(body["hunks"], & &1["op"])
      assert "-" in ops
      assert "+" in ops
      assert " " in ops

      removed = Enum.find(body["hunks"], &(&1["op"] == "-"))
      added = Enum.find(body["hunks"], &(&1["op"] == "+"))
      assert removed["text"] == "line b"
      assert added["text"] == "line b CHANGED"
    end

    test "error: missing `from` returns 400", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/rail/diff?to=1")
      assert resp.status == 400
      body = Jason.decode!(resp.resp_body)
      assert body["reason"] == "bad_request"
    end
  end
end
