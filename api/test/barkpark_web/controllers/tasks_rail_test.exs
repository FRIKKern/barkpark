defmodule BarkparkWeb.TasksRailTest do
  @moduledoc """
  rail-l1 — envelope contract tests for the rail-awareness fields on the
  claim / queue-claim / close / prime responses.

    * THE canonical multi-agent test (acceptance criterion 3): a blocker
      filed onto a claimed task surfaces as a `blocked_while_claimed` notice
      on the claimant's next prime AND close — and the close still commits.
    * rail_rev present when the subject task has a parent, omitted when
      parentless (claim, queue-claim, close).
    * prime carries the `rails` map keyed by each parent of the worker's
      in-progress claims.
    * observed_rail_rev: a concurrent rail change → `rail_changed` notice;
      an unchanged rail (only the worker's own action) → no notice.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-rail-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-rail", "test", ["read", "write", "admin"])
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

  # PDS-D291: one MET criterion keeps this file's `done` closes out of the
  # close-artifact gate, which refuses a `done` close of a criteria-less
  # kind:task row whose reason names no PR+sha and pastes no run. These tests
  # measure the rail, not the close reason.
  defp mk_task!(doc_id, scope, content_extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
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

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp notice_types(payload), do: Enum.map(payload["notices"] || [], & &1["type"])

  defp notice_of(payload, type),
    do: Enum.find(payload["notices"] || [], &(&1["type"] == type))

  # ─── Acceptance criterion 3: the canonical multi-agent case ──────────────

  describe "canonical: a blocker filed onto a claimed task surfaces on prime AND close" do
    test "blocked_while_claimed rides B's prime; after the L4 edge fence, a renewal + close still surface it",
         %{conn: conn, scope: scope} do
      parent = uniq("epic")
      t5 = mk_task!(uniq("t5"), scope, %{"parent_id" => parent})
      t9 = mk_task!(uniq("t9"), scope, %{})

      # Worker B claims t5 (no blockers yet).
      {:ok, claimed} = Tasks.claim_by_id(t5.doc_id, "B", scope)
      epoch = get_in(claimed.content, ["claim", "epoch"])
      assert epoch == 1

      # A SECOND actor (agent A) files a blocks edge t5 → t9 (t9 still open).
      # rail-l4 allow-and-fence: this bumps t5's epoch (t5 is in_progress).
      {:ok, _} = Tasks.add_dep(t5.id, t9.id, :blocks)

      # (a) B's prime carries blocked_while_claimed for t5 with t9 in blockers.
      prime =
        conn |> authed() |> get("/v1/tasks/prime?worker=B") |> json_response(200)

      blocked = notice_of(prime, "blocked_while_claimed")
      assert blocked, "expected a blocked_while_claimed notice on prime"
      assert String.contains?(blocked["task_id"], "t5")
      assert Enum.any?(blocked["blockers"], &String.contains?(&1, "t9"))

      # (b) B's close with the OLD epoch is now FENCED (L4) — the edge landed on
      # its claimed task, so it must resync first.
      stale_close = Jason.encode!(%{worker_id: "B", observed_epoch: epoch})

      fenced =
        conn
        |> authed()
        |> post("/v1/tasks/#{t5.doc_id}/close", stale_close)
        |> json_response(409)

      assert fenced["reason"] == "fenced_off"

      # (c) B renews its lease (same-worker re-claim) → 200 with a fresh epoch
      # AND the blocked_while_claimed notice rides the renewal envelope.
      renew =
        conn
        |> authed()
        |> post("/v1/tasks/#{t5.doc_id}/claim", Jason.encode!(%{worker_id: "B"}))
        |> json_response(200)

      # epoch moved twice: +1 for the L4 edge fence, +1 for this renewal.
      new_epoch = renew["doc"]["claim"]["epoch"]
      assert new_epoch == epoch + 2
      assert notice_of(renew, "blocked_while_claimed")

      # (d) B's close with the NEW epoch commits (blocked status), and the same
      # notice rides the close envelope.
      close_body =
        Jason.encode!(%{worker_id: "B", observed_epoch: new_epoch, lifecycle_status: "blocked"})

      close =
        conn |> authed() |> post("/v1/tasks/#{t5.doc_id}/close", close_body) |> json_response(200)

      assert close["ok"] == true
      assert close["doc"]["lifecycle_status"] == "blocked"

      blocked2 = notice_of(close, "blocked_while_claimed")
      assert blocked2, "expected a blocked_while_claimed notice on close"
      assert String.contains?(blocked2["task_id"], "t5")
      assert Enum.any?(blocked2["blockers"], &String.contains?(&1, "t9"))
    end
  end

  # ─── rail_rev presence / omission ────────────────────────────────────────

  describe "rail_rev on the subject-task envelopes" do
    test "targeted claim carries rail_rev when the task has a parent, omits when parentless",
         %{conn: conn, scope: scope} do
      parent = uniq("epic")
      withp = mk_task!(uniq("wp"), scope, %{"parent_id" => parent})
      nop = mk_task!(uniq("np"), scope, %{})

      with_rev =
        conn
        |> authed()
        |> post("/v1/tasks/#{withp.doc_id}/claim", Jason.encode!(%{worker_id: "w"}))
        |> json_response(200)

      assert is_binary(with_rev["rail_rev"])
      assert byte_size(with_rev["rail_rev"]) == 16

      no_rev =
        conn
        |> authed()
        |> post("/v1/tasks/#{nop.doc_id}/claim", Jason.encode!(%{worker_id: "w"}))
        |> json_response(200)

      refute Map.has_key?(no_rev, "rail_rev")
    end

    test "queue claim (next) carries rail_rev when the claimed task has a parent",
         %{conn: conn, scope: scope} do
      phase = uniq("phase")
      _t = mk_task!(uniq("q"), scope, %{"parent_id" => phase})

      payload =
        conn
        |> authed()
        |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "w", phase_id: phase}))
        |> json_response(200)

      assert payload["ok"] == true
      assert is_binary(payload["rail_rev"])
      assert byte_size(payload["rail_rev"]) == 16
    end

    test "close carries rail_rev when the task has a parent, omits when parentless",
         %{conn: conn, scope: scope} do
      parent = uniq("epic")
      withp = mk_task!(uniq("wp"), scope, %{"parent_id" => parent})
      nop = mk_task!(uniq("np"), scope, %{})

      {:ok, _} = Tasks.claim_by_id(withp.doc_id, "w", scope)
      {:ok, _} = Tasks.claim_by_id(nop.doc_id, "w", scope)

      cbody = Jason.encode!(%{worker_id: "w", observed_epoch: 1})

      with_rev =
        conn |> authed() |> post("/v1/tasks/#{withp.doc_id}/close", cbody) |> json_response(200)

      assert is_binary(with_rev["rail_rev"])

      no_rev =
        conn |> authed() |> post("/v1/tasks/#{nop.doc_id}/close", cbody) |> json_response(200)

      assert no_rev["ok"] == true
      refute Map.has_key?(no_rev, "rail_rev")
    end
  end

  # ─── prime rails map ─────────────────────────────────────────────────────

  describe "prime rails map" do
    test "keyed by each distinct parent of the worker's in-progress claims",
         %{conn: conn, scope: scope} do
      parent = uniq("epic")
      t = mk_task!(uniq("pr"), scope, %{"parent_id" => parent})
      {:ok, _} = Tasks.claim_by_id(t.doc_id, "agent-r", scope)

      payload =
        conn |> authed() |> get("/v1/tasks/prime?worker=agent-r") |> json_response(200)

      assert is_map(payload["rails"])
      # The claimed task's parent (drafts-agnostic) is a key with a 16-hex rev.
      {_k, rev} =
        Enum.find(payload["rails"], fn {k, _v} -> String.contains?(k, parent) end)

      assert is_binary(rev)
      assert byte_size(rev) == 16
      # prime never carries a top-level rail_rev — the map is the right shape.
      refute Map.has_key?(payload, "rail_rev")
    end
  end

  # ─── observed_rail_rev → rail_changed ────────────────────────────────────

  describe "observed_rail_rev" do
    test "a concurrent rail change → rail_changed notice; an unchanged rail → none",
         %{conn: conn, scope: scope} do
      parent = uniq("epic")
      subject = mk_task!(uniq("sub"), scope, %{"parent_id" => parent})
      _sib = mk_task!(uniq("sib"), scope, %{"parent_id" => parent})

      # Claim → learn the current rail_rev (the worker's observed baseline).
      claim =
        conn
        |> authed()
        |> post("/v1/tasks/#{subject.doc_id}/claim", Jason.encode!(%{worker_id: "w"}))
        |> json_response(200)

      observed = claim["rail_rev"]
      assert is_binary(observed)

      # MATCH: nobody else touched the rail → close with observed == baseline
      # emits NO rail_changed (the worker's own close is not "drift").
      match =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{subject.doc_id}/close",
          Jason.encode!(%{worker_id: "w", observed_epoch: 1, observed_rail_rev: observed})
        )
        |> json_response(200)

      assert match["ok"] == true
      refute "rail_changed" in notice_types(match)

      # MISMATCH: a fresh subject, but a SECOND actor moves the rail (new
      # sibling) between the worker's observation and its close.
      subject2 = mk_task!(uniq("sub2"), scope, %{"parent_id" => parent})

      claim2 =
        conn
        |> authed()
        |> post("/v1/tasks/#{subject2.doc_id}/claim", Jason.encode!(%{worker_id: "w2"}))
        |> json_response(200)

      observed2 = claim2["rail_rev"]

      # concurrent actor files another sibling into the SAME rail.
      _sib2 = mk_task!(uniq("sib2"), scope, %{"parent_id" => parent})

      mismatch =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{subject2.doc_id}/close",
          Jason.encode!(%{worker_id: "w2", observed_epoch: 1, observed_rail_rev: observed2})
        )
        |> json_response(200)

      assert mismatch["ok"] == true
      changed = notice_of(mismatch, "rail_changed")
      assert changed, "expected a rail_changed notice after a concurrent rail edit"
      assert String.contains?(changed["parent_id"], parent)
      assert is_binary(changed["rail_rev"])
    end
  end
end
