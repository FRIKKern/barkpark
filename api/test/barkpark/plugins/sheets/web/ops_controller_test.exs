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
    body = conn |> authed() |> post(ops_url(@slug), Jason.encode!(%{"data" => []})) |> json_response(422)

    assert body["error"]["code"] == "malformed_ops"
    assert body["error"]["message"] =~ "ops"
  end

  # ── 3. Batch too large ────────────────────────────────────────────────────

  test "returns 422 batch_too_large when ops list exceeds Session.max_ops_per_call/0", %{conn: conn} do
    oversized = List.duplicate(%{"op" => "noop"}, Session.max_ops_per_call() + 1)
    body = conn |> authed() |> post(ops_url(@slug), Jason.encode!(%{"ops" => oversized})) |> json_response(422)

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

  test "returns 200 with ok:true and applied count for a valid op on an existing sheet", %{conn: conn} do
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
  end
end
