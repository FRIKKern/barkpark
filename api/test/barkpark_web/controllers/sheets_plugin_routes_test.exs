defmodule BarkparkWeb.SheetsPluginRoutesTest do
  @moduledoc """
  M5 route locks for the Sheets plugin conversion API:

      POST /v1/plugins/sheets/import
      GET  /v1/plugins/sheets/:slug/export.{xlsx,csv,tsv,md,html}

  Every route rides the `:ingest` bucket (RequireIngestToken) — the auth
  gate is asserted for all six. Import fixtures are built in-test with
  elixlsx / generated CSV strings (no binary fixtures in git). The cap
  test generates a >50_000-cell CSV and expects 413. A full HTTP-level
  round trip (import xlsx → export.xlsx → re-import) closes the loop.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.XlsxImport
  alias Barkpark.Plugins.Sheets.Engine
  alias Elixlsx.{Sheet, Workbook}

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @import_path "/v1/plugins/sheets/import"
  @dataset "sheets_m5_routes_test"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp export_path(slug, ext, query \\ "") do
    "/v1/plugins/sheets/#{slug}/export.#{ext}?dataset=#{@dataset}" <> query
  end

  defp upload!(tmp_dir, filename, binary) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, binary)
    %Plug.Upload{path: path, filename: filename, content_type: "application/octet-stream"}
  end

  defp fixture_xlsx do
    sheets = [
      %Sheet{
        name: "Budget",
        rows: [
          [["Item", bold: true], ["Cost", bold: true]],
          ["Ops", [1200.5, num_format: "$#,##0.00"]],
          # the merged band's value lives at its anchor, A3
          [[{:formula, "SUM(B2:B2)", value: 1200.5}]]
        ],
        merge_cells: [{"A3", "B3"}],
        col_widths: %{1 => 20.0},
        pane_freeze: {1, 0}
      }
    ]

    {:ok, {_name, binary}} = Elixlsx.write_to_memory(%Workbook{sheets: sheets}, "fixture.xlsx")
    binary
  end

  defp import_fixture!(conn, tmp_dir, slug) do
    upload = upload!(tmp_dir, "#{slug}.xlsx", fixture_xlsx())

    conn
    |> authed()
    |> post(@import_path, %{"file" => upload, "slug" => slug, "dataset" => @dataset})
    |> json_response(200)
  end

  # ── auth gate ───────────────────────────────────────────────────────────────

  describe "auth" do
    @tag :tmp_dir
    test "import rejects without a token", %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "x.csv", "a,b\r\n")
      conn = post(conn, @import_path, %{"file" => upload})
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "every export format rejects without a token", _context do
      for ext <- ~w(xlsx csv tsv md html) do
        conn = get(build_conn(), export_path("nope", ext))

        assert json_response(conn, 401)["error"]["code"] == "unauthorized",
               "expected 401 for export.#{ext}"
      end
    end

    test "a wrong token rejects", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-token")
        |> get(export_path("nope", "csv"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  # ── import ──────────────────────────────────────────────────────────────────

  describe "import" do
    @tag :tmp_dir
    test "xlsx multipart creates a sheet doc; engine + layout ride the save path",
         %{conn: conn, tmp_dir: tmp_dir} do
      body = import_fixture!(conn, tmp_dir, "budget-import")

      assert %{"ok" => true, "slug" => "budget-import", "type" => "sheet", "tabs" => 1} = body
      assert body["cells"] == 5

      {:ok, doc} = Content.get_document("drafts.budget-import", "sheet", @dataset)
      tab = hd(doc.content["tabs"])

      assert tab["name"] == "Budget"
      assert tab["frozen_rows"] == 1
      assert tab["merges"] == ["A3:B3"]
      assert tab["col_widths"] == %{"1" => 140}
      assert tab["cells"]["A1"] == %{"v" => "Item", "s" => %{"b" => true}}
      assert tab["cells"]["B2"] == %{"v" => 1200.5, "fmt" => "currency"}
      # the formula recomputed on the save path
      assert tab["cells"]["A3"] == %{"f" => "SUM(B2:B2)", "v" => 1200.5, "t" => "n"}
    end

    @tag :tmp_dir
    test "csv import creates a single-tab sheet; slug/title derive from the filename",
         %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "Team Scores.csv", "Name,Score\r\nAlice,42\r\n")

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(200)

      assert %{"ok" => true, "slug" => "team-scores", "cells" => 4} = body

      {:ok, doc} = Content.get_document("drafts.team-scores", "sheet", @dataset)
      assert doc.title == "Team Scores"
      assert get_in(doc.content, ["tabs", Access.at(0), "cells", "B2", "v"]) == 42
    end

    @tag :tmp_dir
    test "tsv import maps tabs as separators", %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "data.tsv", "a\tb\r\n1\t2\r\n")

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(200)

      assert body["cells"] == 4
    end

    @tag :tmp_dir
    test "more than 50_000 non-empty cells rejects with 413 naming count and cap",
         %{conn: conn, tmp_dir: tmp_dir} do
      # 16_667 rows × 3 columns = 50_001 non-empty cells
      csv = String.duplicate("a,b,c\r\n", 16_667)
      upload = upload!(tmp_dir, "huge.csv", csv)

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(413)

      assert body["error"]["code"] == "sheet_too_large"
      assert body["error"]["message"] =~ "50001"
      assert body["error"]["message"] =~ "50000"
    end

    @tag :tmp_dir
    test "an upload over the byte cap rejects with 413 before any parse",
         %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "big.csv", :binary.copy("a", 15_000_001))

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(413)

      assert body["error"]["code"] == "upload_too_large"
      assert body["error"]["message"] =~ "15000000"
    end

    test "a missing file field is a clear 422", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post(@import_path, %{"slug" => "no-file"})
        |> json_response(422)

      assert body["error"]["code"] == "missing_file"
    end

    @tag :tmp_dir
    test "an unsupported extension is a clear 422", %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "notes.txt", "hello")

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(422)

      assert body["error"]["code"] == "unsupported_format"
    end

    @tag :tmp_dir
    test "a corrupt xlsx is a clear 422", %{conn: conn, tmp_dir: tmp_dir} do
      upload = upload!(tmp_dir, "broken.xlsx", "not actually a zip")

      body =
        conn
        |> authed()
        |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_xlsx"
    end
  end

  # ── export ──────────────────────────────────────────────────────────────────

  describe "export" do
    @tag :tmp_dir
    test "export.xlsx sends the artifact; HTTP round trip preserves the content",
         %{conn: conn, tmp_dir: tmp_dir} do
      import_fixture!(conn, tmp_dir, "rt-sheet")
      {:ok, doc} = Content.get_document("drafts.rt-sheet", "sheet", @dataset)

      conn = build_conn() |> authed() |> get(export_path("rt-sheet", "xlsx"))

      assert response_content_type(conn, :xlsx) =~ "spreadsheetml"

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="rt-sheet.xlsx")]

      # recompute resolves the formula cell's t/v exactly as the save path
      # did for the stored doc — full equality after one engine pass
      {:ok, reimported} = XlsxImport.to_content(response(conn, 200))
      assert Engine.recompute(reimported) == Map.take(doc.content, ["tabs"])
    end

    @tag :tmp_dir
    test "export.csv defaults to tab 0 with the frozen head re-attached",
         %{conn: conn, tmp_dir: tmp_dir} do
      import_fixture!(conn, tmp_dir, "csv-sheet")

      conn = build_conn() |> authed() |> get(export_path("csv-sheet", "csv"))

      assert response_content_type(conn, :csv) =~ "text/csv"
      # B2 carries fmt "currency": CSV exports the DISPLAY string (what Excel/
      # Sheets write on save-as-CSV); the unformatted formula value stays raw.
      assert response(conn, 200) == "Item,Cost\r\nOps,\"$1,200.50\"\r\n1200.5,\r\n"
    end

    @tag :tmp_dir
    test "export.tsv and the ?tab selector; out-of-range tab is 404",
         %{conn: conn, tmp_dir: tmp_dir} do
      import_fixture!(conn, tmp_dir, "tsv-sheet")

      conn = build_conn() |> authed() |> get(export_path("tsv-sheet", "tsv", "&tab=0"))
      assert response(conn, 200) =~ "Item\tCost\r\n"

      conn = build_conn() |> authed() |> get(export_path("tsv-sheet", "tsv", "&tab=9"))
      assert json_response(conn, 404)["error"]["code"] == "tab_not_found"

      conn = build_conn() |> authed() |> get(export_path("tsv-sheet", "tsv", "&tab=x"))
      assert json_response(conn, 422)["error"]["code"] == "invalid_tab"
    end

    @tag :tmp_dir
    test "export.md sends a GitHub table", %{conn: conn, tmp_dir: tmp_dir} do
      import_fixture!(conn, tmp_dir, "md-sheet")

      conn = build_conn() |> authed() |> get(export_path("md-sheet", "md"))

      assert response_content_type(conn, :md) =~ "text/markdown"
      body = response(conn, 200)
      assert body =~ "## Budget"
      assert body =~ "| Item | Cost |"
    end

    @tag :tmp_dir
    test "export.html renders the standalone page inline", %{conn: conn, tmp_dir: tmp_dir} do
      import_fixture!(conn, tmp_dir, "html-sheet")

      conn = build_conn() |> authed() |> get(export_path("html-sheet", "html"))

      assert response_content_type(conn, :html) =~ "text/html"
      assert get_resp_header(conn, "content-disposition") == []
      body = response(conn, 200)
      assert body =~ "<!doctype html>"
      assert body =~ ~s(colspan="2")
    end

    test "an unknown slug is a 404 for every format", _context do
      for ext <- ~w(xlsx csv tsv md html) do
        conn = build_conn() |> authed() |> get(export_path("never-imported", ext))

        assert json_response(conn, 404)["error"]["code"] == "not_found",
               "expected 404 for export.#{ext}"
      end
    end
  end
end
