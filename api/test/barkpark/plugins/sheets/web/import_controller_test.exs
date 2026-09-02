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

  # ── 7. Traversal defense — File.read uses the upload temp path, not filename ─
  #
  # Protective test for the Sobelow Traversal.FileModule skip on
  # `ImportController.read_upload/1`: the attacker-controlled `filename` never
  # reaches `File.read`. We build an upload whose `path` points at a real temp
  # file holding our CSV, but whose `filename` is a directory-traversal payload.
  # The import must read OUR temp file (cells == 4), NOT the named path, and the
  # malicious filename must only ever produce a safe slugified basename.
  @tag :tmp_dir
  test "a traversal-laden filename reads the upload temp path, never the named path",
       %{conn: conn, tmp_dir: tmp_dir} do
    body_path = Path.join(tmp_dir, "legit_body.csv")
    File.write!(body_path, "Item,Cost\r\nOps,500\r\n")

    upload = %Plug.Upload{
      path: body_path,
      filename: "../../../../etc/passwd.csv",
      content_type: "text/csv"
    }

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(200)

    # It read our temp file's CSV (2x2 = 4 cells), proving `path` was used —
    # not /etc/passwd (which would not parse to this shape).
    assert body["ok"] == true
    assert body["cells"] == 4
    # The traversal payload collapses to a safe slug (basename rootname,
    # slugified) — no "/" or ".." survives into the derived identity.
    assert body["slug"] == "passwd"
    refute body["slug"] =~ "/"
    refute body["slug"] =~ ".."
  end

  # ── 8. xlsx decompression-bomb guard — the response CLASS ──────────────────
  #
  # Two hostile xlsx uploads, pinned at the HTTP boundary rather than at
  # `XlsxImport.to_content/1`, because the controller is the only thing that
  # decides 413 vs 422 vs an uncaught raise (500). `create/2`'s `with` has no
  # rescue: anything `to_content/1` throws leaves the controller as a 500, so
  # these two cases are the guard's user-visible contract.

  # 320 KiB of incompressible bytes zipped, then the CENTRAL directory's
  # uncompressed-size field rewritten to 0 while the local headers and the
  # deflate stream stay honest. `:zip.list_dir/1` reports "0 bytes"; every
  # reader still inflates the real thing. comp_size × 1032 (deflate's maximum
  # ratio) clears the default 256 MiB ceiling, so the guard refuses it on
  # compressed size alone.
  defp lying_zip_bytes do
    {:ok, {_name, bin}} =
      :zip.create(
        ~c"lying.zip",
        [{~c"xl/payload.bin", :crypto.strong_rand_bytes(320 * 1024)}],
        [:memory]
      )

    eocd_at = byte_size(bin) - 22

    <<_::binary-size(eocd_at), 0x50, 0x4B, 0x05, 0x06, _::binary-size(6), count::little-16,
      _cd_size::little-32, cd_offset::little-32, 0, 0>> = bin

    <<before_cd::binary-size(cd_offset), central::binary>> = bin
    before_cd <> zero_headers(central, count, <<>>)
  end

  defp zero_headers(rest, 0, acc), do: acc <> rest

  defp zero_headers(rest, n, acc) do
    <<0x50, 0x4B, 0x01, 0x02, upto_comp::binary-size(20), _uncomp::little-32, name_len::little-16,
      extra_len::little-16, comment_len::little-16, tail::binary>> = rest

    var_len = name_len + extra_len + comment_len
    <<fixed::binary-size(12), names::binary-size(var_len), more::binary>> = tail

    header =
      <<0x50, 0x4B, 0x01, 0x02>> <>
        upto_comp <>
        <<0::little-32, name_len::little-16, extra_len::little-16, comment_len::little-16>> <>
        fixed <> names

    zero_headers(more, n - 1, acc <> header)
  end

  @tag :tmp_dir
  test "returns 413 sheet_too_large for an xlsx whose central directory declares 0",
       %{conn: conn, tmp_dir: tmp_dir} do
    upload = write_upload!(tmp_dir, "bomb.xlsx", lying_zip_bytes())

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(413)

    assert body["error"]["code"] == "sheet_too_large"
    assert body["error"]["message"] =~ "decompressed size"
  end

  @tag :tmp_dir
  test "returns 422 invalid_xlsx for garbage named .xlsx — the guard abstains, it does not 500",
       %{conn: conn, tmp_dir: tmp_dir} do
    # `guard_decompressed_size/1` no longer carries a function-level
    # `rescue _ -> :ok`. This is the case that rescue was covering for: bytes
    # whose central directory does not read as a zip must still reach
    # `open_package/1` and come back as the canonical 422, never a 413 and
    # never an uncaught exception.
    upload = write_upload!(tmp_dir, "garbage.xlsx", "PK\x03\x04 definitely not a zip")

    body =
      conn
      |> authed()
      |> post(@import_path, %{"file" => upload, "dataset" => @dataset})
      |> json_response(422)

    assert body["error"]["code"] == "invalid_xlsx"
    assert body["error"]["message"] =~ "invalid xlsx"
  end
end
