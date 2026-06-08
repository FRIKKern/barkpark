defmodule BarkparkWeb.TasksControllerTest do
  @moduledoc """
  W7b step 1 (paperflow-rx0 / w7-07a) — contract tests for the bd-shim
  surface. One happy path per endpoint + one auth-fail + one error shape.

    * `ready` happy path (one open task surfaces)
    * `claim` happy path → flips lifecycle to `in_progress`
    * `claim` error path: `no_ready` when the queue is empty
    * `close` happy path → flips lifecycle to `done`
    * `close` error path: `fenced_off` when observed_epoch mismatches
    * `edges` happy path (one `blocks` dep visible from both sides)
    * `add_edge` happy path (POST creates a `blocks` edge)
    * auth: 401 with no token on `ready`

  Total: 8 tests. Mirrors the auth-fail + happy/error-shape pattern from
  `plugin_settings_controller_test.exs`.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-tasks-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks", "test", ["read", "write", "admin"])
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
        %{"kind" => "task", "lifecycle_status" => "open"},
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

  describe "auth gating" do
    test "GET /v1/tasks/ready returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/tasks/ready")
      assert resp.status == 401
    end
  end

  describe "GET /v1/tasks/ready" do
    test "returns the open tasks in the active phase", %{conn: conn, scope: scope} do
      phase = uniq("phase-ready")
      _t1 = mk_task!(uniq("ready-a"), scope, %{"parent_id" => phase})
      _t2 = mk_task!(uniq("ready-b"), scope, %{"parent_id" => phase})

      resp = conn |> authed() |> get("/v1/tasks/ready?phase_id=#{phase}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["docs"])
      assert length(body["docs"]) == 2

      first = hd(body["docs"])
      assert first["kind"] == "task"
      assert first["lifecycle_status"] == "open"
      assert first["type"] == "task"

      # w7-08c (paperflow-y1c): edge-count fields present on the ready shape
      # (the bd-shim's list/ready renderers carry them into the consumer JSON).
      assert Map.has_key?(first, "dependency_count")
      assert Map.has_key?(first, "dependent_count")
      assert Map.has_key?(first, "comment_count")
      assert first["dependency_count"] == 0
      assert first["dependent_count"] == 0
      assert first["comment_count"] == 0
    end
  end

  describe "POST /v1/tasks/claim" do
    test "happy path: claims a ready task and flips lifecycle to in_progress",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-claim")
      _task = mk_task!(uniq("claim-a"), scope, %{"parent_id" => phase})

      body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      resp = conn |> authed() |> post("/v1/tasks/claim", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["lifecycle_status"] == "in_progress"
      assert payload["doc"]["assignee"] == "worker-1"
      assert payload["doc"]["claim"]["worker"] == "worker-1"
      assert payload["doc"]["claim"]["epoch"] == 1
    end

    test "error path: returns ok=false reason=no_ready when no claimable rows",
         %{conn: conn} do
      phase = uniq("phase-empty")
      body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})

      resp = conn |> authed() |> post("/v1/tasks/claim", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "no_ready"
    end
  end

  describe "POST /v1/tasks/:doc_id/close" do
    test "happy path: closes a claimed task; lifecycle flips to done",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-close")
      doc_id = uniq("close-a")
      _task = mk_task!(doc_id, scope, %{"parent_id" => phase})

      # Claim it first to get a valid epoch.
      claim_body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      claim_resp = conn |> authed() |> post("/v1/tasks/claim", claim_body)
      claim_payload = Jason.decode!(claim_resp.resp_body)
      claimed_doc_id = claim_payload["doc"]["doc_id"]
      epoch = claim_payload["doc"]["claim"]["epoch"]

      close_body = Jason.encode!(%{worker_id: "worker-1", observed_epoch: epoch})
      resp = conn |> authed() |> post("/v1/tasks/#{claimed_doc_id}/close", close_body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["lifecycle_status"] == "done"
    end

    test "error path: returns ok=false reason=fenced_off on epoch mismatch",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-fenced")
      doc_id = uniq("fenced-a")
      _task = mk_task!(doc_id, scope, %{"parent_id" => phase})

      claim_body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      claim_resp = conn |> authed() |> post("/v1/tasks/claim", claim_body)
      claimed_doc_id = Jason.decode!(claim_resp.resp_body)["doc"]["doc_id"]

      # Wrong epoch (real one is 1; we pass 999).
      close_body = Jason.encode!(%{worker_id: "worker-1", observed_epoch: 999})
      resp = conn |> authed() |> post("/v1/tasks/#{claimed_doc_id}/close", close_body)
      assert resp.status == 409

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "fenced_off"
    end

    # C3b regression — the KEY behaviour to lock. Everything is a task now:
    # goal/phase document types are gone, and fencing is generalized so a task
    # with NO claim record (a never-claimed root/container task — a former
    # "goal"/"phase") closes cleanly. The old type-keyed `goal/phase -> :ok`
    # fence branch is gone; the close is keyed on the ABSENCE of a claim lease,
    # not on the doc type.
    test "closes a root task (no parent, never claimed) without fenced_off",
         %{conn: conn, scope: scope} do
      # A root task = a former "goal"/"epic": no parent_id, never claimed, so
      # it carries no `content.claim` lease.
      root = mk_task!(uniq("c3b-root-close"), scope)
      refute Map.has_key?(root.content, "claim")
      refute Map.has_key?(root.content, "parent_id")

      # The shim sends observed_epoch: (claim.epoch || 1) — i.e. 1 for a doc
      # with no claim. The close must succeed regardless of that value because
      # there is no lease to fence against.
      close_body = Jason.encode!(%{worker_id: "bd-shim", observed_epoch: 1})
      resp = conn |> authed() |> post("/v1/tasks/#{root.doc_id}/close", close_body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["type"] == "task"
      assert payload["doc"]["lifecycle_status"] == "done"
      refute payload["reason"] == "fenced_off"
    end
  end

  describe "GET /v1/tasks/:doc_id/edges" do
    test "returns dependencies + dependents from both sides of a blocks edge",
         %{conn: conn, scope: scope} do
      parent = mk_task!(uniq("edges-parent"), scope)
      child = mk_task!(uniq("edges-child"), scope)

      {:ok, _} = Tasks.add_dep(child.id, parent.id, :blocks)

      # Persisted doc_ids carry the "drafts." prefix — that's the bd-shape
      # id the shim consumes (matches render_doc(doc).doc_id).
      parent_doc_id = parent.doc_id
      child_doc_id = child.doc_id

      # Child's outbound: parent is a dependency (blocker)
      child_resp = conn |> authed() |> get("/v1/tasks/#{child_doc_id}/edges")
      assert child_resp.status == 200
      child_payload = Jason.decode!(child_resp.resp_body)
      assert child_payload["ok"] == true
      assert length(child_payload["dependencies"]) == 1
      assert hd(child_payload["dependencies"])["doc_id"] == parent_doc_id
      assert child_payload["dependents"] == []

      # Parent's inbound: child is a dependent
      parent_resp = conn |> authed() |> get("/v1/tasks/#{parent_doc_id}/edges")
      assert parent_resp.status == 200
      parent_payload = Jason.decode!(parent_resp.resp_body)
      assert parent_payload["dependencies"] == []
      assert length(parent_payload["dependents"]) == 1
      assert hd(parent_payload["dependents"])["doc_id"] == child_doc_id
    end
  end

  # ─── w7-08: new endpoints ──────────────────────────────────────────────

  describe "GET /v1/tasks/:doc_id" do
    test "happy path: returns the doc as render_doc shape", %{conn: conn, scope: scope} do
      task = mk_task!(uniq("show-a"), scope)

      resp = conn |> authed() |> get("/v1/tasks/#{task.doc_id}")
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["doc_id"] == task.doc_id
      assert payload["doc"]["kind"] == "task"
      assert payload["doc"]["lifecycle_status"] == "open"
      assert payload["doc"]["type"] == "task"

      # w7-08c: edge counts ride on the single-doc show response too.
      assert payload["doc"]["dependency_count"] == 0
      assert payload["doc"]["dependent_count"] == 0
      assert payload["doc"]["comment_count"] == 0
    end

    test "error path: 404 when doc_id unknown", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/no-such-#{System.unique_integer([:positive])}")
      assert resp.status == 404

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "not_found"
    end

    # C2 (task carries its rail): the show response surfaces the task's DIRECT
    # child tasks (one level only) in chronological order, plus child_count.
    test "C2: returns direct children (the rail) in chronological order, not grandchildren",
         %{conn: conn, scope: scope} do
      root = mk_task!(uniq("c2-root"), scope)
      first = mk_task!(uniq("c2-child-1"), scope, %{"parent_id" => root.doc_id})
      second = mk_task!(uniq("c2-child-2"), scope, %{"parent_id" => root.doc_id})
      # A grandchild (child of `first`) must NOT appear in root's rail.
      _grandchild = mk_task!(uniq("c2-grandchild"), scope, %{"parent_id" => first.doc_id})

      resp = conn |> authed() |> get("/v1/tasks/#{root.doc_id}")
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      child_ids = payload["children"] |> Enum.map(& &1["doc_id"])
      assert child_ids == [first.doc_id, second.doc_id]
      assert payload["child_count"] == 2

      # Children are lightweight summaries, not the full render_doc.
      summary = hd(payload["children"])
      assert summary["doc_id"] == first.doc_id
      assert summary["title"] == first.title
      assert summary["lifecycle_status"] == "open"
      assert Map.has_key?(summary, "inserted_at")
    end

    test "C2: a childless task returns children == [] and child_count == 0",
         %{conn: conn, scope: scope} do
      leaf = mk_task!(uniq("c2-leaf"), scope)

      resp = conn |> authed() |> get("/v1/tasks/#{leaf.doc_id}")
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["children"] == []
      assert payload["child_count"] == 0
    end
  end

  describe "POST /v1/tasks/:doc_id/claim — targeted (w7-08)" do
    test "happy path: targets the specific row, flips to in_progress, epoch=1",
         %{conn: conn, scope: scope} do
      target = mk_task!(uniq("tclaim-a"), scope)
      _other = mk_task!(uniq("tclaim-b"), scope)

      body = Jason.encode!(%{worker_id: "targeted-w"})
      resp = conn |> authed() |> post("/v1/tasks/#{target.doc_id}/claim", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["doc_id"] == target.doc_id
      assert payload["doc"]["lifecycle_status"] == "in_progress"
      assert payload["doc"]["claim"]["worker"] == "targeted-w"
      assert payload["doc"]["claim"]["epoch"] == 1
    end

    test "error path: 409 reason=not_ready when already claimed", %{conn: conn, scope: scope} do
      target = mk_task!(uniq("tclaim-nr"), scope)

      body = Jason.encode!(%{worker_id: "w1"})
      _ = conn |> authed() |> post("/v1/tasks/#{target.doc_id}/claim", body)

      # Second targeted claim — row is now in_progress, expect 409 not_ready.
      body2 = Jason.encode!(%{worker_id: "w2"})
      resp = conn |> authed() |> post("/v1/tasks/#{target.doc_id}/claim", body2)
      assert resp.status == 409

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "not_ready"
    end
  end

  describe "POST /v1/tasks/edges" do
    test "happy path: creates a blocks edge between two existing tasks",
         %{conn: conn, scope: scope} do
      parent = mk_task!(uniq("addedge-parent"), scope)
      child = mk_task!(uniq("addedge-child"), scope)

      body =
        Jason.encode!(%{from_id: child.doc_id, to_id: parent.doc_id, kind: "blocks"})

      resp = conn |> authed() |> post("/v1/tasks/edges", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["edge"]["kind"] == "blocks"
    end
  end

  # ─── w7-08c (paperflow-y1c): list-all endpoint ─────────────────────────

  describe "GET /v1/tasks" do
    test "basic list: returns tasks in the tenant (root + child are both tasks)",
         %{conn: conn, scope: scope} do
      # Everything is a task: a root task (a former "goal") + a child task
      # whose parent_id points at it (the rail). Both are `type == "task"`.
      root = mk_task!(uniq("idx-root"), scope)
      _child = mk_task!(uniq("idx-child"), scope, %{"parent_id" => root.doc_id})

      resp = conn |> authed() |> get("/v1/tasks")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert is_list(payload["docs"])
      types = payload["docs"] |> Enum.map(& &1["type"]) |> MapSet.new()
      # Only the single `task` type exists now.
      assert MapSet.subset?(MapSet.new(["task"]), types)
      refute MapSet.member?(types, "goal")
      refute MapSet.member?(types, "phase")

      ids = payload["docs"] |> Enum.map(& &1["doc_id"])
      assert root.doc_id in ids

      # Count fields ride on the list shape too.
      first = hd(payload["docs"])
      assert Map.has_key?(first, "dependency_count")
      assert Map.has_key?(first, "dependent_count")
      assert Map.has_key?(first, "comment_count")
    end

    test "filter by type=task narrows to task rows only",
         %{conn: conn, scope: scope} do
      _t1 = mk_task!(uniq("kind-t1"), scope)
      _t2 = mk_task!(uniq("kind-t2"), scope)

      resp = conn |> authed() |> get("/v1/tasks?type=task")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      types = payload["docs"] |> Enum.map(& &1["type"]) |> Enum.uniq()
      assert types == ["task"]
      assert length(payload["docs"]) >= 2
    end

    test "filter by lifecycle_status: open narrows to open rows",
         %{conn: conn, scope: scope} do
      open_phase = uniq("ls-phase-open")
      done_phase = uniq("ls-phase-done")

      _open_task = mk_task!(uniq("ls-open"), scope, %{"parent_id" => open_phase})

      _done_task =
        mk_task!(uniq("ls-done"), scope, %{
          "parent_id" => done_phase,
          "lifecycle_status" => "done"
        })

      resp = conn |> authed() |> get("/v1/tasks?type=task&lifecycle_status=done")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      statuses =
        payload["docs"]
        |> Enum.map(& &1["lifecycle_status"])
        |> Enum.uniq()

      assert statuses == ["done"]
    end

    test "filter by phase_id: narrows to children of that phase",
         %{conn: conn, scope: scope} do
      phase_id = uniq("idx-phase-filter")
      _t1 = mk_task!(uniq("pf-task-a"), scope, %{"parent_id" => phase_id})
      _t2 = mk_task!(uniq("pf-task-b"), scope, %{"parent_id" => phase_id})
      _other = mk_task!(uniq("pf-other"), scope, %{"parent_id" => "different-phase"})

      resp = conn |> authed() |> get("/v1/tasks?phase_id=#{phase_id}")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      parents =
        payload["docs"]
        |> Enum.map(& &1["parent_id"])
        |> Enum.uniq()

      assert parents == [phase_id]
      assert length(payload["docs"]) == 2
    end
  end

  # ─── C1 (task as universal node): GET /v1/tasks?parent= ────────────────
  # "A goal is just a root task" + "a rail is the chronological child tasks of
  # a task". The `parent` filter mirrors `phase_id` exactly but is exposed
  # under the generic param and orders the result chronologically (inserted_at
  # ASC) so it reads as that task's timeline/rail.

  describe "GET /v1/tasks?parent= (C1 universal node)" do
    test "root → child → grandchild: parent walks the recursive task chain, chronologically",
         %{conn: conn, scope: scope} do
      # Root task A has NO parent_id (a root task = a "goal"). B's parent_id is
      # A's persisted doc_id; C's parent_id is B's — a task pointing at ANOTHER
      # task (recursive nesting), not a phase. All accepted by the validator
      # with zero relaxation.
      a = mk_task!(uniq("c1-root-a"), scope)
      b = mk_task!(uniq("c1-child-b"), scope, %{"parent_id" => a.doc_id})
      c = mk_task!(uniq("c1-grandchild-c"), scope, %{"parent_id" => b.doc_id})

      # parent=A → [B] only (the grandchild C hangs off B, not A).
      resp_a = conn |> authed() |> get("/v1/tasks?parent=#{a.doc_id}")
      assert resp_a.status == 200
      payload_a = Jason.decode!(resp_a.resp_body)
      assert payload_a["ok"] == true
      ids_a = payload_a["docs"] |> Enum.map(& &1["doc_id"])
      assert ids_a == [b.doc_id]

      # parent=B → [C].
      resp_b = conn |> authed() |> get("/v1/tasks?parent=#{b.doc_id}")
      assert resp_b.status == 200
      payload_b = Jason.decode!(resp_b.resp_body)
      ids_b = payload_b["docs"] |> Enum.map(& &1["doc_id"])
      assert ids_b == [c.doc_id]
    end

    test "chronological ordering: multiple children of one parent come back inserted_at ASC",
         %{conn: conn, scope: scope} do
      root = mk_task!(uniq("c1-rail-root"), scope)
      # Inserted in order; the rail should preserve that order (oldest first).
      first = mk_task!(uniq("c1-rail-1"), scope, %{"parent_id" => root.doc_id})
      second = mk_task!(uniq("c1-rail-2"), scope, %{"parent_id" => root.doc_id})
      third = mk_task!(uniq("c1-rail-3"), scope, %{"parent_id" => root.doc_id})

      resp = conn |> authed() |> get("/v1/tasks?parent=#{root.doc_id}")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      ids = payload["docs"] |> Enum.map(& &1["doc_id"])
      assert ids == [first.doc_id, second.doc_id, third.doc_id]
    end

    test "root task (no parent_id) is listable and claimable/closable",
         %{conn: conn, scope: scope} do
      # A root task = a "goal": no content.parent_id, still a valid task.
      root = mk_task!(uniq("c1-listable-root"), scope)
      refute Map.has_key?(root.content, "parent_id")

      # Listable in the un-filtered index.
      list_resp = conn |> authed() |> get("/v1/tasks?type=task")
      assert list_resp.status == 200
      list_ids = Jason.decode!(list_resp.resp_body)["docs"] |> Enum.map(& &1["doc_id"])
      assert root.doc_id in list_ids

      # Claimable via the targeted-claim path (a leaf claim still works on a
      # root task).
      claim_body = Jason.encode!(%{worker_id: "c1-worker"})
      claim_resp = conn |> authed() |> post("/v1/tasks/#{root.doc_id}/claim", claim_body)
      assert claim_resp.status == 200
      claim_payload = Jason.decode!(claim_resp.resp_body)
      assert claim_payload["ok"] == true
      assert claim_payload["doc"]["lifecycle_status"] == "in_progress"
      epoch = claim_payload["doc"]["claim"]["epoch"]

      # Closable.
      close_body = Jason.encode!(%{worker_id: "c1-worker", observed_epoch: epoch})
      close_resp = conn |> authed() |> post("/v1/tasks/#{root.doc_id}/close", close_body)
      assert close_resp.status == 200
      close_payload = Jason.decode!(close_resp.resp_body)
      assert close_payload["ok"] == true
      assert close_payload["doc"]["lifecycle_status"] == "done"
    end
  end

  # ─── tt5: GET /v1/tasks?label= generic exact-string filter ─────────────
  # Backs the bd-shim's `bd list --label file-claim:<path>` (and any
  # arbitrary label) → find every task holding a given claim.

  describe "GET /v1/tasks?label=" do
    test "hit: returns the task whose content.labels contains the exact label",
         %{conn: conn, scope: scope} do
      label = "file-claim:/tmp/tt5-#{System.unique_integer([:positive])}.ex"
      claimed = mk_task!(uniq("lbl-hit"), scope, %{"labels" => [label]})
      _other = mk_task!(uniq("lbl-other"), scope, %{"labels" => ["file-claim:/elsewhere"]})

      resp = conn |> authed() |> get("/v1/tasks?label=#{URI.encode_www_form(label)}")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      ids = payload["docs"] |> Enum.map(& &1["doc_id"])
      assert claimed.doc_id in ids
      # The matched row surfaces its labels at the top level (tt5 render_doc).
      hit = Enum.find(payload["docs"], &(&1["doc_id"] == claimed.doc_id))
      assert label in hit["labels"]
    end

    test "miss: a label nobody holds returns zero docs", %{conn: conn, scope: scope} do
      _t = mk_task!(uniq("lbl-miss"), scope, %{"labels" => ["file-claim:/held"]})

      resp =
        conn
        |> authed()
        |> get("/v1/tasks?label=#{URI.encode_www_form("file-claim:/nobody-holds-this")}")

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["docs"] == []
    end

    test "multiple tasks, one shared label: both surface", %{conn: conn, scope: scope} do
      label = "file-claim:/tmp/tt5-shared-#{System.unique_integer([:positive])}.ex"
      a = mk_task!(uniq("lbl-multi-a"), scope, %{"labels" => [label, "phase-build"]})
      b = mk_task!(uniq("lbl-multi-b"), scope, %{"labels" => ["kind:task", label]})

      resp = conn |> authed() |> get("/v1/tasks?label=#{URI.encode_www_form(label)}")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      ids = payload["docs"] |> Enum.map(& &1["doc_id"]) |> MapSet.new()
      assert MapSet.subset?(MapSet.new([a.doc_id, b.doc_id]), ids)
    end
  end

  # ─── tt5: POST /v1/tasks/:doc_id/labels add/remove mutation ────────────
  # Backs the bd-shim's `bd update <id> --add-label/--remove-label`.

  describe "POST /v1/tasks/:doc_id/labels" do
    test "add: union-adds a label, emits task.relabeled", %{conn: conn, scope: scope} do
      task = mk_task!(uniq("relabel-add"), scope)
      label = "file-claim:/tmp/tt5-add.ex"

      resp =
        conn
        |> authed()
        |> post("/v1/tasks/#{task.doc_id}/labels", Jason.encode!(%{add: [label]}))

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert label in payload["doc"]["labels"]

      # A task.relabeled mutation_event was emitted for this doc.
      assert relabel_event?(task.doc_id)
    end

    test "remove: drops a held label, leaves the rest", %{conn: conn, scope: scope} do
      keep = "file-claim:/tmp/tt5-keep.ex"
      drop = "file-claim:/tmp/tt5-drop.ex"
      task = mk_task!(uniq("relabel-rm"), scope, %{"labels" => [keep, drop]})

      resp =
        conn
        |> authed()
        |> post("/v1/tasks/#{task.doc_id}/labels", Jason.encode!(%{remove: [drop]}))

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      labels = payload["doc"]["labels"]
      assert keep in labels
      refute drop in labels
    end

    test "add+remove idempotent: re-adding an existing + removing an absent is a no-op set",
         %{conn: conn, scope: scope} do
      existing = "file-claim:/tmp/tt5-existing.ex"
      task = mk_task!(uniq("relabel-idem"), scope, %{"labels" => [existing]})

      resp =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{task.doc_id}/labels",
          Jason.encode!(%{add: [existing], remove: ["file-claim:/never-held"]})
        )

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      # No duplicate of the existing label; the never-held remove is a no-op.
      assert payload["doc"]["labels"] == [existing]
    end
  end

  # A `task.relabeled` mutation_event exists for `doc_id` in this tenant.
  defp relabel_event?(doc_id) do
    import Ecto.Query, only: [from: 2]

    Barkpark.Repo.exists?(
      from(e in Barkpark.Content.MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.relabeled"
      )
    )
  end

  # ─── Phase A: POST /v1/tasks/:doc_id/papers add/remove mutation ────────
  # Task→paper references stored on content.papers as paper slugs.

  describe "POST /v1/tasks/:doc_id/papers" do
    test "add: union-adds two paper refs, emits task.referenced; remove is idempotent",
         %{conn: conn, scope: scope} do
      task = mk_task!(uniq("papers-add"), scope)
      intro = "intro"
      methodology = "methodology"

      resp =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{task.doc_id}/papers",
          Jason.encode!(%{add: [intro, methodology]})
        )

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      papers = payload["doc"]["papers"]
      assert intro in papers
      assert methodology in papers

      # A task.referenced mutation_event was emitted for this doc.
      assert referenced_event?(task.doc_id)

      # Remove one ref; re-adding an existing ref + removing an absent one is a
      # no-op set — only `intro` survives, with no duplicate.
      resp2 =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{task.doc_id}/papers",
          Jason.encode!(%{add: [intro], remove: [methodology, "never-referenced"]})
        )

      assert resp2.status == 200
      payload2 = Jason.decode!(resp2.resp_body)
      assert payload2["ok"] == true
      assert payload2["doc"]["papers"] == [intro]
    end
  end

  # A `task.referenced` mutation_event exists for `doc_id` in this tenant.
  defp referenced_event?(doc_id) do
    import Ecto.Query, only: [from: 2]

    Barkpark.Repo.exists?(
      from(e in Barkpark.Content.MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.referenced"
      )
    )
  end
end
