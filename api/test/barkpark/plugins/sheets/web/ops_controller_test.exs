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

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "ops_controller_test"
  @ingest_token "barkpark-test-ingest-token"
  @slug "ops-ctrl-test-sheet"

  setup do
    stop_all_sessions()

    on_exit(fn -> stop_all_sessions() end)

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
end
