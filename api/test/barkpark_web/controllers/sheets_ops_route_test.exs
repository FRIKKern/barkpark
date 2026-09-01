defmodule BarkparkWeb.SheetsOpsRouteTest.HaltingPersist do
  @moduledoc false
  # A before_save hook that halts ONLY the sheets-session persist path —
  # installed via the `:barkpark, :plugins` env seam so the canonical upsert
  # fails like a real plugin gate refusing the write (no mocking). Mirrors
  # Barkpark.Plugins.Sheets.SessionHardeningTest.HaltingPersist.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt_session_persist/1]}

  def halt_session_persist(%{ctx: %{source: "sheets_session"}}),
    do: {:halt, "forced persist failure (test)"}

  def halt_session_persist(_payload), do: :ok
end

defmodule BarkparkWeb.SheetsOpsRouteTest do
  @moduledoc """
  M1 route locks for the Sheets wire-op API:

      POST /v1/plugins/sheets/:slug/ops

  Rides the `:ingest` bucket (RequireIngestToken) like import/export. The
  controller is a thin shim over the CORE `Barkpark.Plugins.Sheets.Session` —
  per-op errors land in the 200 receipt's `errors` (indexed), whole-request
  failures are 401/404/422 (+ 503 for the transient session/flush windows).
  The export-flush lock closes the read-your-writes loop: a wire op followed
  by an immediate export.csv serves the new value (the export controller
  flushes the live session) — and a FAILED flush is a 503, never the stale
  row served as fresh.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @dataset "sheets_m1_ops_route_test"

  setup do
    stop_all_sessions()

    # Long debounce so persistence happens only where the test asks for it
    # (flush via export, stop via on_exit); long idle-stop so no session
    # dies mid-test.
    Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session,
      debounce_ms: 60_000,
      idle_stop_ms: 60_000
    )

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
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

    test "422 batch_too_large when the ops list exceeds the per-call cap", %{conn: conn} do
      create_sheet("ops-too-many", %{})
      n = Session.max_ops_per_call() + 1
      ops = for i <- 1..n, do: set_cell("A#{i}", i)

      body =
        conn
        |> authed()
        |> post(ops_path("ops-too-many"), %{"ops" => ops, "dataset" => @dataset})
        |> json_response(422)

      assert body["error"]["code"] == "batch_too_large"
      assert body["error"]["message"] =~ "#{n} ops"
      # Refused pre-mailbox — no session was started for the oversized call.
      assert Session.whereis("ops-too-many", @dataset) == nil
    end

    test "503 session_restarting when the session dies twice in the call window", %{conn: conn} do
      create_sheet("ops-dead", %{})
      {:ok, _} = Session.apply_ops("ops-dead", @dataset, [set_cell("A1", 1)])
      pid = Session.whereis("ops-dead", @dataset)

      # Suspend registry cleanup so the dead pid stays registered across the
      # call AND its single retry — the bounded double-death window.
      partitions = registry_partitions()
      Enum.each(partitions, &:sys.suspend/1)

      conn =
        try do
          GenServer.stop(pid, :normal, 5_000)

          conn
          |> authed()
          |> post(ops_path("ops-dead"), %{"ops" => [set_cell("A1", 2)], "dataset" => @dataset})
        after
          Enum.each(partitions, &:sys.resume/1)
        end

      assert json_response(conn, 503)["error"]["code"] == "session_restarting"
      assert get_resp_header(conn, "retry-after") == ["2"]
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

      assert get_in(content, ["tabs", Access.at(0), "cells", "B1"]) == %{
               "f" => "A1*10",
               "v" => 20,
               "t" => "n"
             }
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

  describe "structural ops over the wire" do
    test "insert_rows shifts keys and rewrites formulas through the endpoint", %{conn: conn} do
      create_sheet("ops-insrow", %{
        "A1" => %{"v" => 5},
        "A2" => %{"f" => "A1*2", "v" => 10, "t" => "n"}
      })

      body =
        conn
        |> authed()
        |> post(ops_path("ops-insrow"), %{
          "ops" => [%{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2}],
          "dataset" => @dataset
        })
        |> json_response(200)

      assert %{"ok" => true, "rev" => 1, "applied" => 1, "errors" => []} = body

      {:ok, content} = Session.peek("ops-insrow", @dataset)
      cells = get_in(content, ["tabs", Access.at(0), "cells"])
      assert cells == %{"A3" => %{"v" => 5}, "A4" => %{"f" => "A3*2", "v" => 10, "t" => "n"}}
    end

    test "tab + layout ops apply in one batch; per-op errors keep their index", %{conn: conn} do
      create_sheet("ops-struct-mix", %{"A1" => %{"v" => "x"}})

      ops = [
        %{"op" => "add_tab", "name" => "T1"},
        %{"op" => "rename_tab", "tab" => 0, "name" => "Main"},
        %{"op" => "set_col_width", "tab" => 0, "col" => 1, "px" => 140},
        %{"op" => "delete_tab", "tab" => 1},
        # The last tab cannot be deleted — indexed error, batch continues.
        %{"op" => "delete_tab", "tab" => 0},
        %{"op" => "set_row_height", "tab" => 0, "row" => 2, "px" => 36}
      ]

      body =
        conn
        |> authed()
        |> post(ops_path("ops-struct-mix"), %{"ops" => ops, "dataset" => @dataset})
        |> json_response(200)

      assert %{"ok" => true, "rev" => 5, "applied" => 5} = body
      assert [%{"index" => 4, "code" => "last_tab"}] = body["errors"]

      {:ok, content} = Session.peek("ops-struct-mix", @dataset)
      [tab] = content["tabs"]
      assert tab["name"] == "Main"
      assert tab["col_widths"] == %{"1" => 140}
      assert tab["row_heights"] == %{"2" => 36}
    end

    test "a structural op missing its fields is malformed_op; invalid at is invalid_at", %{
      conn: conn
    } do
      create_sheet("ops-struct-bad", %{})

      ops = [
        %{"op" => "insert_rows", "tab" => 0, "at" => 2},
        %{"op" => "delete_cols", "tab" => 0, "at" => 0, "count" => 1}
      ]

      body =
        conn
        |> authed()
        |> post(ops_path("ops-struct-bad"), %{"ops" => ops, "dataset" => @dataset})
        |> json_response(200)

      assert %{"applied" => 0} = body

      assert [%{"index" => 0, "code" => "malformed_op"}, %{"index" => 1, "code" => "invalid_at"}] =
               body["errors"]
    end

    test "JSON null px clears a width over the wire", %{conn: conn} do
      create_sheet("ops-struct-px", %{})

      %{"applied" => 1} =
        conn
        |> authed()
        |> post(ops_path("ops-struct-px"), %{
          "ops" => [%{"op" => "set_col_width", "tab" => 0, "col" => 3, "px" => 88}],
          "dataset" => @dataset
        })
        |> json_response(200)

      %{"applied" => 1, "errors" => []} =
        build_conn()
        |> authed()
        |> post(ops_path("ops-struct-px"), %{
          "ops" => [%{"op" => "set_col_width", "tab" => 0, "col" => 3, "px" => nil}],
          "dataset" => @dataset
        })
        |> json_response(200)

      {:ok, content} = Session.peek("ops-struct-px", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "col_widths"]) == %{}
    end
  end

  describe "undo/redo over the wire (M4)" do
    test "an op stamped with a user undoes and redoes through the endpoint", %{conn: conn} do
      create_sheet("ops-undo", %{"A1" => %{"v" => "before"}})

      %{"ok" => true, "applied" => 1} =
        conn
        |> authed()
        |> post(ops_path("ops-undo"), %{
          "ops" => [
            %{
              "op" => "set_cell",
              "tab" => 0,
              "ref" => "A1",
              "raw" => "after",
              "user" => "wire-user"
            }
          ],
          "dataset" => @dataset
        })
        |> json_response(200)

      %{"ok" => true, "rev" => 2, "applied" => 1, "errors" => []} =
        build_conn()
        |> authed()
        |> post(ops_path("ops-undo"), %{
          "ops" => [%{"op" => "undo", "user" => "wire-user"}],
          "dataset" => @dataset
        })
        |> json_response(200)

      {:ok, content} = Session.peek("ops-undo", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => "before"}

      %{"rev" => 3, "applied" => 1, "errors" => []} =
        build_conn()
        |> authed()
        |> post(ops_path("ops-undo"), %{
          "ops" => [%{"op" => "redo", "user" => "wire-user"}],
          "dataset" => @dataset
        })
        |> json_response(200)

      {:ok, content} = Session.peek("ops-undo", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => "after"}
    end

    test "undo without a user / for a userless history rejects per-op", %{conn: conn} do
      create_sheet("ops-undo-bad", %{})

      ops = [
        # No user stamp — records no history…
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => 1},
        # …so this user has nothing; and a userless undo is invalid outright.
        %{"op" => "undo", "user" => "wire-user"},
        %{"op" => "undo"}
      ]

      body =
        conn
        |> authed()
        |> post(ops_path("ops-undo-bad"), %{"ops" => ops, "dataset" => @dataset})
        |> json_response(200)

      assert %{"applied" => 1} = body

      assert [
               %{"index" => 1, "code" => "nothing_to_undo"},
               %{"index" => 2, "code" => "invalid_user"}
             ] = body["errors"]
    end
  end

  describe "export flush (read-your-writes)" do
    test "a wire op followed by an immediate export.csv serves the new value", %{conn: conn} do
      create_sheet("ops-export", %{"A1" => %{"v" => "stale-value"}})

      %{"ok" => true, "applied" => 1} =
        conn
        |> authed()
        |> post(ops_path("ops-export"), %{
          "ops" => [set_cell("A1", "wire-value")],
          "dataset" => @dataset
        })
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

    test "a failed flush is a 503 with a retry hint — never the stale row served as fresh", %{
      conn: conn
    } do
      create_sheet("ops-export-fail", %{"A1" => %{"v" => "stale-value"}})

      %{"ok" => true, "applied" => 1} =
        conn
        |> authed()
        |> post(ops_path("ops-export-fail"), %{
          "ops" => [set_cell("A1", "wire-value")],
          "dataset" => @dataset
        })
        |> json_response(200)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_failing_persist(fn ->
            conn =
              build_conn()
              |> authed()
              |> get("/v1/plugins/sheets/ops-export-fail/export.csv?dataset=#{@dataset}")

            assert json_response(conn, 503)["error"]["code"] == "flush_failed"
            assert get_resp_header(conn, "retry-after") == ["2"]
          end)
        end)

      assert log =~ "persist failed"

      # The failure window closed — the retry the hint promised succeeds and
      # serves the fresh value (the session stayed dirty, nothing was lost).
      csv =
        build_conn()
        |> authed()
        |> get("/v1/plugins/sheets/ops-export-fail/export.csv?dataset=#{@dataset}")
        |> response(200)

      assert csv =~ "wire-value"
      refute csv =~ "stale-value"
    end
  end

  # ── hardening helpers ──────────────────────────────────────────────────────

  # `Barkpark.Plugins.Sheets` rides along with the halting double for a reason.
  # `:barkpark, :plugins` is the INSTALLED-plugin whitelist, and since the
  # BARKPARK_PLUGINS kill switch became effective at request time
  # (`BarkparkWeb.Plugs.PluginRouteGuard`), replacing it wholesale also
  # un-serves every sheets route — the `export.csv` call below would 404
  # before the flush it is here to fail. Listing Sheets keeps the plugin
  # installed; the double is additive, contributing only its `before_save`
  # halt. This is the seam behaving correctly, not a workaround.
  defp with_failing_persist(fun) do
    prior = Application.fetch_env(:barkpark, :plugins)

    Application.put_env(:barkpark, :plugins, [
      BarkparkWeb.SheetsOpsRouteTest.HaltingPersist,
      Barkpark.Plugins.Sheets
    ])

    try do
      fun.()
    after
      case prior do
        {:ok, v} -> Application.put_env(:barkpark, :plugins, v)
        :error -> Application.delete_env(:barkpark, :plugins)
      end
    end
  end

  defp registry_partitions do
    Barkpark.Plugins.Sheets.SessionRegistry
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end
end
