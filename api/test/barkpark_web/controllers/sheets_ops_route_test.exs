defmodule BarkparkWeb.SheetsOpsRouteTest do
  @moduledoc """
  M1 route locks for the Sheets wire-op API:

      POST /v1/plugins/sheets/:slug/ops

  Rides the `:ingest` bucket (RequireIngestToken) like import/export. The
  controller is a thin shim over the CORE `Barkpark.Sheets.Session` —
  per-op errors land in the 200 receipt's `errors` (indexed), whole-request
  failures are 401/404/422. The export-flush lock closes the
  read-your-writes loop: a wire op followed by an immediate export.csv
  serves the new value (the export controller flushes the live session).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Sheets.Session

  # Set in config/test.exs.
  @token "paperflow-test-ingest-token"
  @dataset "sheets_m1_ops_route_test"

  setup do
    stop_all_sessions()

    # Long debounce so persistence happens only where the test asks for it
    # (flush via export, stop via on_exit); long idle-stop so no session
    # dies mid-test.
    Application.put_env(:barkpark, Barkpark.Sheets.Session,
      debounce_ms: 60_000,
      idle_stop_ms: 60_000
    )

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Sheets.Session)
    end)

    :ok
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp ops_path(slug), do: "/v1/plugins/sheets/#{slug}/ops"

  defp create_sheet(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "T0", "cells" => cells}]}},
        @dataset
      )

    doc
  end

  defp set_cell(ref, raw), do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw}

  describe "auth" do
    test "rejects without a token", %{conn: conn} do
      conn = post(conn, ops_path("nope"), %{"ops" => [], "dataset" => @dataset})
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "rejects a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-token")
        |> post(ops_path("nope"), %{"ops" => [], "dataset" => @dataset})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "errors" do
    test "404 for an unknown slug", %{conn: conn} do
      conn =
        conn
        |> authed()
        |> post(ops_path("no-such-sheet"), %{"ops" => [set_cell("A1", 1)], "dataset" => @dataset})

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "422 when the body carries no ops list", _context do
      create_sheet("ops-malformed", %{})

      for body <- [%{"dataset" => @dataset}, %{"ops" => "nope", "dataset" => @dataset}] do
        conn =
          build_conn()
          |> authed()
          |> post(ops_path("ops-malformed"), body)

        assert json_response(conn, 422)["error"]["code"] == "malformed_ops"
      end

      assert Session.whereis("ops-malformed", @dataset) == nil
    end
  end

  describe "ops" do
    test "applies valid ops, reports invalid ones with their index", %{conn: conn} do
      create_sheet("ops-happy", %{"A1" => %{"v" => 2}})

      ops = [
        set_cell("B1", "=A1*10"),
        set_cell("C1", "plain"),
        %{"op" => "set_cell", "tab" => 0, "ref" => "XFE1", "raw" => 1}
      ]

      body =
        conn
        |> authed()
        |> post(ops_path("ops-happy"), %{"ops" => ops, "dataset" => @dataset})
        |> json_response(200)

      assert %{"ok" => true, "slug" => "ops-happy", "rev" => 2, "applied" => 2} = body
      assert [%{"index" => 2, "code" => "ref_out_of_bounds"}] = body["errors"]

      # The session's memory carries the recomputed formula immediately.
      {:ok, content} = Session.peek("ops-happy", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "cells", "B1"]) == %{"f" => "A1*10", "v" => 20, "t" => "n"}
    end

    test "rev is monotonic across requests on the same session", %{conn: conn} do
      create_sheet("ops-rev", %{})

      first =
        conn
        |> authed()
        |> post(ops_path("ops-rev"), %{"ops" => [set_cell("A1", 1)], "dataset" => @dataset})
        |> json_response(200)

      second =
        build_conn()
        |> authed()
        |> post(ops_path("ops-rev"), %{"ops" => [set_cell("A2", 2)], "dataset" => @dataset})
        |> json_response(200)

      assert first["rev"] == 1
      assert second["rev"] == 2
    end
  end

  describe "export flush (read-your-writes)" do
    test "a wire op followed by an immediate export.csv serves the new value", %{conn: conn} do
      create_sheet("ops-export", %{"A1" => %{"v" => "stale-value"}})

      %{"ok" => true, "applied" => 1} =
        conn
        |> authed()
        |> post(ops_path("ops-export"), %{"ops" => [set_cell("A1", "wire-value")], "dataset" => @dataset})
        |> json_response(200)

      # The row is still the persisted original (debounce hasn't fired)…
      {:ok, doc} = Content.get_document(Content.draft_id("ops-export"), "sheet", @dataset)
      assert get_in(doc.content, ["tabs", Access.at(0), "cells", "A1", "v"]) == "stale-value"

      # …but the export flushes the live session before reading.
      csv =
        build_conn()
        |> authed()
        |> get("/v1/plugins/sheets/ops-export/export.csv?dataset=#{@dataset}")
        |> response(200)

      assert csv =~ "wire-value"
      refute csv =~ "stale-value"
    end
  end
end
