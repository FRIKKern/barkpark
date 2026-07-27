defmodule Barkpark.Media.Blobstore.Local do
  @moduledoc """
  The on-disk backend — a verbatim extraction of the pre-blobstore file ops
  (`File.mkdir_p` + `File.cp` / `File.write` under `Media.upload_dir/0`).

  Every operation is NON-raising and collapses unexpected file errors to
  `{:error, :storage_unavailable}`, preserving `Media.upload/3`'s contract
  that a disk fault (ENOSPC / EACCES / read-only mount) surfaces as an
  enveloped 503, never a bare 500.
  """

  @behaviour Barkpark.Media.Blobstore

  alias Barkpark.Media

  @impl true
  def put_file(relative_path, source_path, _opts) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.cp(source_path, full_path) do
      :ok
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
      :ok
    else
      {:error, _reason} -> {:error, :storage_unavailable}
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
