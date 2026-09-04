defmodule BarkparkWeb.SharedMediaTest do
  @moduledoc """
  P3 — the share-aware scoped MEDIA surface:

    * `GET /w/:ws/p/:project/media`              (list)
    * `GET /w/:ws/p/:project/media/:id/meta`     (one asset's metadata)
    * `GET /w/:ws/p/:project/media/files/*path`  (serve the bytes)

  SECURITY CONTRACT: a `:media` share opens ONLY the read-only media surface of
  its OWN scope. The MediaController is scope-aware (every read takes the
  resolved workspace scope), so a share can never reach another workspace's
  media — a path that resolves to a different workspace 404s. Writes
  (upload/delete) and the UNSCOPED rendition route are not mounted on the share
  pipeline. Per-asset `bp_visibility` still applies on serve.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Media, Sharing}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  import Barkpark.TenancyFixtures

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("media-share-a")
    proj_a = create_project!(ws_a, "media-share-pa")
    ws_b = create_workspace!("media-share-b")
    proj_b = create_project!(ws_b, "media-share-pb")

    # A real on-disk file per workspace, with a matching scoped MediaFile row.
    file_a = put_media!("a", @dataset, ws_a, proj_a, "BYTES-FROM-A")
    file_b = put_media!("b", @dataset, ws_b, proj_b, "BYTES-FROM-B")

    {:ok,
     conn: conn,
     ws_a: ws_a,
     proj_a: proj_a,
     ws_b: ws_b,
     proj_b: proj_b,
     file_a: file_a,
     file_b: file_b}
  end

  # ── fixtures ────────────────────────────────────────────────────────────
  defp put_media!(tag, dataset, ws, project, bytes) do
    name = "#{tag}-#{System.unique_integer([:positive])}.png"
    rel = "uploads/shared-media-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: byte_size(bytes),
      dataset: dataset,
      workspace_id: ws.id,
      project_id: project.id
    })
    |> Repo.insert!()
  end

  defp media_root(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/media"
  defp serve_path(ws, project, file), do: "#{media_root(ws, project)}/files/#{file.path}"
  defp meta_path(ws, project, file), do: "#{media_root(ws, project)}/#{file.id}/meta"

  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  defp share(ws, project, surface), do: "#{ws.slug}/#{project.slug}/#{@dataset}:#{surface}:read"

  # ── (a) :media share — anonymous list is public + scope-isolated ──────────
  describe "(a) :media shared scope — anonymous list" do
    test "lists ONLY this scope's files (never another workspace's)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a,
      file_b: file_b
    } do
      with_shares(share(ws_a, proj_a, :media))

      body =
        conn
        |> get(media_root(ws_a, proj_a))
        |> json_response(200)

      ids = body["files"] |> Enum.map(& &1["id"])
      assert file_a.id in ids
      refute file_b.id in ids
    end

    test "anonymous GET /:id/meta returns this scope's file", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      with_shares(share(ws_a, proj_a, :media))

      body = conn |> get(meta_path(ws_a, proj_a, file_a)) |> json_response(200)
      assert body["id"] == file_a.id
    end
  end

  # ── (b) serve the bytes ───────────────────────────────────────────────────
  describe "(b) :media shared scope — anonymous serve" do
    test "serves the file bytes of a public-visibility asset", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      with_shares(share(ws_a, proj_a, :media))

      conn = get(conn, serve_path(ws_a, proj_a, file_a))
      assert conn.status == 200
      assert conn.resp_body == "BYTES-FROM-A"
    end
  end

  # ── (c) CROSS-WORKSPACE — a share can never reach another scope's bytes ────
  describe "(c) cross-workspace isolation" do
    test "A's :media share serving B's file PATH (under A's scope) 404s", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_b: file_b
    } do
      with_shares(share(ws_a, proj_a, :media))

      # B's real path, requested under A's shared scope: get_file_by_path is
      # scoped to A, so B's row is not found -> 404 (B's bytes never served).
      conn = get(conn, "#{media_root(ws_a, proj_a)}/files/#{file_b.path}")
      assert conn.status == 404
      refute conn.resp_body =~ "BYTES-FROM-B"
    end
  end

  # ── (c2) PATH TRAVERSAL — a `../` serve path can never escape the upload root
  # (sobelow Traversal.SendFile, media_controller.ex `serve/2`). The serve edge
  # resolves the file by a validated key: `get_file_by_path/2` matches on exact
  # `path` equality, and stored paths are server-generated (`unique_filename/1`
  # strips directory parts), so a `../…` glob matches no row → 404 and the disk
  # path is derived from the RECORD's `file.path`, never the raw URL segment.
  describe "(c2) path traversal is rejected" do
    test "a `../` serve path escaping the upload root 404s and never serves the file",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      with_shares(share(ws_a, proj_a, :media))

      # Plant a secret OUTSIDE the upload root, at the location a naive
      # `file_path(raw_relative)` would resolve `../<name>` to.
      secret_name = "traversal-secret-#{System.unique_integer([:positive])}.txt"
      escaped = Media.file_path("../" <> secret_name)
      File.write!(escaped, "TOP-SECRET-OUTSIDE-ROOT")
      on_exit(fn -> File.rm_rf(escaped) end)

      conn = get(conn, "#{media_root(ws_a, proj_a)}/files/../#{secret_name}")

      assert conn.status == 404
      refute conn.resp_body =~ "TOP-SECRET-OUTSIDE-ROOT"
    end
  end

  # ── (d) non-shared scope stays gated ──────────────────────────────────────
  describe "(d) non-shared scope" do
    test "no share -> anonymous media list is gated", %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      Application.delete_env(:barkpark, :shares)

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end

    test "sharing a DIFFERENT scope does not open THIS scope's media", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares("some-other-ws/some-other-proj/#{@dataset}:media:read")

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end
  end

  # ── (e) surface-exact — :docs / :papers do NOT open :media ────────────────
  describe "(e) surface-exact" do
    test "a :docs share on this scope leaves media gated", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares(share(ws_a, proj_a, :docs))

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :docs)
      refute Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :media)

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end

    test "a :papers share on this scope leaves media gated", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares(share(ws_a, proj_a, :papers))

      conn = get(conn, media_root(ws_a, proj_a))
      assert conn.status in [401, 403, 404]
    end
  end

  # ── (h) RUNTIME MEDIA DIR (pds W1 G1) — Media.upload_dir reads at CALL time ──
  # `BARKPARK_MEDIA_DIR` (runtime.exs) sets :media_upload_dir; `Media.upload_dir/0`
  # and `file_path/1` read it at call time so a `barkpark reload` relocates the
  # blob root without a recompile. Unset ⇒ the config default, byte-identical.
  describe "(h) media_upload_dir runtime override" do
    test "upload_dir/0 reflects the app-env value and defaults byte-identically" do
      prior = Application.get_env(:barkpark, :media_upload_dir)

      on_exit(fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :media_upload_dir),
          else: Application.put_env(:barkpark, :media_upload_dir, prior)
      end)

      # Default (unset override) is exactly the configured value — byte-identical.
      assert Media.upload_dir() == prior
      assert Media.file_path("a/b.png") == Path.join(prior, "a/b.png")

      # A runtime relocation (what BARKPARK_MEDIA_DIR drives via runtime.exs) is
      # honored on the very next call — no recompile.
      relocated = Path.join(System.tmp_dir!(), "bp-media-#{System.unique_integer([:positive])}")
      Application.put_env(:barkpark, :media_upload_dir, relocated)
      assert Media.upload_dir() == relocated
      assert Media.file_path("a/b.png") == Path.join(relocated, "a/b.png")
    end
  end

  # ── (f) MISSING-BLOB HONESTY (pds W1) — a row whose blob file is gone 404s ──
  # A media_files ROW can outlive its blob: right after a workspace bundle import
  # copies the DB rows but before the blobs are pushed, `serve/2` resolves the
  # row yet the file is absent. It must answer an HONEST 404, never crash with a
  # MatchError :enoent 500 out of send_file.
  describe "(f) missing blob file" do
    test "serving a row whose blob file does not exist returns 404, not a 500", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      with_shares(share(ws_a, proj_a, :media))

      # A scoped row pointing at a path with NO file on disk (import copied the
      # row, blob not yet re-pointed).
      name = "ghost-#{System.unique_integer([:positive])}.png"
      rel = "uploads/shared-media-test/#{name}"
      refute File.exists?(Media.file_path(rel))

      row =
        %MediaFile{}
        |> MediaFile.changeset(%{
          filename: name,
          original_name: name,
          path: rel,
          mime_type: "image/png",
          size: 123,
          dataset: @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        })
        |> Repo.insert!()

      conn = get(conn, serve_path(ws_a, proj_a, row))
      assert conn.status == 404
    end
  end

  # ── (g) BLOB PUSH (pds W1 G2) — admin-gated cross-instance raw-blob write ────
  # PUT /api/workspaces/:ws/media/blob/*path writes bytes verbatim at a validated
  # relative path so an imported row's blob can be re-pointed onto THIS instance.
  # Admin-gated; traversal / malformed paths are refused 422 before any write.
  describe "(g) admin blob push" do
    @admin_token "pds-w1-blob-admin-token"

    setup %{ws_a: ws_a} do
      # Bound to ws_a: `create_token/5` mints the token AND its ws_a membership
      # in one transaction. `:workspace_slug` is binding on this route now, so a
      # token with the global `admin` permission and no membership in the
      # workspace it names is refused — see describe "(h)".
      Auth.create_token(
        @admin_token,
        "dev",
        "pds-w1-blob-push",
        ["read", "write", "admin"],
        ws_a.id
      )

      :ok
    end

    defp admin_put_blob(conn, ws, rel, body) do
      conn
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> put_req_header("content-type", "application/octet-stream")
      |> put("/api/workspaces/#{ws.slug}/media/blob/#{rel}", body)
    end

    test "admin PUT writes the bytes verbatim and serve/2 can then read them", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      name = "pushed-#{System.unique_integer([:positive])}.png"
      rel = "uploads/shared-media-test/#{name}"
      full = Media.file_path(rel)
      on_exit(fn -> File.rm_rf(full) end)
      refute File.exists?(full)

      body = "PUSHED-BLOB-BYTES"
      resp = admin_put_blob(conn, ws_a, rel, body) |> json_response(200)
      assert resp["written"] == rel
      assert resp["path"] == rel, "`path` is the honest name for the legacy `written` key"
      assert resp["bytes"] == byte_size(body)

      # PDS wave 23: RECEIVED and STORED are separate numbers on the wire, and
      # `stored` names the read that produced it. Under :local the disk IS the
      # store, so the post-condition read is a File.stat on the real path.
      assert resp["stored"] == byte_size(body)
      assert resp["verified_by"] == "stat"
      assert resp["unverified_reason"] == nil

      # Bytes landed verbatim on disk.
      assert File.read!(full) == body

      # And a scoped row over that path now serves the pushed bytes.
      with_shares(share(ws_a, proj_a, :media))

      row =
        %MediaFile{}
        |> MediaFile.changeset(%{
          filename: name,
          original_name: name,
          path: rel,
          mime_type: "image/png",
          size: byte_size(body),
          dataset: @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        })
        |> Repo.insert!()

      served = scoped_conn() |> get(serve_path(ws_a, proj_a, row))
      assert served.status == 200
      assert served.resp_body == body
    end

    # PDS wave 23, reviewer addition. The engine-level proof that a black-hole
    # bucket is caught lives in blobstore_s3_test.exs; this is the HTTP surface
    # of that verdict — the 502 envelope was previously read, never rendered.
    test "a store that ACKs and keeps nothing is a 502 blob_not_stored, never a 200", %{
      conn: conn,
      ws_a: ws_a
    } do
      previous = Application.get_env(:barkpark, :media_storage)
      on_exit(fn -> Application.put_env(:barkpark, :media_storage, previous) end)

      # The bucket answers 200 to every PUT and 404 to every HEAD: the write ACK
      # says yes, the post-condition read says the object is not there.
      Req.Test.stub(__MODULE__, fn c ->
        case c.method do
          "PUT" -> Plug.Conn.send_resp(c, 200, "")
          _ -> Plug.Conn.send_resp(c, 404, "")
        end
      end)

      Application.put_env(:barkpark, :media_storage,
        backend: :s3,
        s3: [
          endpoint: "https://test.r2.example.com",
          bucket: "bp-shared-media-test",
          region: "auto",
          access_key_id: "test-access-key",
          secret_access_key: "test-secret-key",
          req_options: [plug: {Req.Test, __MODULE__}]
        ]
      )

      rel = "uploads/shared-media-test/blackhole-#{System.unique_integer([:positive])}.png"
      resp = admin_put_blob(conn, ws_a, rel, "PUSHED-BLOB-BYTES") |> json_response(502)

      assert resp["error"]["code"] == "blob_not_stored"
      assert resp["error"]["message"] =~ "read-back"
      # The envelope is stamped like every other error on this surface.
      assert is_binary(resp["error"]["request_id"])
    end

    test "a traversal path is rejected 422 and nothing is written", %{conn: conn, ws_a: ws_a} do
      # A secret OUTSIDE the media root that a naive write would clobber.
      secret = Media.file_path("../pds-blob-escape-#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm_rf(secret) end)

      resp =
        admin_put_blob(conn, ws_a, "../#{Path.basename(secret)}", "EVIL") |> json_response(422)

      assert resp["error"]["code"] == "invalid_path"
      refute File.exists?(secret)
    end

    test "a malformed segment is rejected 422", %{conn: conn, ws_a: ws_a} do
      resp =
        admin_put_blob(conn, ws_a, "uploads/2026/.hidden/x.png", "X") |> json_response(422)

      assert resp["error"]["code"] == "invalid_path"
    end

    test "an empty body is rejected 422 empty_body and nothing is written", %{
      conn: conn,
      ws_a: ws_a
    } do
      rel = "uploads/shared-media-test/empty-#{System.unique_integer([:positive])}.png"

      resp = admin_put_blob(conn, ws_a, rel, "") |> json_response(422)
      assert resp["error"]["code"] == "empty_body"
      refute File.exists?(Media.file_path(rel))
    end

    test "a mislabeled content-type (json) whose body Plug.Parsers consumed is refused, never a 0-byte blob",
         %{conn: conn, ws_a: ws_a} do
      # `application/json` routes the body through Plug.Parsers, which consumes
      # it before the controller's read_body — the raw body arrives EMPTY. The
      # guard refuses instead of writing an empty blob serve/2 would stream.
      rel = "uploads/shared-media-test/mislabeled-#{System.unique_integer([:positive])}.png"

      resp =
        conn
        |> put_req_header("authorization", "Bearer " <> @admin_token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/workspaces/#{ws_a.slug}/media/blob/#{rel}", Jason.encode!(%{not: "bytes"}))
        |> json_response(422)

      assert resp["error"]["code"] == "empty_body"
      refute File.exists?(Media.file_path(rel))
    end

    test "anonymous PUT is gated (no admin token)", %{conn: conn, ws_a: ws_a} do
      resp =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put("/api/workspaces/#{ws_a.slug}/media/blob/uploads/x/y.png", "X")

      assert resp.status in [401, 403]
    end
  end

  # ── (h) BLOB PUSH TENANCY — the URL workspace is BINDING, not decoration ─────
  # `PUT /api/workspaces/:workspace_slug/media/blob/*path` used to drop
  # `workspace_slug` on the floor (media_controller `put_blob(conn, %{"path" =>
  # path_parts})`) and write into a FLAT, instance-global keyspace
  # (`Media.put_blob/2` → `Blobstore.put_bytes(relative_path, body, [])`). Two
  # independent defects rode that: the caller was never bound to the workspace
  # it named, and the stored key carried no tenant, so ANY token holding the
  # workspace-blind `admin` permission could overwrite ANY tenant's bytes.
  #
  # Both arms below are the SAME primitive from two angles, and neither alone
  # is sufficient — binding the caller still leaves a flat keyspace in which a
  # legitimate member of B writes over A's object.
  describe "(h) blob push is bound to the URL workspace" do
    @outsider_admin_token "blob-tenancy-outsider-admin"
    @b_admin_token "blob-tenancy-b-admin"

    setup %{ws_b: ws_b} do
      # A GLOBAL-admin token that is a member of a THIRD workspace — it clears
      # `:require_admin` (Auth.has_permission?(token, "admin")) and has no
      # membership whatsoever in ws_a or ws_b.
      outsider_ws = create_workspace!("media-share-outsider")

      {:ok, _} =
        Auth.create_token(
          @outsider_admin_token,
          "dev",
          "blob-tenancy",
          ["read", "write", "admin"],
          outsider_ws.id
        )

      # A GLOBAL-admin token that IS a legitimate member of ws_b. Nothing about
      # this principal is illegitimate — it is an admin of the workspace it
      # names in the URL. It must still not be able to reach ws_a's bytes.
      {:ok, _} =
        Auth.create_token(
          @b_admin_token,
          "dev",
          "blob-tenancy",
          ["read", "write", "admin"],
          ws_b.id
        )

      {:ok, outsider_ws: outsider_ws}
    end

    defp put_blob_as(conn, token, ws, rel, body) do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/octet-stream")
      |> put("/api/workspaces/#{ws.slug}/media/blob/#{rel}", body)
    end

    # (a) AUTHORIZE. The slug in the URL must bind the caller.
    test "a global-admin token with NO membership in the named workspace cannot write into it",
         %{conn: conn, ws_b: ws_b} do
      rel = "uploads/shared-media-test/outsider-#{System.unique_integer([:positive])}.png"
      full = Media.file_path(rel)
      on_exit(fn -> File.rm_rf(full) end)

      resp = put_blob_as(conn, @outsider_admin_token, ws_b, rel, "OUTSIDER-BYTES")

      # Non-member and unknown-slug collapse to 404 — the no-existence-leak
      # convention this controller family already uses (workspace_controller
      # `projects`/`create_project`/`datasets`).
      assert resp.status == 404,
             "a non-member global-admin wrote into #{ws_b.slug} (status #{resp.status})"

      refute File.exists?(full),
             "the refused write still put bytes on disk at #{rel}"
    end

    # (b) NAMESPACE. Binding the caller is NOT enough: ws_b's own admin, naming
    # ws_b in the URL, must not be able to address a key ws_a owns.
    test "a legitimate ws_b admin cannot overwrite a blob ws_a owns", %{
      conn: conn,
      ws_b: ws_b,
      file_a: file_a
    } do
      full_a = Media.file_path(file_a.path)
      assert File.read!(full_a) == "BYTES-FROM-A", "fixture precondition"

      resp = put_blob_as(conn, @b_admin_token, ws_b, file_a.path, "CLOBBERED-BY-B")

      # The HARM first: whatever the status, ws_a's object must be untouched.
      assert File.read!(full_a) == "BYTES-FROM-A",
             "ws_a's bytes were replaced by a write issued under ws_b's slug " <>
               "(status #{resp.status})"

      assert resp.status in [403, 404],
             "ws_b's admin addressed ws_a's blob key and got #{resp.status}"
    end

    # (c) The LEGITIMATE arm, end to end: an admin of the workspace writes a key
    # that workspace owns, gets 200, and the EXISTING serve path reads the new
    # bytes back. Read and write must agree on the namespace.
    test "an admin of the workspace writes its own blob 200 and serve/2 reads it back", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      {:ok, _} =
        Auth.create_token(
          "blob-tenancy-a-admin",
          "dev",
          "blob-tenancy",
          ["read", "write", "admin"],
          ws_a.id
        )

      body = "RE-POINTED-BYTES-FOR-A"
      resp = put_blob_as(conn, "blob-tenancy-a-admin", ws_a, file_a.path, body)
      assert resp.status == 200, "own-workspace admin write was refused (#{resp.status})"
      assert json_response(resp, 200)["path"] == file_a.path

      # Read-back through the EXISTING GET blob path, not a File.read.
      with_shares(share(ws_a, proj_a, :media))
      served = scoped_conn() |> get(serve_path(ws_a, proj_a, file_a))
      assert served.status == 200
      assert served.resp_body == body
    end

    test "a token without the admin permission is 403", %{conn: conn, ws_a: ws_a} do
      {:ok, _} =
        Auth.create_token(
          "blob-tenancy-a-writer",
          "dev",
          "blob-tenancy",
          ["read", "write"],
          ws_a.id
        )

      rel = "uploads/shared-media-test/nonadmin-#{System.unique_integer([:positive])}.png"
      resp = put_blob_as(conn, "blob-tenancy-a-writer", ws_a, rel, "X")
      assert resp.status == 403
      refute File.exists?(Media.file_path(rel))
    end

    # The context seam fails CLOSED on omission, not open. A future caller that
    # forgets to thread a workspace must be refused, never handed the old
    # instance-global write back by default.
    test "Media.put_blob/3 without a :workspace_id is refused, not treated as unscoped" do
      rel = "uploads/shared-media-test/unscoped-#{System.unique_integer([:positive])}.png"

      assert {:error, :unscoped_blob_write} = Media.put_blob(rel, "X")
      assert {:error, :unscoped_blob_write} = Media.put_blob(rel, "X", workspace_id: nil)
      refute File.exists?(Media.file_path(rel))
    end

    test "an unauthenticated PUT is 401", %{conn: conn, ws_a: ws_a} do
      rel = "uploads/shared-media-test/anon-#{System.unique_integer([:positive])}.png"

      resp =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put("/api/workspaces/#{ws_a.slug}/media/blob/#{rel}", "X")

      assert resp.status == 401
      refute File.exists?(Media.file_path(rel))
    end
  end
end
