defmodule BarkparkWeb.TasksFilterRoutesTest do
  @moduledoc """
  task-e1b74c19174cb2c1 — the `filter[...]` container on the SIBLING read
  routes of `GET /v1/tasks`.

  PR #12780 made the container fail-CLOSED on `GET /v1/tasks` only. `ready`,
  `prime` and `events` still ignored `filter` outright, so a caller who learned
  `filter[parent_id]` on one route and carried it one route over got a 200
  carrying an UNFILTERED page — the original false confirmation, one route over.
  Measured live on guerrilla 2026-09-01 before this fix:

    * `GET /v1/tasks/ready?filter[parent_id]=task-96a908af98698118`
      → 200, **200 rows spanning 47 distinct parent_ids**
      (`?phase_id=` on the same parent → 18 rows, ONE parent_id)
    * `GET /v1/tasks/prime?filter[worker]=lead-cli`
      → 200, `worker: null`, all 28 live claims (`?worker=` → 4)
    * `GET /v1/tasks/events?filter[doc_id]=…&limit=5`
      → 200, 5 rows spanning 5 distinct doc_ids

  Every test here asserts on the RETURNED ROWS or on the refusal body, and
  every row assertion is scoped to rows this test created — the test database
  is shared, so a whole-queue count would be someone else's measurement.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-filter-routes-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-filter-routes", "test", ["read", "write", "admin"])
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc.doc_id
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp body(resp), do: Jason.decode!(resp.resp_body)

  # ─── GET /v1/tasks/ready ────────────────────────────────────────────────

  describe "GET /v1/tasks/ready — the filter[] container" do
    setup %{scope: scope} do
      mine = uniq("frt-parent")
      foreign = uniq("frt-foreign")

      a = mk_task!(uniq("frt-a"), scope, %{"parent_id" => mine})
      b = mk_task!(uniq("frt-b"), scope, %{"parent_id" => mine})
      decoy = mk_task!(uniq("frt-decoy"), scope, %{"parent_id" => foreign})

      %{mine: mine, foreign: foreign, a: a, b: b, decoy: decoy}
    end

    test "filter[parent_id] narrows the queue — every returned row is that parent's child",
         %{conn: conn, mine: mine, a: a, b: b, decoy: decoy} do
      resp =
        conn
        |> authed()
        |> get("/v1/tasks/ready?filter[parent_id]=#{mine}&limit=1000")

      assert resp.status == 200
      docs = body(resp)["docs"]

      ids = Enum.map(docs, & &1["doc_id"])

      # The rows this test owns: both children present, the foreign sibling gone.
      assert a in ids
      assert b in ids
      refute decoy in ids

      # And NO row in the page belongs to another parent — the pre-fix response
      # carried 47 of them.
      assert Enum.uniq(Enum.map(docs, & &1["parent_id"])) == [mine]
    end

    test "filter[parent] and filter[phase_id] are the SAME edge as filter[parent_id]",
         %{conn: conn, mine: mine, a: a, b: b, decoy: decoy} do
      for spelling <- ["parent", "parent_id", "phase_id"] do
        resp =
          conn
          |> authed()
          |> get("/v1/tasks/ready?filter[#{spelling}]=#{mine}&limit=1000")

        assert resp.status == 200, "filter[#{spelling}] was refused"
        ids = body(resp)["docs"] |> Enum.map(& &1["doc_id"]) |> Enum.sort()

        assert a in ids, "filter[#{spelling}] dropped a child it should keep"
        assert b in ids, "filter[#{spelling}] dropped a child it should keep"
        refute decoy in ids, "filter[#{spelling}] kept a foreign row"
      end
    end

    test "a key ready cannot honour is a 400 that NAMES it", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/ready?filter[lifecycle_status]=done")

      assert resp.status == 400
      b = body(resp)
      assert b["ok"] == false
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "lifecycle_status"
      assert b["message"] =~ "GET /v1/tasks/ready"
      assert b["details"]["key"] == "lifecycle_status"
      assert b["details"]["supported"] == ["parent", "parent_id", "phase_id"]
    end

    test "the operator form is refused rather than dropped", %{conn: conn, mine: mine} do
      resp = conn |> authed() |> get("/v1/tasks/ready?filter[parent_id][eq]=#{mine}")

      assert resp.status == 400
      b = body(resp)
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "filter[parent_id] must be a single string value"
      assert b["message"] =~ "GET /v1/tasks/ready"
    end

    test "two spellings with different values are refused — neither quietly wins",
         %{conn: conn, mine: mine, foreign: foreign} do
      resp =
        conn
        |> authed()
        |> get("/v1/tasks/ready?phase_id=#{mine}&filter[parent_id]=#{foreign}")

      assert resp.status == 400
      b = body(resp)
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "phase_id"
      assert b["message"] =~ "filter[parent_id]"
      assert b["details"]["conflicting"] == ["phase_id", "filter[parent_id]"]
    end

    test "the same spelling twice with the SAME value is honoured, not refused",
         %{conn: conn, mine: mine, a: a, decoy: decoy} do
      resp =
        conn
        |> authed()
        |> get("/v1/tasks/ready?phase_id=#{mine}&filter[parent_id]=#{mine}&limit=1000")

      assert resp.status == 200
      ids = body(resp)["docs"] |> Enum.map(& &1["doc_id"])
      assert a in ids
      refute decoy in ids
    end

    test "no filter[] at all still answers 200 (the flat path is untouched)",
         %{conn: conn, mine: mine, a: a, b: b, decoy: decoy} do
      resp = conn |> authed() |> get("/v1/tasks/ready?phase_id=#{mine}&limit=1000")

      assert resp.status == 200
      ids = body(resp)["docs"] |> Enum.map(& &1["doc_id"])
      assert a in ids
      assert b in ids
      refute decoy in ids
    end
  end

  # ─── GET /v1/tasks/prime ────────────────────────────────────────────────

  describe "GET /v1/tasks/prime — the filter[] container" do
    setup %{scope: scope} do
      worker = uniq("frt-worker")
      other = uniq("frt-other")

      claimed =
        mk_task!(uniq("frt-claimed"), scope, %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => worker, "epoch" => 1}
        })

      foreign_claim =
        mk_task!(uniq("frt-foreign-claim"), scope, %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => other, "epoch" => 1}
        })

      %{worker: worker, other: other, claimed: claimed, foreign_claim: foreign_claim}
    end

    test "filter[worker] narrows in_progress exactly as ?worker= does",
         %{conn: conn, worker: worker, claimed: claimed, foreign_claim: foreign_claim} do
      resp = conn |> authed() |> get("/v1/tasks/prime?filter[worker]=#{worker}&limit=100")

      assert resp.status == 200
      b = body(resp)

      # Pre-fix this echoed null and carried every live claim.
      assert b["worker"] == worker

      ids = Enum.map(b["in_progress"], & &1["doc_id"])
      assert claimed in ids
      refute foreign_claim in ids

      # No row in the slice belongs to another worker.
      workers =
        b["in_progress"]
        |> Enum.map(&get_in(&1, ["content", "claim", "worker"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      assert workers in [[], [worker]]
    end

    test "?worker= and filter[worker] agree row-for-row",
         %{conn: conn, worker: worker} do
      flat = conn |> authed() |> get("/v1/tasks/prime?worker=#{worker}&limit=100")
      bracket = conn |> authed() |> get("/v1/tasks/prime?filter[worker]=#{worker}&limit=100")

      assert flat.status == 200
      assert bracket.status == 200

      ids = fn resp -> resp |> body() |> Map.fetch!("in_progress") |> Enum.map(& &1["doc_id"]) end
      assert ids.(flat) == ids.(bracket)
    end

    test "a key prime cannot honour is a 400 that NAMES it", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/prime?filter[parent_id]=whatever")

      assert resp.status == 400
      b = body(resp)
      assert b["ok"] == false
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "parent_id"
      assert b["message"] =~ "GET /v1/tasks/prime"
      assert b["details"]["key"] == "parent_id"
      assert b["details"]["supported"] == ["worker"]
    end

    test "?worker= and filter[worker] disagreeing is refused, not silently resolved",
         %{conn: conn, worker: worker, other: other} do
      resp = conn |> authed() |> get("/v1/tasks/prime?worker=#{worker}&filter[worker]=#{other}")

      assert resp.status == 400
      b = body(resp)
      assert b["reason"] == "invalid_filter"
      assert b["details"]["conflicting"] == ["worker", "filter[worker]"]
    end

    test "no filter[] at all still answers 200 with the full envelope",
         %{conn: conn, worker: worker, claimed: claimed} do
      resp = conn |> authed() |> get("/v1/tasks/prime?worker=#{worker}&limit=100")

      assert resp.status == 200
      b = body(resp)
      assert b["ok"] == true
      assert claimed in Enum.map(b["in_progress"], & &1["doc_id"])
      assert is_list(b["ready"])
      assert is_list(b["recent_events"])
      assert is_map(b["counts"])
    end
  end

  # ─── GET /v1/tasks/events ───────────────────────────────────────────────

  describe "GET /v1/tasks/events — the filter[] container" do
    test "ANY filter[] key is a 400 that names it and says what the feed takes",
         %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/events?filter[doc_id]=frt-nope&limit=5")

      assert resp.status == 400
      b = body(resp)
      assert b["ok"] == false
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "doc_id"
      assert b["message"] =~ "GET /v1/tasks/events"
      assert b["message"] =~ "honours no filter[] key"
      assert b["message"] =~ "since, limit"
      assert b["details"]["key"] == "doc_id"
      assert b["details"]["supported"] == []
    end

    test "even a key its SIBLING routes honour is refused here", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/events?filter[parent_id]=frt-nope")

      assert resp.status == 400
      assert body(resp)["details"]["key"] == "parent_id"
    end

    test "a bare ?filter= is refused too", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/tasks/events?filter=frt-nope")

      assert resp.status == 400
      b = body(resp)
      assert b["reason"] == "invalid_filter"
      assert b["message"] =~ "filter must be given as filter[<key>]=<value>"
    end

    test "the feed still replays without a filter (no regression)",
         %{conn: conn, scope: scope} do
      _mine = mk_task!(uniq("frt-event"), scope, %{})

      resp = conn |> authed() |> get("/v1/tasks/events?since=0&limit=5")

      assert resp.status == 200
      b = body(resp)
      assert b["ok"] == true
      assert is_list(b["events"])
      assert is_integer(b["cursor"])
      assert is_boolean(b["has_more"])
    end
  end
end
