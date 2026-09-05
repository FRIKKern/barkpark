defmodule BarkparkWeb.BulldocsIntentsControllerTest do
  @moduledoc """
  P6.U6a (barkpark-jwai) — the pending-intents API over `paper_events`, the
  Barkpark half of the loop-closer.

  Mirrors the paper-ingest endpoint's auth shape: `Authorization: Bearer
  <ingest token>` via the `:ingest` pipeline (RequireIngestToken).
  Asserts a valid token lists pending `action:*`/`simplify-*` intents, that
  `POST …/processed` marks one (so a follow-up GET omits it), and that a
  request without the token is rejected 401 (same as BulldocsIngestControllerTest).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Plugins.Bulldocs.Events

  # Set in config/test.exs (same shared-secret ingest token the papers test uses).
  @token "barkpark-test-ingest-token"
  @index_path "/v1/plugins/bulldocs/intents"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  describe "auth" do
    test "rejects a request with no token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get(@index_path)

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "rejects a request with a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> get(@index_path)

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /v1/plugins/bulldocs/intents" do
    test "returns only the pending actionable intents", %{conn: conn} do
      {:ok, build} =
        Events.create_event(%{"goal_id" => "bd-ix", "event_type" => "action:build"})

      {:ok, _lifecycle} =
        Events.create_event(%{"goal_id" => "bd-ix", "event_type" => "goal-opened"})

      conn = authed(conn) |> get(@index_path)
      resp = json_response(conn, 200)

      types = Enum.map(resp["intents"], & &1["event_type"])
      ids = Enum.map(resp["intents"], & &1["id"])

      assert build.id in ids
      assert "action:build" in types
      refute "goal-opened" in types

      intent = Enum.find(resp["intents"], &(&1["id"] == build.id))
      assert intent["goal_id"] == "bd-ix"
      assert Map.has_key?(intent, "branch")
      assert Map.has_key?(intent, "paper_slug")
      assert Map.has_key?(intent, "payload_html")
      assert Map.has_key?(intent, "inserted_at")
    end
  end

  describe "POST /v1/plugins/bulldocs/intents/:id/processed" do
    test "marks the intent so a follow-up GET omits it", %{conn: conn} do
      {:ok, intent} =
        Events.create_event(%{"goal_id" => "bd-mark", "event_type" => "simplify-request"})

      # Present before marking.
      before_ids =
        authed(build_conn())
        |> get(@index_path)
        |> json_response(200)
        |> Map.fetch!("intents")
        |> Enum.map(& &1["id"])

      assert intent.id in before_ids

      conn = authed(conn) |> post("/v1/plugins/bulldocs/intents/#{intent.id}/processed")
      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["id"] == intent.id

      # Absent after marking.
      after_ids =
        authed(build_conn())
        |> get(@index_path)
        |> json_response(200)
        |> Map.fetch!("intents")
        |> Enum.map(& &1["id"])

      refute intent.id in after_ids
    end

    test "unknown id → 404 not_found", %{conn: conn} do
      conn =
        authed(conn) |> post("/v1/plugins/bulldocs/intents/#{Ecto.UUID.generate()}/processed")

      resp = json_response(conn, 404)
      assert resp["ok"] == false
      assert resp["error"] == "not_found"
    end

    test "non-UUID id → 404 not_found (no Ecto.Query.CastError)", %{conn: conn} do
      conn =
        authed(conn) |> post("/v1/plugins/bulldocs/intents/evt_does_not_exist_12345/processed")

      resp = json_response(conn, 404)
      assert resp["ok"] == false
      assert resp["error"] == "not_found"
      assert resp["id"] == "evt_does_not_exist_12345"
    end

    test "rejects a mark without a token", %{conn: conn} do
      {:ok, intent} =
        Events.create_event(%{"goal_id" => "bd-noauth", "event_type" => "action:build"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/plugins/bulldocs/intents/#{intent.id}/processed")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      # Untouched — still pending.
      assert is_nil(Events.get_event(intent.id).processed_at)
    end
  end
end
