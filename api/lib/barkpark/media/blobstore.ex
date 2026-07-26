defmodule Barkpark.Media.Blobstore do
  @moduledoc """
  Pluggable byte storage for media blobs — the ONE seam between "a blob exists
  at this server-generated relative path" and "where its bytes physically live".

  Every module above this line (upload, serve, renditions, probe, delete,
  blob-push) already speaks in relative paths (`uploads/YYYY/MM/slug-rand.ext`,
  `_renditions/{id}/{preset}.{ext}`); this behaviour keeps that contract and
  swaps only the byte transport underneath:

    * `Barkpark.Media.Blobstore.Local` — today's on-disk layout under
      `Media.upload_dir/0`, byte-identical to the pre-blobstore behaviour.
      The DEFAULT: an unconfigured instance changes nothing.
    * `Barkpark.Media.Blobstore.S3` — originals in any S3-compatible bucket
      (Cloudflare R2, AWS S3, MinIO, Backblaze B2, Tigris, …) with the local
      disk demoted to a regenerable write-through cache.

  Renditions are NOT routed through the backend: they are a derivable cache
  (`Renditions.generate_all/2` can always rebuild them from the original), so
  they stay on local disk under `_renditions/` regardless of backend and keep
  serving via `send_file` unchanged. Only ORIGINAL bytes move.

  Backend selection is read at CALL TIME (mirrors `Media.upload_dir/0`'s
  runtime read) from:

      config :barkpark, :media_storage, backend: :local | :s3

  so `BARKPARK_MEDIA_STORAGE` (runtime.exs) can switch it without a recompile
  and tests can override per-case.
  """

  alias Barkpark.Media.Blobstore.{Local, S3}

  @typedoc "Server-generated path relative to the media root — never raw client input."
  @type relative_path :: String.t()

  @typedoc """
  How a controller should answer a request for these bytes:

    * `{:file, absolute_path}` — stream from local disk via `send_file` (the
      existing hardened path: nosniff + type collapse stay in the controller).
    * `{:redirect, url}` — 302 to a time-limited presigned URL. The
      `opts` a caller passed (`:response_content_type` /
      `:response_content_disposition`) are baked INTO the signed query so the
      bucket echoes the same stored-XSS defenses the local path applies.
    * `{:error, :not_found}` — the row outlived its blob; answer an honest 404.
  """
  @type serve_strategy ::
          {:file, String.t()} | {:redirect, String.t()} | {:error, :not_found}

  @doc "Persist a temp file's bytes at `relative_path`. `opts`: `:content_type`."
  @callback put_file(relative_path(), source_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Persist in-memory bytes at `relative_path` (cross-instance blob push)."
  @callback put_bytes(relative_path(), body :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Best-effort removal of the blob (and any local cache copy)."
  @callback delete(relative_path()) :: :ok | {:error, term()}

  @doc """
  Guarantee a locally readable copy and return its absolute path — the bridge
  for byte-consumers that need a real file (probe, rendition generation).
  Local: a plain path join. S3: download into the write-through cache once.
  """
  @callback ensure_local(relative_path()) :: {:ok, String.t()} | {:error, term()}

  @doc "Resolve how to answer an HTTP request for the blob. See `t:serve_strategy/0`."
  @callback serve_strategy(relative_path(), opts :: keyword()) :: serve_strategy()

  def put_file(relative_path, source_path, opts \\ []),
    do: impl().put_file(relative_path, source_path, opts)

  def put_bytes(relative_path, body, opts \\ []),
    do: impl().put_bytes(relative_path, body, opts)

  def delete(relative_path), do: impl().delete(relative_path)

  def ensure_local(relative_path), do: impl().ensure_local(relative_path)

  def serve_strategy(relative_path, opts \\ []),
    do: impl().serve_strategy(relative_path, opts)

  @doc """
  The active backend module. `:local` when unconfigured, so every existing
  deployment keeps byte-identical behaviour without touching config.
  """
  @spec impl() :: module()
  def impl do
    case Application.get_env(:barkpark, :media_storage, [])[:backend] do
      :s3 -> S3
      _ -> Local
    end
  end
end
