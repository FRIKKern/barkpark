defmodule Barkpark.Media do
  @moduledoc "Context for media file upload, storage, and retrieval."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Delivery.{Cdn, Events}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @asset_type "mediaAsset"

  @metadata_fields ~w(title altText caption description tags collection collections assetRole rights focalPoint relatedAssets bp_visibility)

  # ── blob path allowlist (pds W1 G2 — put_blob/2) ───────────────────────────
  #
  # The cross-instance blob-push route (PUT .../media/blob/*path) writes bytes at
  # a caller-supplied RELATIVE path. Each `/`-segment must match the
  # server-generated blob shape — `unique_filename/1` emits `slug-<hex>.ext` and
  # the date dirs are `YYYY`/`MM` — i.e. `[A-Za-z0-9._-]+`. `.` and `..` are
  # rejected outright (no traversal, no current-dir), an absolute path (leading
  # `/` → empty first segment) is rejected, and an empty path is rejected. This
  # is a strict allowlist, NOT a blocklist, so an unforeseen escape shape fails
  # closed.
  @blob_segment ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc """
  The media blob root.

  Read at CALL TIME (not `compile_env`) so `BARKPARK_MEDIA_DIR` (runtime.exs)
  can relocate the blob root without a recompile — the Personal-Local twin
  points it at a portable data dir so pulled cloud blobs land beside its data.
  Unset resolves to the `config/config.exs` default, byte-identical to the old
  compile-time capture (`Application.fetch_env!` raises on a truly-missing key,
  the same guarantee `compile_env!` gave).
  """
  def upload_dir, do: Application.fetch_env!(:barkpark, :media_upload_dir)

  @doc """
  Save an uploaded file to disk and create a DB record.

  `opts` may carry tenancy scope stamped onto the new row on insert (mirrors
  `Barkpark.Content` write scoping):
    * `:workspace_id` — stamp the owning workspace (nil = unscoped / pre-tenancy).
    * `:project_id`   — stamp the owning project (nil = workspace-wide).
  """
  def upload(plug_upload, dataset, opts \\ []) when is_binary(dataset) do
    %Plug.Upload{filename: original_name, path: temp_path} = plug_upload

    # Generate date-based path: uploads/2026/04/filename
    now = DateTime.utc_now()
    date_dir = "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}"
    filename = unique_filename(original_name)
    relative_path = "#{date_dir}/#{filename}"

    # SECURITY — server-derived MIME + validate-before-persist.
    #
    # PART 1 (behavior-preserving): the stored `mime_type` is derived from the
    # filename the SAME way the serve path derives it (`MIME.from_path` — see
    # media_controller serve + media/probe.ex), NOT taken from the client-supplied
    # multipart `content_type`. A legit upload carries the real extension
    # (pixel.png, book.xml), so the derived type is byte-identical to what the
    # client claimed and to what serving already returns — only a header LIE can
    # no longer set the persisted mime. Size is read from the TEMP file (identical
    # bytes to the copy) so nothing is written until every check below passes.
    #
    # PART 2 (config-gated, OFF by default): `validate_upload/3` reads an optional
    # allowlist + size cap from app config. Unset/empty = allow-all (today's
    # behavior, zero rejections). When configured it rejects BEFORE any blob is
    # written (`unsupported_media_type` → 422 / `payload_too_large` → 413).
    #
    # Byte persistence is delegated to the configured `Blobstore` backend
    # (local disk by default; S3-compatible object storage when configured).
    # The backend is NON-raising so a storage fault (ENOSPC / EACCES /
    # read-only mount / unreachable bucket) returns {:error,
    # :storage_unavailable} — an enveloped 503 — instead of an uncaught raise
    # → bare 500. On ANY failure after the write we remove the (possibly
    # partial) blob so a rejected upload never orphans bytes.
    mime_type = MIME.from_path(original_name)

    with {:ok, %{size: size}} <- File.stat(temp_path),
         :ok <- validate_upload(mime_type, original_name, size),
         # `{:ok, receipt}` — the backend's write ACK plus its post-condition
         # read (see Blobstore.receipt/3). The row's `size` stays the SOURCE
         # size (what the client uploaded); the receipt is not persisted here,
         # it is the seam that lets a store which ACKs but does not store fail
         # as {:error, :not_stored} → the 503 below, instead of inserting a row
         # over bytes that are not there.
         {:ok, _receipt} <-
           Blobstore.put_file(relative_path, temp_path, content_type: mime_type) do
      # Create DB record. Tenancy scope (workspace_id/project_id) is stamped from
      # `opts` when the caller supplied a resolved scope — mirrors
      # `Barkpark.Content` write scoping so a new blob is owned by the workspace
      # it was uploaded into. Without scope opts the keys are absent and the row
      # keeps its pre-tenancy (nil) shape.
      attrs =
        %{
          filename: filename,
          original_name: original_name,
          path: relative_path,
          mime_type: mime_type,
          size: size,
          dataset: dataset
        }
        |> put_scope_attrs(opts)

      result =
        %MediaFile{}
        |> MediaFile.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, file} = ok ->
          _ =
            Barkpark.Plugins.Registry.run_after_media_upload(%{
              media_file: file,
              dataset: dataset
            })

          ok

        error ->
          # Insert (validation / DB) failed — the blob is already persisted, so
          # remove it to avoid orphaning bytes with no owning row, then surface
          # the original error unchanged (happy path + error shape preserved).
          _ = Blobstore.delete(relative_path)
          error
      end
    else
      # PART 2 rejects, raised by validate_upload BEFORE any blob is written — the
      # allowlist / size-cap veto. Nothing is persisted, so surface the typed error
      # (→ 422 / 413 via FallbackController) with no cleanup needed.
      {:error, :unsupported_media_type} = rejected ->
        rejected

      {:error, :payload_too_large} = rejected ->
        rejected

      {:error, _reason} ->
        # stat(temp) or the backend write failed. A partial write may survive
        # → best-effort cleanup so no orphan blob remains, then report storage
        # as unavailable (503) rather than raising.
        _ = Blobstore.delete(relative_path)
        {:error, :storage_unavailable}
    end
  end

  # PART 2 — config-gated upload allowlist + size cap. OFF by default: an unset /
  # empty allowlist and a nil cap short-circuit to :ok, so an unconfigured server
  # accepts every type + size exactly as before (allow-all). Configure via:
  #
  #     config :barkpark, :media_uploads,
  #       allowed_mime_types: ["image/png", "image/jpeg"],  # server-derived MIME
  #       allowed_extensions: ["png", "jpg", "jpeg"],        # lower-case, no dot
  #       max_upload_bytes: 10_000_000                       # per-upload cap
  #
  # Read at RUNTIME (not compile_env) so an operator can flip it via runtime.exs
  # and tests can override per-case. Rejection happens BEFORE the blob is
  # persisted, so a disallowed upload never touches disk.
  defp validate_upload(mime_type, original_name, size) do
    cfg = Application.get_env(:barkpark, :media_uploads, [])

    with :ok <- check_mime(cfg, mime_type),
         :ok <- check_extension(cfg, original_name) do
      check_size(cfg, size)
    end
  end

  defp check_mime(cfg, mime_type) do
    case Keyword.get(cfg, :allowed_mime_types, []) do
      allowed when allowed in [nil, []] ->
        :ok

      allowed ->
        if mime_type in allowed, do: :ok, else: {:error, :unsupported_media_type}
    end
  end

  defp check_extension(cfg, original_name) do
    case Keyword.get(cfg, :allowed_extensions, []) do
      allowed when allowed in [nil, []] ->
        :ok

      allowed ->
        ext = original_name |> Path.extname() |> String.downcase() |> String.trim_leading(".")
        normalized = Enum.map(allowed, &(&1 |> String.downcase() |> String.trim_leading(".")))
        if ext in normalized, do: :ok, else: {:error, :unsupported_media_type}
    end
  end

  # Per-upload byte cap. This does NOT duplicate the endpoint's 100 MB body bound
  # (Plug.Parsers → RequestTooLargeError → enveloped 413 in endpoint.ex): that is
  # a hard global ceiling on the whole multipart body; this is an OPTIONAL,
  # operator-set, tighter per-media cap. nil (the default) = no media-layer cap,
  # so the 100 MB body bound remains the only limit and behavior is unchanged.
  defp check_size(cfg, size) do
    case Keyword.get(cfg, :max_upload_bytes) do
      nil -> :ok
      max when is_integer(max) and size <= max -> :ok
      max when is_integer(max) -> {:error, :payload_too_large}
    end
  end

  @doc "List all media files for a dataset."
  def list_files(dataset, opts \\ []) when is_binary(dataset) do
    {files, _} = query_files(dataset, Keyword.delete(opts, :limit) |> Keyword.put(:limit, 10_000))
    files
  end

  @doc """
  Paginated media query. Returns `{files, total_count}`.

  Options:
    * `:limit`, `:offset`
    * `:mime_type` — MIME prefix (`image/` → `LIKE 'image/%'`)
    * `:kind` — `mediaAsset.bp_asset_kind` (`image`, `video`, …)
    * `:q` — case-insensitive search on filename / original name / asset title
  """
  @spec query_files(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer()}
  def query_files(dataset, opts \\ []) when is_binary(dataset) do
    search_opts =
      opts
      |> Keyword.take([
        :limit,
        :offset,
        :mime_type,
        :kind,
        :q,
        :status,
        :processing,
        :collection,
        :tags,
        :visibility,
        :sort,
        :workspace_id,
        :project_id
      ])
      |> Keyword.put_new(:limit, 50)
      |> Keyword.put_new(:offset, 0)

    {files, total, _facets, _meta} = Barkpark.Media.Delivery.Search.search(dataset, search_opts)
    {files, total}
  end

  @doc """
  Faceted search. Returns `{files, total, facets, meta}`.
  See `Barkpark.Media.Delivery.Search` for supported options.
  """
  @spec search_files(String.t(), keyword()) ::
          {[MediaFile.t()], non_neg_integer(), map(), map()}
  def search_files(dataset, opts \\ []) when is_binary(dataset) do
    Barkpark.Media.Delivery.Search.search(dataset, opts)
  end

  @doc """
  Batch-load linked `mediaAsset` documents keyed by blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); it is
  threaded into `Assets.find_by_media_file_ids/3` so a listing resolved to
  workspace B never resolves workspace A's asset metadata (title/tags/rights)
  for a blob that shares the dataset STRING — the cross-workspace metadata leak
  (barkpark-vmv1). The asset-doc envelope is NULL-tolerant so legacy
  NULL-workspace docs stay visible in their own tenant.
  """
  @spec asset_docs_for_files([MediaFile.t()], String.t(), keyword()) :: %{
          String.t() => struct()
        }
  def asset_docs_for_files(files, dataset, opts \\ [])
      when is_list(files) and is_binary(dataset) and is_list(opts) do
    ids = Enum.map(files, & &1.id)
    Assets.find_by_media_file_ids(ids, dataset, opts)
  end

  @doc """
  Linked `mediaAsset` document for a blob row, if any.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); threaded
  into `Assets.find_by_media_file_id/3` so a relation-graph read scoped to
  workspace B never resolves workspace A's asset doc for the same blob id
  (barkpark-m21z). An absent workspace_id is the deliberate global / legacy
  single-tenant path — the 2-arity callers stay unchanged via the default.
  """
  @spec asset_doc_for_file(MediaFile.t(), String.t(), keyword()) :: struct() | nil
  def asset_doc_for_file(%MediaFile{} = file, dataset, opts \\ []) do
    Assets.find_by_media_file_id(file.id, dataset, opts)
  end

  @doc """
  Patch metadata on the linked `mediaAsset` document. Creates the asset
  document if missing. Does not mutate blob fields (`fileInfo`, `mediaFileId`).
  """
  @spec patch_asset_metadata(MediaFile.t(), map(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def patch_asset_metadata(%MediaFile{} = file, params, dataset) when is_map(params) do
    with {:ok, doc} <- ensure_asset_doc(file),
         {:ok, _schema} <- Content.get_schema(@asset_type, dataset) do
      patch = pick_metadata(params)
      title = Map.get(patch, "title", doc.title)
      content_patch = Map.drop(patch, ["title"])

      content =
        (doc.content || %{})
        |> Map.merge(content_patch)
        |> Map.put("mediaFileId", file.id)

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(
             @asset_type,
             attrs,
             dataset,
             [source: :api] ++ Assets.file_scope_opts(file)
           ) do
        {:ok, updated} -> {:ok, updated}
        error -> error
      end
    end
  end

  defp ensure_asset_doc(%MediaFile{} = file) do
    case Assets.ensure_for_upload(file) do
      {:ok, doc} -> {:ok, doc}
      error -> error
    end
  end

  defp pick_metadata(params) do
    params
    |> stringify_keys()
    |> Map.take(@metadata_fields)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Get a single media file by ID.

  `opts` may carry tenancy scope (mirrors `Barkpark.Content.get_document`):
    * `:workspace_id` — scope the read to a workspace (nil = unscoped).
    * `:project_id`   — further narrow to a project (requires `:workspace_id`).

  The workspace/project filter is applied via
  `Barkpark.Content.Scope.scope_to_workspace/3`, so a get scoped to workspace B
  returns `{:error, :not_found}` for a blob owned by workspace A.
  """
  def get_file(id, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    # Guard the :binary_id cast: a non-UUID id (e.g. GET /v1/media/:ds/garbage)
    # would raise Ecto.CastError → 500. A malformed id matches no row → not_found.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        MediaFile
        |> where([m], m.id == ^uuid)
        |> Content.Scope.scope_to_workspace_or_global(workspace_id, project_id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          file -> {:ok, file}
        end
    end
  end

  @doc """
  Get a media file by its storage-relative path.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); when present
  the path lookup is scoped through `Content.Scope.scope_to_workspace_or_global/3`
  so a serve scoped to workspace B never resolves a blob owned by workspace A
  (barkpark-af50). An unscoped lookup keeps the explicit-global behaviour, so the
  public serve path is unchanged until a workspace is threaded in.
  """
  @spec get_file_by_path(String.t(), keyword()) :: {:ok, MediaFile.t()} | {:error, :not_found}
  def get_file_by_path(relative_path, opts \\ []) when is_binary(relative_path) do
    MediaFile
    |> where([m], m.path == ^relative_path)
    |> Content.Scope.scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  Delete a media file from disk and DB.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); the
  about-to-delete read is scoped through `get_file/2` so a delete in workspace B
  returns `{:error, :not_found}` for a blob owned by workspace A (barkpark-af50).
  An unscoped delete keeps the explicit-global behaviour for back-compat.
  """
  def delete_file(id, opts \\ []) do
    case get_file(id, opts) do
      {:ok, file} ->
        # Resolve the webhook payload BEFORE deleting so the DB delete is the
        # FIRST side effect: on failure the row survives intact (still
        # pointing at a live blob) and no phantom media.deleted fires.
        doc = asset_doc_for_file(file, file.dataset)

        # A stale delete means a concurrent DELETE already consumed the row →
        # {:error, :not_found} (both controllers 404 via FallbackController)
        # instead of an uncaught Ecto.StaleEntryError (a 500).
        case Repo.delete(file, stale_error_field: :id) do
          {:ok, deleted} ->
            # The FOUR irreversible non-DB effects — CDN edge purge, the
            # `media.deleted` webhook, the on-disk `File.rm`, and the rendition
            # cache removal — are DEFERRED when we're inside a transaction so a
            # later rollback cannot strand a surviving row's blob (phantom
            # media). Outside a transaction they fire IMMEDIATELY (unchanged for
            # the three non-transaction callers: ticket attachments + the two
            # media controllers). See `defer_media_effect/1`.
            defer_media_effect(fn ->
              Cdn.invalidate(file)
              Events.dispatch(file.dataset, "media.deleted", file, doc)
              Blobstore.delete(file.path)
              Barkpark.Media.Renditions.delete_for_file(file.id)
            end)

            # `run_after_media_delete` is a DB write and MUST stay inside the
            # transaction so it rolls back with the row. HOOK CONTRACT: an
            # `after_media_delete` plugin callback may only touch the DATABASE —
            # NO file or HTTP I/O — because it runs before commit and would
            # otherwise re-open exactly the phantom hole this deferral closes.
            _ =
              Barkpark.Plugins.Registry.run_after_media_delete(%{
                media_file_id: file.id,
                dataset: file.dataset
              })

            {:ok, deleted}

          {:error, cs} ->
            if stale?(cs), do: {:error, :not_found}, else: {:error, cs}
        end

      error ->
        error
    end
  end

  # ── Deferred media-delete effects (felix-phantom-media-atomicity) ──────────
  #
  # `delete_file/2`'s four irreversible non-DB effects (CDN purge, the
  # `media.deleted` webhook, the on-disk `File.rm`, and rendition removal) must
  # NOT fire until the surrounding DB transaction COMMITS. Otherwise a rollback
  # (e.g. `Tenancy.delete_workspace/1` hitting a halted document delete) leaves
  # the `media_file` ROW alive but its blob/CDN/renditions already gone — a
  # phantom. This triad mirrors `Barkpark.Content.Broadcast`'s deferred-broadcast
  # triad exactly, keyed to its own process-dict slot. Effects are queued as
  # 0-arity closures (one per `delete_file/2` call, preserving per-file order)
  # and the transaction OWNER flushes on commit / clears on rollback.
  @deferred_media_effects :barkpark_deferred_media_effects

  # Run the effect NOW when outside a transaction (today's behaviour for the
  # three non-transaction callers); otherwise prepend it to the deferred queue
  # (reversed on flush to preserve original order) to fire on commit.
  defp defer_media_effect(effect) when is_function(effect, 0) do
    if Repo.in_transaction?() do
      queue = Process.get(@deferred_media_effects, [])
      Process.put(@deferred_media_effects, [effect | queue])
      :ok
    else
      effect.()
      :ok
    end
  end

  @doc """
  Fire every media-delete effect deferred during a committed transaction, in
  original (FIFO) order, then reset the queue. Called by the transaction owner
  (`Barkpark.Tenancy.delete_workspace/1`) on `{:ok, _}`. A no-op when nothing
  was deferred, so callers outside a transaction never need it.
  """
  def flush_deferred_media_effects do
    (Process.delete(@deferred_media_effects) || [])
    |> Enum.reverse()
    |> Enum.each(fn effect -> effect.() end)

    :ok
  end

  @doc """
  Drop every deferred media-delete effect WITHOUT firing it — called by the
  transaction owner on rollback/rescue so a rolled-back workspace delete leaves
  the blob, CDN entry, and renditions intact alongside the surviving rows.
  Also used to clear any stale queue before opening a transaction.
  """
  def clear_deferred_media_effects do
    Process.delete(@deferred_media_effects)
    :ok
  end

  # Repo.delete(struct, stale_error_field: :id) turns a would-be
  # Ecto.StaleEntryError into a changeset error tagged `stale: true` in the
  # error opts (mirrors content/lifecycle.ex). Match on that tag.
  defp stale?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, error_opts}} -> Keyword.get(error_opts, :stale) == true
      _ -> false
    end)
  end

  defp stale?(_), do: false

  @doc "Get the full disk path for serving a file."
  def file_path(relative_path) do
    Path.join(upload_dir(), relative_path)
  end

  @doc """
  Write a raw blob verbatim at a validated relative path under the media root.

  The cross-instance blob-push primitive (pds W1 G2): a bundle import on a
  TARGET instance receives each source blob by its server-generated relative
  path and drops the bytes at the same location so `serve/2` (which resolves the
  disk path from the DB row's `path`) finds them. Path validation is a strict
  allowlist (`@blob_segment` per segment; `.`/`..`/absolute/empty rejected) so a
  malicious or malformed path can never escape the media root:

    * `{:ok, relative_path, receipt}` — the backend took the bytes (parent dirs
      created) and answered a `t:Barkpark.Media.Blobstore.receipt/0`: how many
      bytes were RECEIVED, and how many a post-condition read of the STORE
      found (or the named `:unverified` when that read could not be performed).
      The two numbers are never merged — see `Blobstore.receipt/3`.
    * `{:error, :not_stored}` — the store ACKed the write and a read-back then
      proved the bytes are ABSENT (502).
    * `{:error, {:storage_mismatch, received, stored}}` — the read-back
      succeeded and DISAGREED with the received count (502). A disagreement is
      a failure, never a 200 with a discrepancy field.
    * `{:error, :invalid_path}` — the path is not a safe server-blob shape (422).
    * `{:error, :empty_body}` — a zero-byte body (422). No real media blob is
      empty; the common cause is a caller mislabeling the content-type (e.g.
      `application/json`), which lets `Plug.Parsers` consume the body before the
      controller reads it — refuse loudly instead of writing a 0-byte blob the
      serve path would then happily stream.
    * `{:error, :storage_unavailable}` — a disk fault on write (503).

  Non-raising file ops mirror `upload/3`: a read-only mount / ENOSPC returns a
  typed error, never a bare 500.
  """
  @spec put_blob(String.t(), binary()) ::
          {:ok, String.t(), Blobstore.receipt()}
          | {:error,
             :invalid_path
             | :empty_body
             | :storage_unavailable
             | :not_stored
             | {:storage_mismatch, non_neg_integer(), non_neg_integer()}}
  def put_blob(_relative_path, ""), do: {:error, :empty_body}

  def put_blob(relative_path, body) when is_binary(relative_path) and is_binary(body) do
    if valid_blob_path?(relative_path) do
      # The read-back lives BELOW this line, inside the backend (Blobstore's
      # stat_blob/1 callback) — deliberately not here. This module also owns
      # `file_path/1`, and a File.stat against that path is exactly the check
      # the S3 backend's write-through cache defeats: it returns the expected
      # size for an object the bucket never took.
      case Blobstore.put_bytes(relative_path, body, []) do
        {:ok, %{stored: :unverified} = receipt} ->
          {:ok, relative_path, receipt}

        {:ok, %{stored: stored, received: received} = receipt} when stored == received ->
          {:ok, relative_path, receipt}

        {:ok, %{stored: stored, received: received}} ->
          {:error, {:storage_mismatch, received, stored}}

        {:error, :not_stored} ->
          {:error, :not_stored}

        {:error, _reason} ->
          {:error, :storage_unavailable}
      end
    else
      {:error, :invalid_path}
    end
  end

  # A path is a safe server-blob path iff it is a non-empty relative path whose
  # every `/`-segment matches @blob_segment (so `.`, `..`, an absolute leading
  # `/`, a trailing `/`, and any `\`/null/space shape all fail closed).
  defp valid_blob_path?(relative_path) do
    segments = String.split(relative_path, "/")

    relative_path != "" and
      not String.starts_with?(relative_path, "/") and
      Enum.all?(segments, &Regex.match?(@blob_segment, &1))
  end

  # Stamp tenancy scope (:workspace_id / :project_id) onto write attrs when the
  # caller supplied it via opts. Only non-nil keys are added, so an unscoped
  # upload leaves the attr map untouched — mirrors `Barkpark.Content.put_scope_attrs`.
  #
  # W2 dual-write: also resolve the blob's `dataset` STRING → its `dataset_id`
  # (within the resolved project — opts `:project_id` or the seeded Default
  # project) and stamp BOTH. The string stays as a mirror; `dataset_id` is the
  # new authoritative leaf for the (path, dataset_id) uniqueness. Degrades to no
  # dataset_id (string-only) when the project/dataset can't be resolved.
  defp put_scope_attrs(attrs, opts) do
    project_id = Keyword.get(opts, :project_id) || default_project_id()

    attrs
    |> maybe_put_scope_attr(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put_scope_attr(:project_id, Keyword.get(opts, :project_id))
    |> maybe_put_scope_attr(:dataset_id, resolve_dataset_id(attrs, project_id))
  end

  defp default_project_id do
    case Barkpark.Tenancy.get_default_project() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp resolve_dataset_id(_attrs, nil), do: nil

  defp resolve_dataset_id(attrs, project_id) do
    case Map.get(attrs, :dataset) || Map.get(attrs, "dataset") do
      dataset when is_binary(dataset) ->
        case Barkpark.Tenancy.get_or_create_dataset(project_id, dataset) do
          {:ok, %Barkpark.Tenancy.Dataset{id: id}} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_put_scope_attr(attrs, _key, nil), do: attrs
  defp maybe_put_scope_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp unique_filename(original_name) do
    ext = Path.extname(original_name)
    base = Path.basename(original_name, ext)
    slug = base |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.trim("-")
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{slug}-#{random}#{ext}"
  end
end
