defmodule Barkpark.Media.Blobstore.LocalTest do
  @moduledoc """
  Round-trips the Local backend — the verbatim extraction of the
  pre-blobstore file ops, plus the post-condition read-back (`stat_blob/1`)
  that turns its write ACK into a storage claim. Pure filesystem under the test media root with
  unique per-test subpaths (`System.unique_integer/1`), so `async: true` is
  safe: no Application env is mutated and no paths collide.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore.Local

  defp unique_rel(name) do
    "test/blobstore-local/#{System.unique_integer([:positive])}/#{name}"
  end

  defp tmp_source!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "bp-blobstore-src-#{System.unique_integer([:positive])}"
      )

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "put_file/3 lands bytes at the relative path; ensure_local + serve_strategy resolve it" do
    rel = unique_rel("a.png")
    src = tmp_source!("png-bytes")

    assert {:ok, receipt} = Local.put_file(rel, src, content_type: "image/png")

    # RECEIVED and STORED are separate numbers, and STORED came from a read of
    # the store (here: the disk, which for this backend IS the store).
    assert receipt == %{
             received: 9,
             stored: 9,
             verified_by: :stat,
             unverified_reason: nil
           }

    full = Media.file_path(rel)
    assert File.read!(full) == "png-bytes"
    assert {:ok, ^full} = Local.ensure_local(rel)
    assert {:file, ^full} = Local.serve_strategy(rel, [])
  end

  test "put_bytes/3 writes in-memory bytes (blob-push shape) and reads the size back" do
    rel = unique_rel("pushed.bin")

    assert {:ok, receipt} = Local.put_bytes(rel, <<1, 2, 3>>, [])

    assert receipt == %{received: 3, stored: 3, verified_by: :stat, unverified_reason: nil}
    assert File.read!(Media.file_path(rel)) == <<1, 2, 3>>
  end

  test "stat_blob/1 reports the stored size, and :not_found for a path never written" do
    rel = unique_rel("statted.bin")
    assert {:ok, _} = Local.put_bytes(rel, "0123456789", [])

    assert {:ok, %{size: 10}} = Local.stat_blob(rel)
    assert {:error, :not_found} = Local.stat_blob(unique_rel("never.bin"))
  end

  test "stat_blob/1 refuses to call a DIRECTORY at the blob path a stored blob" do
    rel = unique_rel("its-a-dir")
    File.mkdir_p!(Media.file_path(rel))

    assert {:error, :not_found} = Local.stat_blob(rel)
  end

  test "delete/1 removes the blob and is idempotent" do
    rel = unique_rel("gone.txt")
    assert {:ok, _} = Local.put_bytes(rel, "x", [])

    assert :ok = Local.delete(rel)
    refute File.exists?(Media.file_path(rel))
    # second delete of an absent blob stays :ok — best-effort contract
    assert :ok = Local.delete(rel)
  end

  test "missing blobs answer {:error, :not_found} — the honest-404 seam" do
    rel = unique_rel("never-written.jpg")

    assert {:error, :not_found} = Local.ensure_local(rel)
    assert {:error, :not_found} = Local.serve_strategy(rel, [])
  end

  test "a source that cannot be read reports :storage_unavailable, not a raise" do
    rel = unique_rel("from-missing-src.dat")

    assert {:error, :storage_unavailable} =
             Local.put_file(rel, "/nonexistent/source-#{System.unique_integer()}", [])
  end
end
