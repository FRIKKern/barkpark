defmodule BarkparkWeb.MediaExtensionlessContentSniffTest do
  @moduledoc """
  studio3-w5 / task-57ee9fff4aae9217 — finding #4: an upload whose FILENAME
  carries no usable extension was stored, and served, as
  `application/octet-stream` even when its BYTES were a real image.

  Gyldendal's 816 source assets were all named `remote.axd` by the old .NET
  image handler. `MIME.from_path("remote.axd")` is `application/octet-stream`,
  so the persisted `mime_type` was octet-stream and the serve edge — which
  re-derived the type from the blob path — answered octet-stream too. 515
  uploads were unrenderable in a browser.

  THE FIX IS AT INGEST, NOT AT SERVE. "Serve the stored mimeType" alone fixes
  nothing here: the stored value was ALREADY octet-stream. `Media.Probe`
  sniffs the leading bytes and only falls back to the extension when the
  content is unrecognised. The serve edge then serves that STORED value
  through `MediaFile.serve_content_type/1`.

  BOTH DEFENCES STILL HOLD, and the negative arm below is the proof:

    * The client's multipart `content_type` stays DISTRUSTED. Sniffing reads
      the BYTES the client uploaded, never the header it claimed, so a header
      lie still cannot set the persisted mime.
    * `neutralize_dangerous_mime/1` stays in the changeset. Sniffed
      `image/svg+xml` is collapsed to octet-stream at write, and
      `MediaFile.serve_content_type/1` collapses the dangerous family again at
      the serve edge. Sniffing makes that defence STRICTLY stronger: a hostile
      SVG dressed as `pixel.png` used to be persisted as `image/png`; now the
      bytes give it away and it is neutralized.

  MUTATION PROOF (criterion 5): replace the `Probe.sniff_mime/2` call in
  `Media.upload/3` with the bare `MIME.from_path(original_name)` it replaced
  and the four "real image bytes" tests RED naming the served content type
  (`"application/octet-stream" != "image/png"` on the `content-type` RESPONSE
  HEADER, not an exit code — a 200 that serves octet-stream is exactly the
  bug). Restoring the call goes green.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  # A real 1x1 PNG: signature + IHDR + IDAT + IEND. Real bytes are the whole
  # point of the criterion — "a .png fixture passes with the bug still present
  # and proves nothing", and neither does a .axd full of the word "fake".
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 100, 96, 0, 0,
         0, 6, 0, 2, 48, 129, 208, 47, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  # A real JPEG head (SOI + APP0/JFIF + SOF0 1x1) — enough for a magic-byte
  # sniff and for Probe.probe/2 to read dimensions off.
  @jpeg <<255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 255, 192, 0,
          11, 8, 0, 1, 0, 1, 1, 1, 17, 0, 255, 217>>

  @svg "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"/>"

  setup do
    # The flat `/media` routes carry no tenancy slugs, so AssignDefaultScope
    # pins the read to the seeded DEFAULT workspace/project. The uploaded row
    # must live there or every serve GET 404s (media fixtures need dataset_id).
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    %{ws: ws, project: project}
  end

  # A real on-disk temp file wrapped as a Plug.Upload. `content_type` is the
  # CLIENT'S CLAIM and is deliberately allowed to lie — nothing in the ingest
  # path may read it.
  defp upload_bytes(ctx, filename, bytes, claimed_type \\ "application/octet-stream") do
    tmp =
      Path.join(System.tmp_dir!(), "sniff-#{System.unique_integer([:positive])}-#{filename}")

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)

    plug_upload = %Plug.Upload{path: tmp, filename: filename, content_type: claimed_type}

    {:ok, file} =
      Media.upload(plug_upload, "production",
        workspace_id: ctx.ws.id,
        project_id: ctx.project.id
      )

    on_exit(fn -> _ = Blobstore.delete(file.path) end)

    file
  end

  defp served_content_type(file) do
    conn = scoped_conn() |> get("/media/files/#{file.path}")
    assert conn.status == 200, "serve GET for #{file.path} answered #{conn.status}"
    conn |> get_resp_header("content-type") |> List.first() |> to_string()
  end

  describe "extensionless real image bytes (finding #4 — Gyldendal's remote.axd)" do
    test "`remote.axd` carrying real PNG bytes is stored AND served as image/png", ctx do
      file = upload_bytes(ctx, "remote.axd", @png)

      # THE RESPONSE HEADER IS THE ASSERTION (criterion 5). An upload that
      # answers 200 while serving octet-stream is exactly the bug, so the
      # header is checked BEFORE the persisted column — disarming the sniff
      # must RED naming the served content type, not an exit code.
      served = served_content_type(file)

      assert served =~ "image/png",
             "the SERVED content-type header for real PNG bytes was #{inspect(served)}"

      assert file.mime_type == "image/png",
             "ingest persisted #{inspect(file.mime_type)} for real PNG bytes"
    end

    test "a filename with NO extension at all carrying real PNG bytes serves image/png", ctx do
      file = upload_bytes(ctx, "remote", @png)

      served = served_content_type(file)

      assert served =~ "image/png",
             "the SERVED content-type header for real PNG bytes was #{inspect(served)}"

      assert file.mime_type == "image/png"
    end

    test "`remote.axd` carrying real JPEG bytes serves image/jpeg", ctx do
      file = upload_bytes(ctx, "remote.axd", @jpeg)

      served = served_content_type(file)

      assert served =~ "image/jpeg",
             "the SERVED content-type header for real JPEG bytes was #{inspect(served)}"

      assert file.mime_type == "image/jpeg"
    end

    test "the extension is still the FALLBACK when the bytes are unrecognised", ctx do
      # No magic match — `MIME.from_path/1` still decides, exactly as before.
      file = upload_bytes(ctx, "notes.txt", "just some prose, no magic number here")

      assert file.mime_type == "text/plain"
      assert served_content_type(file) =~ "text/plain"
    end

    test "unrecognised bytes AND no extension stay application/octet-stream", ctx do
      file = upload_bytes(ctx, "mystery", "no magic number here either")

      assert file.mime_type == "application/octet-stream"
      assert served_content_type(file) =~ "application/octet-stream"
    end
  end

  describe "negative arm — the stored-XSS defences both still hold" do
    test "a LYING client content_type cannot set the persisted mime", ctx do
      # Real PNG bytes, client swears it is HTML. The sniff reads the bytes;
      # the header is never consulted.
      file = upload_bytes(ctx, "remote.axd", @png, "text/html")

      served = served_content_type(file)

      assert served =~ "image/png",
             "the SERVED content-type header was #{inspect(served)}"

      assert file.mime_type == "image/png"
      refute file.mime_type == "text/html"
    end

    test "a lying content_type on unrecognised bytes cannot set the mime either", ctx do
      file = upload_bytes(ctx, "mystery", "not html at all", "text/html")

      assert file.mime_type == "application/octet-stream"
      refute file.mime_type == "text/html"
    end

    test "extensionless SVG bytes are neutralized at write, not stored as image/svg+xml", ctx do
      file = upload_bytes(ctx, "remote.axd", @svg)

      # Sniffed image/svg+xml → neutralize_dangerous_mime → octet-stream.
      assert file.mime_type == "application/octet-stream"
      refute file.mime_type == "image/svg+xml"
    end

    test "SVG bytes wearing a .png name are caught by the sniff and neutralized", ctx do
      # STRICTLY STRONGER than main: the extension-only ingest persisted
      # `image/png` here and never noticed the payload.
      file = upload_bytes(ctx, "pixel.png", @svg)

      assert file.mime_type == "application/octet-stream"
    end

    test "the dangerous family still collapses at the SERVE edge", ctx do
      # An honestly-named .svg: the write-side neutralizer already downgrades
      # it, and the serve edge collapses the dangerous family a second time.
      file = upload_bytes(ctx, "logo.svg", @svg)

      assert file.mime_type == "application/octet-stream"

      conn = scoped_conn() |> get("/media/files/#{file.path}")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/octet-stream"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment"
    end

    test "a row whose stored mime is dangerous is STILL collapsed on serve", ctx do
      # Belt-and-braces: hand-write a hostile mime straight into the row,
      # bypassing the changeset neutralizer, and prove the serve edge alone
      # refuses to echo it. This is the arm that keeps
      # `MediaFile.serve_content_type/1` load-bearing at the read seam now that
      # the read trusts the STORED value.
      file = upload_bytes(ctx, "remote.axd", @png)

      {1, _} =
        Repo.update_all(
          from(m in Barkpark.Media.Storage.MediaFile, where: m.id == ^file.id),
          set: [mime_type: "text/html"]
        )

      conn = scoped_conn() |> get("/media/files/#{file.path}")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/octet-stream"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
