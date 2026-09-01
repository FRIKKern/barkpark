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

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore.{Local, S3}
  alias Barkpark.Media.Storage.{MediaFile, ObjectKey}

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

  @typedoc """
  What a write can honestly claim about the bytes afterwards.

    * `:received` — how many bytes this instance handed to the backend. This is
      a fact about THIS process, never about the store.
    * `:stored` — how many bytes a POST-CONDITION READ found in the store, or
      `:unverified` when no read-back could be performed. It is NEVER the
      received count copied across.
    * `:verified_by` — which read produced `:stored`: `:stat` (the local
      backend's `File.stat` on the real store) or `:head` (an S3 HEAD that
      bypasses the write-through cache). `nil` when `:stored` is `:unverified`.
      `:etag` is reserved and deliberately unused: a PUT's ETag is
      response-backed, absent under SSE-KMS and multipart, and therefore
      strictly weaker than a post-condition read.
    * `:unverified_reason` — the NAMED reason the read-back could not answer
      (e.g. `:no_content_length`, a transport error). `nil` when verified.
  """
  @type receipt :: %{
          received: non_neg_integer(),
          stored: non_neg_integer() | :unverified,
          verified_by: :stat | :head | :etag | nil,
          unverified_reason: term() | nil
        }

  @doc """
  Persist a temp file's bytes at `relative_path`. `opts`: `:content_type`.

  Answers `{:ok, receipt}` — the write ACK plus whatever the post-condition
  read could prove — or `{:error, :not_stored}` when the read-back proves the
  bytes are ABSENT despite an accepted write.
  """
  @callback put_file(relative_path(), source_path :: String.t(), opts :: keyword()) ::
              {:ok, receipt()} | {:error, term()}

  @doc """
  Persist in-memory bytes at `relative_path` (cross-instance blob push).
  Same receipt contract as `c:put_file/3`.
  """
  @callback put_bytes(relative_path(), body :: binary(), opts :: keyword()) ::
              {:ok, receipt()} | {:error, term()}

  @doc "Best-effort removal of the blob (and any local cache copy)."
  @callback delete(relative_path()) :: :ok | {:error, term()}

  @doc """
  Guarantee a locally readable copy and return its absolute path — the bridge
  for byte-consumers that need a real file (probe, rendition generation).
  Local: a plain path join. S3: download into the write-through cache once.
  """
  @callback ensure_local(relative_path()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Read the blob's size back FROM THE STORE — the post-condition read behind
  every `t:receipt/0`.

  This callback exists because the two obvious cheap checks are both fooled by
  the S3 backend's write-through cache and would report a store that never
  happened:

    * `File.stat(Media.file_path(rel))` passes with the EXACT expected byte
      count, because `S3.put_file/3` warm-caches the source at that path.
    * `ensure_local/1` also passes, with ZERO bucket requests, because it
      short-circuits on `File.regular?`.

  So the contract is: answer from the STORE, never from the cache. `Local`
  stats the real store (there is no cache to bypass — the disk IS the store);
  `S3` sends a presigned HEAD.

    * `{:ok, %{size: n}}` — the store holds `n` bytes at that path.
    * `{:error, :not_found}` — the store PROVABLY does not hold it.
    * `{:error, reason}` — the read-back could not be performed; the caller
      degrades to a NAMED `:unverified`, never to the received count.
  """
  @callback stat_blob(relative_path()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :not_found | term()}

  @doc "Resolve how to answer an HTTP request for the blob. See `t:serve_strategy/0`."
  @callback serve_strategy(relative_path(), opts :: keyword()) :: serve_strategy()

  def put_file(relative_path, source_path, opts \\ []),
    do: impl().put_file(relative_path, source_path, opts)

  def put_bytes(relative_path, body, opts \\ []),
    do: impl().put_bytes(relative_path, body, opts)

  # ── READ/SERVE SEAM TRAVERSAL GUARD (felix scar-class defence-in-depth) ─────
  #
  # `relative_path` is typed as server-generated and "never raw client input"
  # (see `t:relative_path/0`), but that is a CALLER-side invariant with no callee
  # enforcement: `import_member/3` COPYs bundle rows straight into `media_files`
  # past `MediaFile.changeset/2` (Blobstore.Local PATH PROVENANCE clause 2), so an
  # admin bundle CAN plant `../../..` in `media_files.path`. Every DB-path read
  # sink funnels through here — `serve_strategy/2` (share_link + tickets_attachments
  # + media controllers), `ensure_local/1` (rendition source + probe) — plus the
  # `File.rm` in `delete/1`. Promote the write seam's `Media.valid_blob_path?/1`
  # per-segment allowlist to these verbs so a traversal-shaped path fails CLOSED to
  # the existing missing-blob shapes (`{:error, :not_found}` / a skipped `delete`)
  # BEFORE it reaches `send_file`/`File.rm`, rather than resolving and serving.
  #
  # ZERO SOBELOW DELTA — intentional. Sobelow has no taint model and fires on any
  # non-empty extracted `File.*` argument, so routing through a guard does not
  # retire a `Traversal.FileModule` finding (it just extracts the guard's name).
  # This is scar-class defence-in-depth (the moduledoc invariant, ENFORCED not
  # asserted), NOT a vulnerability fix — reachability is authorization-bounded.
  #
  # Renditions' `_renditions/<uuid>/…` cache paths do NOT pass this allowlist
  # (leading `_`), but they never reach a Blobstore verb: they resolve via
  # `Media.file_path/1` directly (renditions.ex) and stay on local disk by design
  # (see the "Renditions are NOT routed through the backend" moduledoc note), so
  # this guard leaves them untouched.
  defp safe_blob_path?(relative_path), do: Media.valid_blob_path?(relative_path)

  # ── ROW-ADDRESSED VERBS (task-8eb6542ece62aff1) ────────────────────────────
  #
  # A bare `relative_path` carries NO TENANT, so a store addressed by it alone
  # cannot tell two rows at one path apart and hands the second claimant the
  # first one's bytes. These heads take the ROW and resolve its object through
  # the single owner `Media.object_key/1`, which answers "which object does THIS
  # row address" — the path itself for every uncontested and every born-keyed
  # row (the overwhelming majority, zero queries), the row's own tenant shadow
  # for a contested legacy flat key.
  #
  # The bare-string heads BELOW stay, and are not a bypass to be closed: they
  # are the seam for keys no row claims yet — the bundle importer's blob push
  # (`Media.put_blob/3`, rows COPYed first, bytes pushed after) and
  # `scripts/pds-scratch-target.sh`'s bare-path probe. A caller holding a
  # `%MediaFile{}` must use these heads; `ObjectKey.for_row/1` is what makes them
  # differ from `verb(file.path)`.
  def delete(%MediaFile{} = file), do: delete(ObjectKey.for_row(file))

  def delete(relative_path) do
    if safe_blob_path?(relative_path), do: impl().delete(relative_path), else: :ok
  end

  def ensure_local(%MediaFile{} = file), do: ensure_local(ObjectKey.for_row(file))

  def ensure_local(relative_path) do
    if safe_blob_path?(relative_path),
      do: impl().ensure_local(relative_path),
      else: {:error, :not_found}
  end

  def stat_blob(relative_path), do: impl().stat_blob(relative_path)

  @doc """
  Assemble a `t:receipt/0` from a write's received count and the backend's own
  post-condition read — the ONE place the received/stored distinction is
  resolved, so no backend can accidentally answer the question with its own
  input.

  A read-back that proves ABSENCE is not a degraded receipt, it is a failed
  write: `{:error, :not_stored}`. A read-back that could not be PERFORMED is a
  receipt whose `:stored` is the named `:unverified` — the received count is
  never copied into it.
  """
  @spec receipt(
          non_neg_integer(),
          :stat | :head,
          {:ok, %{size: non_neg_integer()}} | {:error, term()}
        ) ::
          {:ok, receipt()} | {:error, :not_stored}
  def receipt(received, verified_by, read_back)

  def receipt(received, verified_by, {:ok, %{size: size}}) do
    {:ok, %{received: received, stored: size, verified_by: verified_by, unverified_reason: nil}}
  end

  def receipt(_received, _verified_by, {:error, :not_found}), do: {:error, :not_stored}

  def receipt(received, _verified_by, {:error, reason}) do
    {:ok, %{received: received, stored: :unverified, verified_by: nil, unverified_reason: reason}}
  end

  def serve_strategy(path_or_file, opts \\ [])

  def serve_strategy(%MediaFile{} = file, opts),
    do: serve_strategy(ObjectKey.for_row(file), opts)

  def serve_strategy(relative_path, opts) do
    if safe_blob_path?(relative_path),
      do: impl().serve_strategy(relative_path, opts),
      else: {:error, :not_found}
  end

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
