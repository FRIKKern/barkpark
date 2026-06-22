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
    * `list_files/2` — returns all unscoped rows for a dataset.
    * `query_files/2` — returns {files, total_count}.
    * `search_files/2` — returns {files, total, facets, meta}.

  The `upload/3` function requires real `Plug.Upload` + disk I/O + plugin
  hooks — it is exercised through the controller integration tests; this file
  stays at the context boundary.

  `async: true` is safe here — every DB write is row-level and the SQL sandbox
  provides per-test isolation. Tests that create workspace fixtures use unique
  slugs from `System.unique_integer/1` to avoid collisions.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Media
  alias Barkpark.Media.MediaFile
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
      assert {:error, :not_found} = Media.delete_file(Ecto.UUID.generate())
    end

    test "deletes the DB row and returns {:ok, file}" do
      file = insert_file!()

      # We need the file on disk (even empty) because delete_file calls File.rm
      full = Path.join(@upload_dir, file.path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "")

      assert {:ok, deleted} = Media.delete_file(file.id)
      assert deleted.id == file.id

      # Verify the row is gone
      assert {:error, :not_found} = Media.get_file(file.id)
    end

    test "workspace-scoped delete returns :not_found for cross-workspace id" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()

      file_a = insert_file!(%{workspace_id: ws_a.id, project_id: proj_a.id})

      assert {:error, :not_found} = Media.delete_file(file_a.id, workspace_id: ws_b.id)

      # The file must still exist — it was not deleted
      assert {:ok, _} = Media.get_file(file_a.id, workspace_id: ws_a.id)
    end
  end
end
