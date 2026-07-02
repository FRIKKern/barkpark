defmodule Barkpark.Plugins.Sheets.Web.ImportControllerTest do
  @moduledoc """
  Contract tests for `POST /v1/plugins/sheets/import`.

  Covers the controller's distinct response paths:
    - 401 when the shared-secret ingest token is absent
    - 422 when the `file` multipart field is missing (`missing_file`)
    - 422 when the extension is unsupported (`unsupported_format`)
    - 200 for a valid CSV upload with slug/title derived from the filename
    - 413 when the upload exceeds the byte cap (`upload_too_large`)
    - 422 when an explicit slug param fails the slug pattern (`invalid_slug`)

  Runs against the live DB. `async: false` to avoid dataset collisions.
  """

  use BarkparkWeb.ConnCase, async: false

  @token "barkpark-test-ingest-token"
  @import_path "/v1/plugins/sheets/import"
  @dataset "import_ctrl_test"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp write_upload!(tmp_dir, filename, content) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, content)
    %Plug.Upload{path: path, filename: filename, content_type: "application/octet-stream"}
  end

  # ── 1. Auth gate ────────────────────────────────────────────────────────────

  @tag :tmp_dir
  test "returns 401 when no Authorization header is present", %{conn: conn, tmp_dir: tmp_dir} do
    upload = write_upload!(tmp_dir, "x.csv", "a,b\r\n")

    body =
      conn
      |> post(@import_path, %{"file" => upload})
      |> json_response(401)

    assert body["error"]["code"] == "unauthorized"
  end

  # ── 2. Missing file field ───────────────────────────────────────────────────

  test "returns 422 missing_file when no file field is provided", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post(@import_path, %{"slug" => "irrelevant"})
      |> json_response(422)

    assert body["error"]["code"] == "missing_file"
    assert body["error"]["message"] =~ "file"
  end

  # ── 3. Unsupported extension ────────────────────────────────────────────────

  @tag :tmp_dir
  test "returns 422 unsupported_format for an unknown extension", %{conn: conn, tmp_dir: tmp_dir} do
    upload = write_upload!(tmp_dir, "report.pdf", "fake pdf content")

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(422)

    assert body["error"]["code"] == "unsupported_format"
    assert body["error"]["message"] =~ "report.pdf"
  end

  # ── 4. CSV happy path — slug and title derive from filename ─────────────────

  @tag :tmp_dir
  test "returns 200 for a valid CSV; slug/title derive from the filename",
       %{conn: conn, tmp_dir: tmp_dir} do
    upload = write_upload!(tmp_dir, "My Budget.csv", "Item,Cost\r\nOps,500\r\n")

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(200)

    assert body["ok"] == true
    assert body["slug"] == "my-budget"
    assert body["type"] == "sheet"
    assert body["tabs"] == 1
    assert body["cells"] == 4
  end

  # ── 4b. UTF-16LE+BOM TSV transcodes and imports a 2×2 grid ──────────────────

  @tag :tmp_dir
  test "imports a UTF-16LE+BOM TSV as a 2x2 grid", %{conn: conn, tmp_dir: tmp_dir} do
    utf16 = :unicode.characters_to_binary("a\tb\r\nc\td\r\n", :utf8, {:utf16, :little})
    upload = write_upload!(tmp_dir, "grid.tsv", <<0xFF, 0xFE>> <> utf16)

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(200)

    assert body["ok"] == true
    assert body["cells"] == 4
  end

  # ── 4c. Explicit sep param overrides the separator sniff ────────────────────

  @tag :tmp_dir
  test "explicit sep param beats the sniff", %{conn: conn, tmp_dir: tmp_dir} do
    # "a;b" sniffs to ";" (2 cells); forcing sep="," keeps it one field (1 cell).
    upload = write_upload!(tmp_dir, "semi.csv", "a;b\r\n")

    sniffed =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset, "slug" => "sniffed"})
      |> json_response(200)

    assert sniffed["cells"] == 2

    upload2 = write_upload!(tmp_dir, "semi2.csv", "a;b\r\n")

    forced =
      conn
      |> authed()
      |> post(@import_path, %{
        "file" => upload2,
        "dataset" => @dataset,
        "slug" => "forced",
        "sep" => ","
      })
      |> json_response(200)

    assert forced["cells"] == 1
  end

  # ── 5. Byte cap — rejects before parsing ───────────────────────────────────

  @tag :tmp_dir
  test "returns 413 upload_too_large when the file exceeds 15 MB", %{conn: conn, tmp_dir: tmp_dir} do
    # 15_000_001 bytes — one byte over the cap
    upload = write_upload!(tmp_dir, "giant.csv", :binary.copy("a", 15_000_001))

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(413)

    assert body["error"]["code"] == "upload_too_large"
    assert body["error"]["message"] =~ "15000000"
  end

  # ── 6. Invalid slug param ──────────────────────────────────────────────────

  @tag :tmp_dir
  test "returns 422 invalid_slug when the slug param fails the pattern",
       %{conn: conn, tmp_dir: tmp_dir} do
    upload = write_upload!(tmp_dir, "data.csv", "a\r\n")

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "slug" => "has spaces!", "dataset" => @dataset})
      |> json_response(422)

    assert body["error"]["code"] == "invalid_slug"
    assert body["error"]["message"] =~ "has spaces!"
  end
end
