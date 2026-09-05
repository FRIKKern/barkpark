defmodule Barkpark.Plugins.Sheets.Web.OpsControllerTest do
  @moduledoc """
  Contract tests for `POST /v1/plugins/sheets/:slug/ops`.

  Covers the controller's four distinct response paths:
    - 401 when the shared-secret ingest token is missing
    - 422 when the body carries no `"ops"` list (malformed_ops)
    - 422 when the batch exceeds `Session.max_ops_per_call/0` (batch_too_large)
    - 404 for an unknown slug (Session.apply_ops returns {:error, :not_found})
    - 200 with `ok:true` + rev/applied/errors for a valid op on a real sheet

  Runs against the live DB + the in-tree SessionSupervisor (always started in
  application.ex, not plugin-gated) using a fresh dataset per test module.
  `async: false` because sessions are globally registered processes.
  """

  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Session.ReplayRing

  @dataset "ops_controller_test"
  @ingest_token "barkpark-test-ingest-token"
  @slug "ops-ctrl-test-sheet"
  @ring_table :sheets_ops_replay
  @sheets_sup Barkpark.Plugins.Sheets.Supervisor

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      ensure_ring!()
    end)

    :ok
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Restore the invariant a ring-deleting test broke: a live ring owning a live
  # `:sheets_ops_replay` table. Copied in shape from session_ring_crash_test.exs
  # — a REAL kill of the supervised singleton, so the supervisor rebuilds the
  # table rather than a test hand-creating one it does not own.
  defp ensure_ring! do
    if :ets.whereis(@ring_table) == :undefined do
      with_log(fn -> restart_ring!() end)
    end

    :ok
  end

  defp restart_ring! do
    pid = Process.whereis(ReplayRing)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    deadline = System.monotonic_time(:millisecond) + 2_000
    wait_for_new_ring(pid, deadline)
  end

  defp wait_for_new_ring(old, deadline) do
    case Process.whereis(ReplayRing) do
      new when is_pid(new) and new != old ->
        assert is_pid(Process.whereis(@sheets_sup))
        new

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("the ReplayRing did not come back after a kill")
        else
          Process.sleep(10)
          wait_for_new_ring(old, deadline)
        end
    end
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @ingest_token)
    |> put_req_header("content-type", "application/json")
  end

  defp ops_url(slug, dataset \\ nil) do
    base = "/v1/plugins/sheets/#{slug}/ops"
    if dataset, do: base <> "?dataset=#{dataset}", else: base
  end

  defp create_sheet(slug) do
    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{
            "tabs" => [%{"name" => "Sheet1", "cells" => %{"A1" => %{"v" => "hello"}}}]
          }
        },
        @dataset
      )
  end

  # ── 1. Auth gate ──────────────────────────────────────────────────────────

  test "returns 401 when no Authorization header is provided", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(ops_url(@slug), Jason.encode!(%{"ops" => []}))

    assert conn.status == 401
  end

  # ── 2. Malformed body — no "ops" key ─────────────────────────────────────

  test "returns 422 malformed_ops when body lacks an ops list", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post(ops_url(@slug), Jason.encode!(%{"data" => []}))
      |> json_response(422)

    assert body["error"]["code"] == "malformed_ops"
    assert body["error"]["message"] =~ "ops"
  end

  # ── 3. Batch too large ────────────────────────────────────────────────────

  test "returns 422 batch_too_large when ops list exceeds Session.max_ops_per_call/0", %{
    conn: conn
  } do
    oversized = List.duplicate(%{"op" => "noop"}, Session.max_ops_per_call() + 1)

    body =
      conn
      |> authed()
      |> post(ops_url(@slug), Jason.encode!(%{"ops" => oversized}))
      |> json_response(422)

    assert body["error"]["code"] == "batch_too_large"
    assert body["error"]["message"] =~ "#{Session.max_ops_per_call()}"
  end

  # ── 4. Not found ──────────────────────────────────────────────────────────

  test "returns 404 for an unknown slug", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post(ops_url("ghost-slug-that-does-not-exist"), Jason.encode!(%{"ops" => []}))
      |> json_response(404)

    assert body["error"]["code"] == "not_found"
    assert body["error"]["message"] =~ "ghost-slug-that-does-not-exist"
  end

  # ── 5. Success ────────────────────────────────────────────────────────────

  test "returns 200 with ok:true and applied count for a valid op on an existing sheet", %{
    conn: conn
  } do
    create_sheet(@slug)

    op = %{"op" => "set_cell", "tab" => 0, "ref" => "B1", "raw" => "world"}

    body =
      conn
      |> authed()
      |> post(ops_url(@slug, @dataset), Jason.encode!(%{"ops" => [op]}))
      |> json_response(200)

    assert body["ok"] == true
    assert body["slug"] == @slug
    assert is_integer(body["rev"]) and body["rev"] >= 1
    assert body["applied"] == 1
    assert body["errors"] == []
    # Additive replayed field: a first (non-retried) request is false.
    assert body["replayed"] == false
  end

  # ── 6. sort_range rides the existing endpoint (SF-A) ──────────────────────

  test "sort_range happy path + a refusal both ride POST /ops", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "sort-wire",
          "content" => %{
            "tabs" => [%{"name" => "S", "cells" => %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}}}]
          }
        },
        @dataset
      )

    happy = %{
      "op" => "sort_range",
      "tab" => 0,
      "range" => "A1:A2",
      "keys" => [%{"col" => 0, "dir" => "asc"}]
    }

    body =
      conn
      |> authed()
      |> post(ops_url("sort-wire", @dataset), Jason.encode!(%{"ops" => [happy]}))
      |> json_response(200)

    assert body["ok"] == true
    assert body["applied"] == 1
    assert body["errors"] == []

    # A refusal surfaces per-op in the errors list (the op is applied
    # individually — the endpoint itself still returns 200).
    bad = %{
      "op" => "sort_range",
      "tab" => 0,
      "range" => "A1:A2",
      "keys" => [%{"col" => 0, "dir" => "up"}]
    }

    body2 =
      build_conn()
      |> authed()
      |> post(ops_url("sort-wire", @dataset), Jason.encode!(%{"ops" => [bad]}))
      |> json_response(200)

    assert body2["applied"] == 0
    assert [%{"code" => "invalid_sort_keys"}] = body2["errors"]
  end

  # ── 7. Idempotency: request_id validation + exactly-once replay (QR-A) ─────

  test "returns 422 invalid_request_id when request_id is not a non-empty string", %{conn: conn} do
    create_sheet(@slug)
    op = %{"op" => "set_cell", "tab" => 0, "ref" => "B1", "raw" => "world"}

    for bad <- [123, ["x"], "", %{"k" => "v"}] do
      body =
        conn
        |> authed()
        |> post(
          ops_url(@slug, @dataset),
          Jason.encode!(%{"ops" => [op], "request_id" => bad})
        )
        |> json_response(422)

      assert body["error"]["code"] == "invalid_request_id"
    end
  end

  test "threads request_id end-to-end: an HTTP retry replays and applies exactly once", %{
    conn: conn
  } do
    # Seed a cell at A3 so a non-idempotent insert_rows is observable: one
    # application shifts A3 → A5, a double-apply would land it at A7.
    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{"tabs" => [%{"name" => "T0", "cells" => %{"A3" => %{"v" => "x"}}}]}
        },
        @dataset
      )

    insert = %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2}
    payload = Jason.encode!(%{"ops" => [insert], "request_id" => "http-retry-1"})

    first =
      conn
      |> authed()
      |> post(ops_url(@slug, @dataset), payload)
      |> json_response(200)

    assert first["applied"] == 1
    assert first["replayed"] == false

    # The retry (identical request_id) replays and applies nothing.
    second =
      build_conn()
      |> authed()
      |> post(ops_url(@slug, @dataset), payload)
      |> json_response(200)

    assert second["replayed"] == true
    assert second["rev"] == first["rev"]
    assert second["applied"] == first["applied"]

    # Single application: A3 shifted to A5 exactly once (no A7 double-shift).
    {:ok, content} = Session.peek(@slug, @dataset)
    cells = get_in(content, ["tabs", Access.at(0), "cells"])
    assert Map.has_key?(cells, "A5")
    refute Map.has_key?(cells, "A7")
  end

  # ── 8. The ring is unreachable: a TRANSIENT 503, not a 422 ───────────────
  #
  # `Session.apply_ops/5` answers `{:error, :replay_unavailable}` when the
  # exactly-once ring has no table to read (the fail-CLOSED backstop — see
  # session_ring_crash_test.exs (2)). That is a SERVER-side, transient outage:
  # the caller's batch was never applied and the SAME request will succeed once
  # the ring is back. The catch-all rendered it as 422 `session_start_failed`,
  # which tells a client its request was malformed and — because it is a 4xx —
  # stops the retry that would have fixed it. Same class as
  # `:session_unavailable`, so it takes the same envelope: 503 + `retry-after`.
  #
  # RED on the pre-change controller: 422, body code "session_start_failed".
  test "returns 503 replay_unavailable with a retry-after hint when the replay ring is gone",
       %{conn: conn} do
    create_sheet(@slug)

    # A request_id is what makes the session consult the ring at all; without
    # one the batch never reaches the `:unavailable` branch.
    payload =
      Jason.encode!(%{
        "ops" => [%{"op" => "set_cell", "tab" => 0, "ref" => "B1", "raw" => "world"}],
        "request_id" => "ring-gone-1"
      })

    {resp, _log} =
      with_log(fn ->
        # An explicit delete is the one case the ETS heir cannot cover, and the
        # only way to reach the backstop from the outside.
        :ets.delete(@ring_table)
        assert :ets.whereis(@ring_table) == :undefined

        conn
        |> authed()
        |> post(ops_url(@slug, @dataset), payload)
      end)

    # Status and code asserted as ONE tuple so a failure prints both sides —
    # the pre-change controller reads `left: {422, "session_start_failed"}`,
    # which is the whole defect in one line. A 4xx tells the client its request
    # was wrong and stops the retry that would have fixed it.
    assert {resp.status, Jason.decode!(resp.resp_body)["error"]["code"]} ==
             {503, "replay_unavailable"}

    assert Plug.Conn.get_resp_header(resp, "retry-after") != [],
           "a 503 on this door carries retry-after (the :session_unavailable precedent)"

    # Refused, not applied: nothing landed.
    {:ok, content} = Session.peek(@slug, @dataset)
    refute Map.has_key?(get_in(content, ["tabs", Access.at(0), "cells"]), "B1")
  end

  # ── the authorization wall (pds-w44-bl-ops-controller-apply-ops-ungated) ──
  #
  # This HTTP door is the SECOND Session.apply_ops surface — the LiveView
  # write wall (sheet_grid/ops.ex `write_capable: false`) does not and cannot
  # cover it. The chain, derived from source: route `auth: :ingest`
  # (sheets.ex register_routes) → `pipe_through :ingest` (router/plugins.ex)
  # → pipeline :ingest → RequireIngestToken (router.ex), which authorizes
  # ONLY a constant-time ingest-secret match OR an api_token satisfying
  # `Tenancy.Auth.permits?(token, :admin)` — every other principal 401s
  # before the controller. These tests settle that BY RUN with the STORED
  # cell value as the oracle, against a LIVE session (so the proof can never
  # be satisfied by a vacuous "no session started" predicate).

  test "a write-denied principal cannot reach Session.apply_ops — settled by the STORED " <>
         "cell value against a LIVE session",
       %{conn: conn} do
    create_sheet("authz-probe")

    # Positive control FIRST: the authed door writes for real and the oracle
    # can see a landed write — and the session is now LIVE, so the denials
    # below are proven against a running target.
    body =
      conn
      |> authed()
      |> post(
        ops_url("authz-probe", @dataset),
        Jason.encode!(%{
          "ops" => [%{"op" => "set_cell", "tab" => 0, "ref" => "B1", "raw" => "legit"}]
        })
      )
      |> json_response(200)

    assert body["applied"] == 1
    assert is_pid(Session.whereis("authz-probe", @dataset))

    probe =
      Jason.encode!(%{
        "ops" => [%{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "hacked"}]
      })

    # (a) anonymous — no bearer at all.
    resp_anon =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(ops_url("authz-probe", @dataset), probe)

    assert resp_anon.status == 401

    # (b) the SHARPEST write-denied principal: a VALID, live api_token
    # carrying read+write permissions — but not admin. Generic write
    # permission does NOT open this door.
    raw = "sheets-nonadmin-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, "sheets non-admin", "test", ["read", "write"])

    resp_writer =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(ops_url("authz-probe", @dataset), probe)

    assert resp_writer.status == 401
    assert Jason.decode!(resp_writer.resp_body)["error"]["code"] == "unauthorized"

    # THE ORACLE — the stored cell value, both layers. The session's
    # authoritative in-memory content:
    {:ok, content} = Session.peek("authz-probe", @dataset)
    cells = get_in(content, ["tabs", Access.at(0), "cells"])
    assert cells["A1"]["v"] == "hello"
    refute inspect(content) =~ "hacked"
    # …the positive control's write IS visible to the same oracle:
    assert inspect(cells["B1"]) =~ "legit"

    # And the PERSISTED document, behind the read-your-writes flush barrier:
    assert :ok = Session.flush("authz-probe", @dataset)
    {:ok, doc} = Content.get_document("drafts.authz-probe", "sheet", @dataset)
    stored_cells = get_in(doc.content, ["tabs", Access.at(0), "cells"])
    assert stored_cells["A1"]["v"] == "hello"
    refute inspect(doc.content) =~ "hacked"
  end

  test "an ADMIN api_token opens the door without the shared secret (the second " <>
         "RequireIngestToken arm is live, not decorative)",
       %{conn: conn} do
    create_sheet("authz-admin")

    raw = "sheets-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "sheets admin", "test", ["read", "write", "admin"])

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(
        ops_url("authz-admin", @dataset),
        Jason.encode!(%{
          "ops" => [%{"op" => "set_cell", "tab" => 0, "ref" => "C1", "raw" => "by-admin"}]
        })
      )
      |> json_response(200)

    assert body["applied"] == 1

    {:ok, content} = Session.peek("authz-admin", @dataset)
    assert inspect(get_in(content, ["tabs", Access.at(0), "cells"])["C1"]) =~ "by-admin"
  end
end
