defmodule Barkpark.Media.Blobstore.Local do
  @moduledoc """
  The on-disk backend — a verbatim extraction of the pre-blobstore file ops
  (`File.mkdir_p` + `File.cp` / `File.write` under `Media.upload_dir/0`).

  Every operation is NON-raising and collapses unexpected file errors to
  `{:error, :storage_unavailable}`, preserving `Media.upload/3`'s contract
  that a disk fault (ENOSPC / EACCES / read-only mount) surfaces as an
  enveloped 503, never a bare 500.

  Both write verbs answer with a `t:Barkpark.Media.Blobstore.receipt/0`: the
  bytes RECEIVED plus a post-condition `stat_blob/1` read of what the store
  actually holds. Here the disk IS the store — there is no write-through cache
  to bypass — so `File.stat` on the real path is the honest read, not the trap
  it would be under the S3 backend.
  """

  @behaviour Barkpark.Media.Blobstore

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore

  @impl true
  def put_file(relative_path, source_path, _opts) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.cp(source_path, full_path),
         {:ok, %File.Stat{size: received}} <- File.stat(source_path) do
      Blobstore.receipt(received, :stat, stat_blob(relative_path))
    else
      # cp may have written a partial file before failing → best-effort cleanup
      # so no orphan blob survives (moved here verbatim from Media.upload/3).
      {:error, _reason} ->
        _ = File.rm(full_path)
        {:error, :storage_unavailable}
    end
  end

  @impl true
  def put_bytes(relative_path, body, _opts) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, body) do
      Blobstore.receipt(byte_size(body), :stat, stat_blob(relative_path))
    else
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  @impl true
  def stat_blob(relative_path) do
    case File.stat(Media.file_path(relative_path)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, %{size: size}}
      # a directory (or a device/symlink target) at the blob path is not a blob
      {:ok, %File.Stat{}} -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(relative_path) do
    _ = File.rm(Media.file_path(relative_path))
    :ok
  end

  @impl true
  def ensure_local(relative_path) do
    full_path = Media.file_path(relative_path)

    if File.regular?(full_path) do
      {:ok, full_path}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def serve_strategy(relative_path, _opts) do
    # The `File.regular?` probe is the HONEST missing-blob 404 the serve edge
    # relies on (a media_files row can outlive its blob after a bundle import)
    # — without it send_file's internal File.stat raises on :enoent → 500.
    case ensure_local(relative_path) do
      {:ok, full_path} -> {:file, full_path}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
