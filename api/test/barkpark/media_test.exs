defmodule Barkpark.MediaTest do
  @moduledoc """
  Covers the public API of `Barkpark.Media` — the context module for media file
  storage and retrieval.

  Focus areas:
    * `upload_dir/0` — returns the configured path string.
    * `file_path/1` — joins upload_dir + relative_path.
    * `get_file/2` — happy path, :not_found, workspace isolation.
    * `get_file_by_path/2` — happy path, :not_found, workspace isolation.
    * `delete_file/2` — happy path deletes DB row, :not_found guard, workspace
      isolation (cross-workspace delete returns :not_found).
    * `list_files/2` — bounded by `:limit` (default + clamp 10_000; never
      honoured verbatim above that).
    * `query_files/2` — returns {files, total_count}.
    * `search_files/2` — returns {files, total, facets, meta}.

  The `upload/3` function requires real `Plug.Upload` + disk I/O + plugin
  hooks — it is exercised through the controller integration tests; this file
  stays at the context boundary.

  `async: false` — REQUIRED, not incidental. The upload-validation tests below
  drive `put_media_cfg/1`, which does `Application.put_env(:barkpark,
  :media_uploads, …)`. Application env is PROCESS-GLOBAL VM state; the SQL
  sandbox isolates the DB, NOT the env. `Barkpark.Media.validate_upload/3` reads
  that same key at runtime (`Application.get_env/3`), so a concurrent async test
  calling `Media.upload/3` would observe this module's mutation — and race its
  `on_exit` restore (the exact order-dependent flake shape of the solved
  sandbox-ownership scar). Today the only other reader lives in an async:false
  module (`v1_media_test.exs`), so the leak is latent — but relying on "no other
  async reader exists yet" is a landmine, not isolation. Serial execution is the
  real fix; the parallelism we trade is worth the correctness (matches the
  suite's convention — every dedicated global-state test is already async:false).
  DB writes remain row-level and workspace fixtures use unique slugs from
  `System.unique_integer/1` to avoid collisions.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @upload_dir Application.compile_env!(:barkpark, :media_upload_dir)
  @dataset "test-media-ctx"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_file!(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    base =
      %{
        filename: "ctx-#{suffix}.png",
        original_name: "original-#{suffix}.png",
        path: "test/ctx/#{suffix}.png",
        mime_type: "image/png",
        size: 42,
        dataset: @dataset
      }

    %MediaFile{}
    |> MediaFile.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  # A real on-disk temp file wrapped as a Plug.Upload (content_type defaults to a
  # generic value — the point of the fix is that it is NOT trusted).
  defp temp_upload(filename, content) do
    tmp = Path.join(System.tmp_dir!(), "mt-#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, content)
    %Plug.Upload{path: tmp, filename: filename, content_type: "application/octet-stream"}
  end

  # Bulk-seed `media_files` rows straight through `insert_all` — mirrors
  # `content/query_collect_all_documents_test.exs`'s convention for pinning a
  # clamp without N real create round-trips. Chunked at 500 rows/statement so
  # a @max_limit-sized seed (10_001 rows × 9 columns) never approaches
  # Postgres's ~65_535 bound-parameter ceiling per statement.
  defp seed_many!(n, dataset) do
    now = DateTime.utc_now()

    1..n
    |> Enum.map(fn i ->
      suffix = "#{System.unique_integer([:positive])}-#{i}"

      %{
        id: Ecto.UUID.generate(),
        filename: "bulk-#{suffix}.png",
        original_name: "bulk-original-#{suffix}.png",
        path: "test/bulk/#{suffix}.png",
        mime_type: "image/png",
        size: 1,
        dataset: dataset,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk -> {_count, nil} = Repo.insert_all(MediaFile, chunk) end)

    :ok
  end

  # Override :media_uploads config for one test, restoring the prior value after.
  defp put_media_cfg(cfg) do
    prev = Application.get_env(:barkpark, :media_uploads)
    Application.put_env(:barkpark, :media_uploads, cfg)

    on_exit(fn ->
      if prev do
        Application.put_env(:barkpark, :media_uploads, prev)
      else
        Application.delete_env(:barkpark, :media_uploads)
      end
    end)
  end

  # Deterministic "was any blob persisted?" probe: scan the upload tree for a file
  # carrying the upload's unique marker bytes. False proves validate-before-persist
  # (no blob written on a rejected upload). Race-free because the marker is unique.
  defp blob_written?(marker) do
    @upload_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(fn p ->
      case File.read(p) do
        {:ok, bytes} -> String.contains?(bytes, marker)
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # upload_dir/0 — pure config read
  # ---------------------------------------------------------------------------

  describe "upload_dir/0" do
    test "returns the configured upload directory string" do
      assert is_binary(Media.upload_dir())
      assert Media.upload_dir() == @upload_dir
    end
  end

  # ---------------------------------------------------------------------------
  # file_path/1 — path join
  # ---------------------------------------------------------------------------

  describe "file_path/1" do
    test "joins the upload_dir and the relative path" do
      relative = "2026/06/somefile.png"
      expected = Path.join(@upload_dir, relative)
      assert Media.file_path(relative) == expected
    end

    test "works for a nested path" do
      relative = "a/b/c/d.jpg"
      assert Media.file_path(relative) == Path.join(@upload_dir, relative)
    end
  end

  # ---------------------------------------------------------------------------
  # valid_blob_path?/1 + the Blobstore read/serve seam traversal guard
  # (felix-w24-bl-blobstore-runtime-guard — scar-class defence-in-depth)
  #
  # `media_files.path` is typed server-generated + "never raw client input", but
  # a workspace bundle import COPYs rows past the changeset (Blobstore.Local PATH
  # PROVENANCE clause 2), so an admin bundle CAN plant `../../..`. The write-seam
  # allowlist `Media.valid_blob_path?/1` is now enforced at the Blobstore
  # dispatch verbs (`serve_strategy`/`ensure_local`/`delete`), so a traversal
  # `file.path` fails closed BEFORE `send_file`/`File.rm`.
  #
  # MUTATION PROOF: `delete/1 skips File.rm` deletes an EXTERNAL sentinel iff the
  # guard is removed — flip `safe_blob_path?/1` to always-true and it reds.
  # ---------------------------------------------------------------------------

  describe "valid_blob_path?/1" do
    test "accepts a server-generated blob path" do
      assert Media.valid_blob_path?("2026/06/photo-a1b2c3d4.png")
    end

    test "rejects traversal, absolute, empty, and non-binary shapes" do
      refute Media.valid_blob_path?("../../../etc/passwd")
      refute Media.valid_blob_path?("2026/../../secret")
      refute Media.valid_blob_path?("/etc/passwd")
      refute Media.valid_blob_path?("")
      refute Media.valid_blob_path?(nil)
    end

    # unique_filename/1 emits `-<hex>.ext` when the client basename slugs to
    # empty (CJK/emoji/space-only names) — those blobs are legitimately stored,
    # so the read/serve guard must accept them or serving them regresses to 404.
    test "accepts the leading-dash filename unique_filename emits for empty slugs" do
      assert Media.valid_blob_path?("2026/08/-a1b2c3d4.png")
    end

    test "still rejects leading-dot and leading-underscore segments" do
      refute Media.valid_blob_path?("2026/08/.hidden")
      refute Media.valid_blob_path?("_renditions/abc/file.png")
    end
  end

  describe "Blobstore read/serve seam traversal guard" do
    test "serve_strategy rejects a traversal path with the missing-blob shape" do
      assert Blobstore.serve_strategy("../../../etc/passwd") == {:error, :not_found}
    end

    test "ensure_local rejects a traversal path with the missing-blob shape" do
      assert Blobstore.ensure_local("../../../etc/passwd") == {:error, :not_found}
    end

    test "delete skips File.rm for a traversal path (mutation: reds if the guard is removed)" do
      # A sentinel OUTSIDE the media root. The relative path from upload_dir to it
      # is `../…` — the exact bundle-planted traversal shape. With the guard,
      # Blobstore.delete never resolves it to File.rm, so the sentinel survives;
      # remove the guard and File.rm(Path.join(upload_dir, "../…")) deletes it.
      # A single-level `..` escape out of the media root — the exact
      # bundle-planted shape. Its resolved location sits beside upload_dir.
      traversal_rel = "../felix-blob-sentinel-#{System.unique_integer([:positive])}"
      sentinel = Path.expand(Media.file_path(traversal_rel))
      File.write!(sentinel, "do not delete me")
      on_exit(fn -> File.rm(sentinel) end)

      # Sanity: it is genuinely a traversal shape that resolves OUTSIDE the root,
      # so the mutation (guard removed → File.rm) would truly delete it.
      assert String.starts_with?(traversal_rel, "..")
      refute String.starts_with?(sentinel, Path.expand(@upload_dir) <> "/")

      assert Blobstore.delete(traversal_rel) == :ok
      assert File.exists?(sentinel), "guard must reject the traversal path before File.rm"
    end
  end

  # ---------------------------------------------------------------------------
  # get_file/2 — by id
  # ---------------------------------------------------------------------------

  describe "get_file/2" do
    test "returns {:ok, file} for an existing id" do
      file = insert_file!()
      assert {:ok, fetched} = Media.get_file(file.id)
      assert fetched.id == file.id
      assert fetched.filename == file.filename
    end

    test "returns {:error, :not_found} for a random id" do
      missing_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Media.get_file(missing_id)
    end

    test "a malformed (non-UUID) id is {:error, :not_found}, not an Ecto CastError" do
      # id is :binary_id; before the UUID-cast guard a non-UUID crashed the query
      # (500 at every /v1/media/:ds/:id endpoint). Now it's a clean not_found.
      assert {:error, :not_found} = Media.get_file("not-a-uuid")
      assert {:error, :not_found} = Media.get_file("garbage", workspace_id: Ecto.UUID.generate())
    end

    test "unscoped get returns a workspace-stamped file" do
      ws = create_workspace!()
      proj = create_project!(ws)
      file = insert_file!(%{workspace_id: ws.id, project_id: proj.id})

      assert {:ok, fetched} = Media.get_file(file.id)
      assert fetched.id == file.id
    end

    test "workspace-scoped get returns {:ok, file} when scope matches" do
      ws = create_workspace!()
      proj = create_project!(ws)
      file = insert_file!(%{workspace_id: ws.id, project_id: proj.id})

      assert {:ok, fetched} = Media.get_file(file.id, workspace_id: ws.id)
      assert fetched.id == file.id
    end

    test "workspace-scoped get returns {:error, :not_found} when scope is wrong workspace" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()

      file_a = insert_file!(%{workspace_id: ws_a.id, project_id: proj_a.id})

      assert {:error, :not_found} = Media.get_file(file_a.id, workspace_id: ws_b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_file_by_path/2 — by relative path
  # ---------------------------------------------------------------------------

  describe "get_file_by_path/2" do
    test "returns {:ok, file} for an existing path" do
      file = insert_file!()
      assert {:ok, fetched} = Media.get_file_by_path(file.path)
      assert fetched.id == file.id
    end

    test "returns {:error, :not_found} for an unknown path" do
      assert {:error, :not_found} = Media.get_file_by_path("nonexistent/ghost.png")
    end

    test "workspace-scoped lookup returns {:ok, file} when scope matches" do
      ws = create_workspace!()
      proj = create_project!(ws)
      file = insert_file!(%{workspace_id: ws.id, project_id: proj.id})

      assert {:ok, fetched} = Media.get_file_by_path(file.path, workspace_id: ws.id)
      assert fetched.id == file.id
    end

    test "workspace-scoped lookup returns :not_found for cross-workspace path" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()

      file_a = insert_file!(%{workspace_id: ws_a.id, project_id: proj_a.id})

      assert {:error, :not_found} =
               Media.get_file_by_path(file_a.path, workspace_id: ws_b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # list_files/2
  # ---------------------------------------------------------------------------

  describe "list_files/2" do
    test "returns files for the given dataset" do
      f1 = insert_file!()
      f2 = insert_file!()

      files = Media.list_files(@dataset)
      ids = Enum.map(files, & &1.id)

      assert f1.id in ids
      assert f2.id in ids
    end

    test "does not return files from another dataset" do
      other = insert_file!(%{dataset: "other-dataset-#{System.unique_integer([:positive])}"})

      files = Media.list_files(@dataset)
      ids = Enum.map(files, & &1.id)

      refute other.id in ids
    end

    test "returns empty list when no files exist for the dataset" do
      fresh = "fresh-ds-#{System.unique_integer([:positive])}"
      assert Media.list_files(fresh) == []
    end

    # THE DEFECT (task wb-api-media-list-files-limit): unpatched code does
    # `Keyword.delete(opts, :limit) |> Keyword.put(:limit, 10_000)` — it
    # explicitly discards the caller's `:limit` before substituting a fixed
    # 10_000. Seeded count (5) sits well under that 10_000, so unpatched code
    # returns all 5 here regardless of the `limit: 3` the caller asked for;
    # this assertion REDS on unpatched code and is GREEN once `:limit` is
    # threaded through.
    test "honours a caller-supplied :limit smaller than the seeded rows" do
      ds = "limit-honoured-#{System.unique_integer([:positive])}"
      seed_many!(5, ds)

      files = Media.list_files(ds, limit: 3)

      assert length(files) == 3
    end

    # THE CLAMP: a limit above @max_limit is capped, never honoured verbatim
    # and never an error. Mirrors
    # `content/query_collect_all_documents_test.exs`'s "the clamp is REAL"
    # shape — seed one row past the ceiling and prove the page stops short.
    test "a :limit above @max_limit is clamped, not honoured verbatim" do
      ds = "limit-clamped-#{System.unique_integer([:positive])}"
      seed_many!(10_001, ds)

      files = Media.list_files(ds, limit: 50_000)

      assert length(files) == 10_000
    end

    # DEFAULT PRESERVATION: no existing caller passes `:limit` (see the
    # `grep -rn 'list_files(' api/lib api/test` evidence on the task), so the
    # no-:limit ceiling must stay exactly what it was before this fix —
    # 10_000 — or every one of those callers changes behaviour silently.
    test "with no :limit supplied, the ceiling stays the historical 10_000" do
      ds = "limit-default-#{System.unique_integer([:positive])}"
      seed_many!(10_001, ds)

      files = Media.list_files(ds)

      assert length(files) == 10_000
    end
  end

  # ---------------------------------------------------------------------------
  # query_files/2
  # ---------------------------------------------------------------------------

  describe "query_files/2" do
    test "returns {files, total_count} tuple" do
      insert_file!()

      {files, total} = Media.query_files(@dataset)
      assert is_list(files)
      assert is_integer(total)
      assert total >= 1
    end

    test "total_count matches the number of files in the dataset" do
      # Insert two files and capture prior count to handle other parallel tests
      # using the same @dataset (async: true) — we verify +2 delta.
      {_, before_count} = Media.query_files(@dataset)
      insert_file!()
      insert_file!()
      {_, after_count} = Media.query_files(@dataset)
      assert after_count == before_count + 2
    end

    test "mime_type filter returns only matching files" do
      insert_file!(%{mime_type: "image/png"})
      insert_file!(%{mime_type: "image/png"})
      video = insert_file!(%{mime_type: "video/mp4"})

      {files, _} = Media.query_files(@dataset, mime_type: "video/")
      ids = Enum.map(files, & &1.id)

      assert video.id in ids
      # png files must not appear in the video-only filter
      Enum.each(files, fn f -> assert String.starts_with?(f.mime_type, "video/") end)
    end

    test "limit/offset controls page size" do
      # Make sure there are at least 3 rows
      Enum.each(1..3, fn _ -> insert_file!() end)

      {files, _total} = Media.query_files(@dataset, limit: 2, offset: 0)
      assert length(files) <= 2
    end

    test "returns empty list for an unknown dataset" do
      fresh = "empty-qs-#{System.unique_integer([:positive])}"
      {files, total} = Media.query_files(fresh)
      assert files == []
      assert total == 0
    end
  end

  # ---------------------------------------------------------------------------
  # search_files/2
  # ---------------------------------------------------------------------------

  describe "search_files/2" do
    test "returns a 4-tuple {files, total, facets, meta}" do
      insert_file!()
      result = Media.search_files(@dataset)
      assert {files, total, facets, meta} = result
      assert is_list(files)
      assert is_integer(total)
      assert is_map(facets)
      assert is_map(meta)
    end

    test "total in search_files is non-negative" do
      fresh = "sf-fresh-#{System.unique_integer([:positive])}"
      {_files, total, _facets, _meta} = Media.search_files(fresh)
      assert total >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # delete_file/2
  # ---------------------------------------------------------------------------

  describe "delete_file/2" do
    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Media.delete_file(Ecto.UUID.generate(), where_used: :cascade)
    end

    test "deletes the DB row and returns {:ok, file}" do
      file = insert_file!()

      # We need the file on disk (even empty) because delete_file calls File.rm
      full = Path.join(@upload_dir, file.path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "")

      assert {:ok, deleted} = Media.delete_file(file.id, where_used: :cascade)
      assert deleted.id == file.id

      # Verify the row is gone
      assert {:error, :not_found} = Media.get_file(file.id)
    end

    test "workspace-scoped delete returns :not_found for cross-workspace id" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()

      file_a = insert_file!(%{workspace_id: ws_a.id, project_id: proj_a.id})

      assert {:error, :not_found} = Media.delete_file(file_a.id, workspace_id: ws_b.id, where_used: :cascade)

      # The file must still exist — it was not deleted
      assert {:ok, _} = Media.get_file(file_a.id, workspace_id: ws_a.id)
    end

    test "a successful delete removes the DB row, the blob, and its renditions" do
      file = insert_file!()

      full = Path.join(@upload_dir, file.path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "")

      # A rendition lives under {upload_dir}/_renditions/{id}/ — seed one so we
      # can assert delete_file sweeps the cache dir on success.
      rendition_dir = Path.join([@upload_dir, "_renditions", file.id])
      File.mkdir_p!(rendition_dir)
      File.write!(Path.join(rendition_dir, "thumb.jpg"), "")

      assert {:ok, deleted} = Media.delete_file(file.id, where_used: :cascade)
      assert deleted.id == file.id

      assert {:error, :not_found} = Media.get_file(file.id)
      refute File.exists?(full)
      refute File.exists?(rendition_dir)
    end

    test "when the DB row is already gone the blob is left intact and no destructive side effect fires" do
      file = insert_file!()

      full = Path.join(@upload_dir, file.path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "keep-me")

      # The row is consumed out from under us (a concurrent DELETE winner). The
      # DB delete is the FIRST side effect, so a delete that cannot remove the
      # row must not touch the blob nor dispatch media.deleted.
      {1, _} = Repo.delete_all(from(m in MediaFile, where: m.id == ^file.id))

      assert {:error, :not_found} = Media.delete_file(file.id, where_used: :cascade)
      assert File.exists?(full)
      assert File.read!(full) == "keep-me"
    end

    test "the stale-guarded DB delete delete_file performs never raises Ecto.StaleEntryError" do
      file = insert_file!()
      {:ok, held} = Media.get_file(file.id)

      # A racing DELETE consumes the row after `held` was read — exactly the
      # struct a concurrent delete_file is holding when it reaches Repo.delete.
      {1, _} = Repo.delete_all(from(m in MediaFile, where: m.id == ^file.id))

      # Pre-fix delete_file ran a bare `Repo.delete(file)` here, which raises an
      # uncaught Ecto.StaleEntryError (a 500) under a concurrent double-DELETE.
      assert_raise Ecto.StaleEntryError, fn -> Repo.delete(held) end

      # The guarded form delete_file now uses surfaces the race as a changeset
      # (mapped to {:error, :not_found}) instead of raising.
      assert {:error, %Ecto.Changeset{}} = Repo.delete(held, stale_error_field: :id)
    end
  end

  # ---------------------------------------------------------------------------
  # upload/3 — storage-fault path
  #
  # The happy path needs a real multipart Plug.Upload + plugin hooks and is
  # covered by the controller integration tests. Here we pin the NON-raising
  # storage-fault behaviour: a disk write that can't complete must return the
  # typed {:error, :storage_unavailable} (mapped to an enveloped 503 by
  # FallbackController) instead of raising File.cp!/mkdir_p!/stat! → a bare 500,
  # and must not create a MediaFile row.
  # ---------------------------------------------------------------------------
  describe "upload/3 storage fault" do
    test "a copy failure returns {:error, :storage_unavailable} and inserts no row" do
      # A Plug.Upload whose temp file does not exist makes File.cp fail with
      # :enoent — standing in for ENOSPC / EACCES / read-only mount without
      # needing a real broken volume.
      missing = Path.join(System.tmp_dir!(), "bp-missing-#{System.unique_integer([:positive])}")
      refute File.exists?(missing)

      upload = %Plug.Upload{
        filename: "broken-#{System.unique_integer([:positive])}.png",
        path: missing,
        content_type: "image/png"
      }

      {_, before_count} = Media.query_files(@dataset)

      assert {:error, :storage_unavailable} = Media.upload(upload, @dataset)

      # No orphan DB row: the write bailed before Repo.insert.
      {_, after_count} = Media.query_files(@dataset)
      assert after_count == before_count

      refute Repo.exists?(from(m in MediaFile, where: m.original_name == ^upload.filename))
    end
  end

  # ---------------------------------------------------------------------------
  # upload/3 — PART 2 config-gated allowlist + size cap (SECURITY)
  #
  # These pin the REJECT paths only, so they never reach the plugin hooks /
  # Repo.insert (safe under async). Each proves the veto happens BEFORE any blob
  # is persisted: the returned tuple is the typed error, no MediaFile row exists,
  # and no file under the upload dir carries the upload's unique marker bytes.
  # ---------------------------------------------------------------------------
  describe "upload/3 config-gated allowlist (PART 2)" do
    test "MIME not in allowed_mime_types → :unsupported_media_type, no blob, no row" do
      put_media_cfg(
        allowed_mime_types: ["image/png"],
        allowed_extensions: [],
        max_upload_bytes: nil
      )

      marker = "evil-marker-#{System.unique_integer([:positive])}"
      upload = temp_upload("evil.txt", marker)

      {_, before_count} = Media.query_files(@dataset)
      assert {:error, :unsupported_media_type} = Media.upload(upload, @dataset)

      {_, after_count} = Media.query_files(@dataset)
      assert after_count == before_count
      refute Repo.exists?(from(m in MediaFile, where: m.original_name == ^upload.filename))
      refute blob_written?(marker)
    end

    test "extension not in allowed_extensions → :unsupported_media_type, no blob" do
      put_media_cfg(
        allowed_mime_types: [],
        allowed_extensions: ["png", "jpg"],
        max_upload_bytes: nil
      )

      marker = "ext-marker-#{System.unique_integer([:positive])}"
      upload = temp_upload("notes.txt", marker)

      assert {:error, :unsupported_media_type} = Media.upload(upload, @dataset)
      refute blob_written?(marker)
    end

    test "size above max_upload_bytes → :payload_too_large, no blob, no row" do
      put_media_cfg(allowed_mime_types: [], allowed_extensions: [], max_upload_bytes: 4)

      marker = "big-marker-#{System.unique_integer([:positive])}"
      # ~100 bytes, well over the 4-byte cap.
      upload = temp_upload("big.png", String.duplicate(marker, 5))

      assert {:error, :payload_too_large} = Media.upload(upload, @dataset)
      refute Repo.exists?(from(m in MediaFile, where: m.original_name == ^upload.filename))
      refute blob_written?(marker)
    end

    test "server-derived MIME ignores the client content_type header (allowlist keys off the real type)" do
      # An allowlist of image/png must ACCEPT-logic on the SERVER-derived type, so
      # a .txt LYING that it is image/png in the multipart header is still
      # rejected — the client claim never enters the decision.
      put_media_cfg(
        allowed_mime_types: ["image/png"],
        allowed_extensions: [],
        max_upload_bytes: nil
      )

      marker = "lie-marker-#{System.unique_integer([:positive])}"
      tmp = Path.join(System.tmp_dir!(), "mt-lie-#{System.unique_integer([:positive])}.txt")
      File.write!(tmp, marker)
      liar = %Plug.Upload{path: tmp, filename: "totally.txt", content_type: "image/png"}

      assert {:error, :unsupported_media_type} = Media.upload(liar, @dataset)
      refute blob_written?(marker)
    end
  end
end
