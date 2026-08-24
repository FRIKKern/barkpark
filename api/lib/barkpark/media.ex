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
  #
  # A LEADING `-` is permitted: `unique_filename/1` genuinely emits `-<hex>.ext`
  # when the client basename slugs to empty (CJK/emoji/space-only names), so
  # those files exist on disk and in `media_files.path` — refusing them here
  # would 404 the read/serve seam for legitimately stored blobs. A leading `-`
  # has no path semantics (the joined path never starts with it), unlike a
  # leading `.` (traversal/hidden — still refused) or a leading `_` (still
  # refused, which keeps `_renditions/…` cache paths outside the Blobstore
  # verbs by construction).
  @blob_segment ~r/\A[A-Za-z0-9-][A-Za-z0-9._-]*\z/

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

    # Generate date-based path: 2026/04/filename, under the owning dataset's key
    # prefix once the scope resolves (see blob_key/3).
    now = DateTime.utc_now()
    date_dir = "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}"
    filename = unique_filename(original_name)

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

    # ORDER IS LOAD-BEARING (task-918106d49c62563e): the scope resolves BEFORE
    # any byte is written, because the blob key is DERIVED from the resolved
    # `dataset_id`. Scope-then-write is also strictly better on the error path —
    # a refused dataset slug no longer writes a blob it must then delete.
    with {:ok, %{size: size}} <- File.stat(temp_path),
         :ok <- validate_upload(mime_type, original_name, size),
         # Tenancy scope (workspace_id/project_id) is stamped from `opts` when the
         # caller supplied a resolved scope — mirrors `Barkpark.Content` write
         # scoping so a new blob is owned by the workspace it was uploaded into.
         # Without scope opts the keys are absent and the row keeps its
         # pre-tenancy (nil) shape. FAIL-CLOSED: a caller-supplied `dataset` slug
         # the Tenancy layer REFUSES returns {:error, {:invalid_dataset, _}} /
         # {:error, :conflict} here (never a silent dataset_id=nil) — routed to
         # 422/409 in the else block below.
         {:ok, attrs} <-
           put_scope_attrs(
             %{
               filename: filename,
               original_name: original_name,
               mime_type: mime_type,
               size: size,
               dataset: dataset
             },
             opts
           ) do
      persist_upload(
        attrs,
        blob_key(date_dir, filename, Map.get(attrs, :dataset_id)),
        temp_path,
        mime_type,
        dataset
      )
    else
      # PART 2 rejects, raised by validate_upload BEFORE any blob is written — the
      # allowlist / size-cap veto. Nothing is persisted, so surface the typed error
      # (→ 422 / 413 via FallbackController) with no cleanup needed.
      {:error, :unsupported_media_type} = rejected ->
        rejected

      {:error, :payload_too_large} = rejected ->
        rejected

      # put_scope_attrs refused a caller-supplied `dataset` slug. It now runs
      # BEFORE the write, so there is no orphan blob to clean up — the typed
      # error is surfaced UNCHANGED so FallbackController renders 422
      # validation_failed (invalid_dataset) / 409 conflict, NEVER the 503 storage
      # catch-all below. These two clauses MUST precede the {:error, _reason}
      # catch-all or the 422/409 is silently relabelled 503.
      {:error, {:invalid_dataset, _details}} = rejected ->
        rejected

      {:error, :conflict} = rejected ->
        rejected

      {:error, _reason} ->
        # stat(temp) failed. Nothing was written, so report storage as
        # unavailable (503) rather than raising.
        {:error, :storage_unavailable}
    end
  end

  # THE BLOB KEY AND THE ROW'S `path` ARE ONE VARIABLE (task-918106d49c62563e).
  #
  # `persist_upload/5` receives exactly one `relative_path` and uses it for BOTH
  # `Blobstore.put_file/3` (the object key) and `path:` on the inserted row (what
  # `serve/2` resolves verbatim). They cannot drift, because there is nothing to
  # drift from — which is what makes the dataset prefix safe with no migration:
  # a store that accepts writes it cannot serve requires two variables, and there
  # is only one.
  defp persist_upload(attrs, relative_path, temp_path, mime_type, dataset) do
    # `{:ok, receipt}` — the backend's write ACK plus its post-condition read
    # (see Blobstore.receipt/3). The row's `size` stays the SOURCE size (what the
    # client uploaded); the receipt is not persisted here, it is the seam that
    # lets a store which ACKs but does not store fail as {:error, :not_stored} →
    # a 503, instead of inserting a row over bytes that are not there.
    case Blobstore.put_file(relative_path, temp_path, content_type: mime_type) do
      {:ok, _receipt} ->
        insert_uploaded_row(Map.put(attrs, :path, relative_path), relative_path, dataset)

      {:error, _reason} ->
        # The backend write failed. A partial write may survive → best-effort
        # cleanup so no orphan blob remains, then report storage as unavailable
        # (503) rather than raising.
        _ = Blobstore.delete(relative_path)
        {:error, :storage_unavailable}
    end
  end

  defp insert_uploaded_row(attrs, relative_path, dataset) do
    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert()
    |> case do
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
  end

  # THE TENANT-KEYED BLOB KEY (task-918106d49c62563e).
  #
  # A blob born under a resolved dataset is addressed `d/<dataset_id>/YYYY/MM/…`.
  # Uniqueness on `media_files` is already `(path, dataset_id)`, so keying the
  # OBJECT space on `dataset_id` makes key uniqueness mirror row uniqueness
  # exactly: one row, one object, by construction. `workspace_id` would leave
  # same-workspace cross-dataset sharing open at the identical cost.
  #
  # NO MIGRATION, and the reason is structural rather than optimistic: the prefix
  # is chosen at BIRTH and never rewritten. A row inserted flat keeps its flat key
  # and keeps resolving forever, because the read side reads `media_files.path`
  # verbatim and both backends take arbitrary depth (local.ex File.mkdir_p; s3.ex
  # `key_for/1` is a plain concat over an existing key_prefix). Mixed layouts are
  # therefore coherent permanently — no cutover, no flag day, no object moves, no
  # orphan risk, no in-flight window.
  #
  # AND THE PATH IS NEVER REWRITTEN AFTERWARDS, which is not a stylistic
  # preference: `media_files.path` is a PUBLISHED REFERENCE. Studio's upload
  # handler persists `"/media/files/\#{file.path}"` into a document's content
  # (live/studio/studio_live/handlers/media.ex), and `serve/2` resolves that URL
  # through `get_file_by_path/2` — a lookup keyed on the very string that was
  # persisted. Rewriting an existing row's path orphans every document already
  # pointing at it; pinned by
  # `test/barkpark/media_path_is_a_published_reference_test.exs`.
  #
  # A NULL `dataset_id` has no prefix to apply and stays flat: that is the legacy
  # / untenanted layer, untouched.
  #
  # PUBLIC so it has exactly ONE owner: any future write seam that needs to place
  # a blob calls this instead of restating the rule, and the flat (legacy) clause
  # is pinnable without a Default-project-free install.
  #
  # @canonical capability:tenant-blob-key aka:blob prefix,dataset key,media path prefix
  @spec blob_key(String.t(), String.t(), String.t() | nil) :: String.t()
  def blob_key(date_dir, filename, dataset_id) when is_binary(dataset_id),
    do: "d/#{dataset_id}/#{date_dir}/#{filename}"

  def blob_key(date_dir, filename, _no_dataset_id), do: "#{date_dir}/#{filename}"

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
  `Barkpark.Content.Scope.scope_to_workspace_or_global/3` — the function this
  actually calls. A get scoped to workspace B returns `{:error, :not_found}`
  for a blob owned by workspace A, and an empty scope from an HTTP conn
  (`:shared_only`, the `ScopeHelpers.scope_opts/1` sentinel) narrows to the
  shared `workspace_id IS NULL` layer, because the `_or_global` catch-all
  delegates to `scope_to_workspace/3`, which owns both of those arms.

  The `nil` arm is the one that differs and the reason the name matters: on
  `_or_global` a nil `:workspace_id` is an EXPLICIT global read (every tenant),
  NOT the fail-closed `where: false` of `scope_to_workspace/3`.

  Who can reach that nil arm, stated precisely — the sentinel covers LESS than
  its name suggests. `ScopeHelpers.scope_opts/1` picks its mode by carrier
  (scope_helpers.ex:62-68): a `%Plug.Conn{}` gets `:sentinel` and therefore
  `:shared_only`, but a `%Phoenix.LiveView.Socket{}` or `%Phoenix.Socket{}`
  gets `:legacy`, which OMITS the key entirely (:134). That exclusion is
  deliberate and documented there. So the nil arm is reachable by an internal
  caller that omits the key AND by a socket-borne read — never by an HTTP
  request. Do not clear a socket-reached path on the sentinel's guarantee.
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
    * `{:error, :unscoped_blob_write}` — `opts` carried no `:workspace_id`. There
      is no unscoped blob write; the caller must name the owning workspace.
    * `{:error, :blob_key_not_owned}` — a `media_files` row at this key belongs to
      a DIFFERENT workspace, or to none at all. The store is addressed by the very
      string `media_files.path` holds, so the tenant wall on THIS route — where
      the caller supplies the key — is OWNERSHIP of the key. Since
      task-918106d49c62563e a key BORN through `upload/3` also carries a
      `d/<dataset_id>/` prefix (see `blob_key/3`), so newly-written keys are
      tenant-disjoint by construction and this predicate is the guard on
      caller-supplied ones. It remains a WRITE-side predicate and structurally
      cannot close a read-side substitution; see `blob_key/3` for what does.
    * `{:error, :empty_body}` — a zero-byte body (422). No real media blob is
      empty; the common cause is a caller mislabeling the content-type (e.g.
      `application/json`), which lets `Plug.Parsers` consume the body before the
      controller reads it — refuse loudly instead of writing a 0-byte blob the
      serve path would then happily stream.
    * `{:error, :storage_unavailable}` — a disk fault on write (503).

  Non-raising file ops mirror `upload/3`: a read-only mount / ENOSPC returns a
  typed error, never a bare 500.
  """
  @spec put_blob(String.t(), binary(), keyword()) ::
          {:ok, String.t(), Blobstore.receipt()}
          | {:error,
             :invalid_path
             | :empty_body
             | :unscoped_blob_write
             | :blob_key_not_owned
             | :storage_unavailable
             | :not_stored
             | {:storage_mismatch, non_neg_integer(), non_neg_integer()}}
  def put_blob(relative_path, body, opts \\ [])

  def put_blob(_relative_path, "", _opts), do: {:error, :empty_body}

  def put_blob(relative_path, body, opts)
      when is_binary(relative_path) and is_binary(body) and is_list(opts) do
    with true <- valid_blob_path?(relative_path) or {:error, :invalid_path},
         :ok <- authorize_blob_key(relative_path, opts) do
      put_validated_blob(relative_path, body)
    else
      {:error, _reason} = error -> error
    end
  end

  # The blob keyspace is FLAT and instance-wide: `Blobstore` resolves an object
  # by the very string that `media_files.path` holds (serve/2 →
  # `Blobstore.serve_strategy(file.path)`, `delete_file/2` →
  # `Blobstore.delete(file.path)`). A key is therefore OWNED by whatever
  # workspace owns the `media_files` row(s) at that path, and the tenant wall on
  # THIS route — the one place a CALLER names the key — is ownership of it.
  #
  # CORRECTED (task-918106d49c62563e). This comment used to justify ownership over
  # a prefix by claiming a prefix "would change the layout of every object already
  # in the store, which the read side could not resolve without a data migration",
  # and that was read as ruling out prefixing altogether. It does not. The claim
  # holds only for REWRITING existing rows; `upload/3` now chooses a
  # `d/<dataset_id>/` key at BIRTH (`blob_key/3`), which moves no object, rewrites
  # no row and needs no migration — old flat rows keep flat keys and keep
  # resolving, permanently, and mixed layouts are coherent.
  #
  # What the original fear DOES correctly rule out is a rewrite, and for a sharper
  # reason than object layout: `media_files.path` is a PUBLISHED REFERENCE that
  # documents persist as a literal `/media/files/<path>` string, so rewriting a
  # row orphans every document pointing at it (pinned by
  # `test/barkpark/media_path_is_a_published_reference_test.exs`).
  #
  # FAIL CLOSED on three shapes:
  #   * no `:workspace_id` in opts → `:unscoped_blob_write`. There is exactly one
  #     production caller (MediaController.put_blob/2) and it always supplies one;
  #     an omission is a bug, never an "unscoped" licence.
  #   * a row at this key owned by a DIFFERENT workspace → `:blob_key_not_owned`.
  #     This is the cross-tenant overwrite.
  #   * a row at this key owned by NO workspace (`workspace_id IS NULL`) → also
  #     `:blob_key_not_owned`. `Content.Scope.scope_to_workspace_or_global/3`
  #     serves an unscoped row to EVERY tenant, so letting one workspace rewrite
  #     its bytes poisons an object every other tenant reads.
  #
  # A key NO row claims stays writable: that is the live contract of this route
  # (a bundle import COPIes the rows first and pushes the bytes after — see
  # `internal/cli/cloud_workspace_cmd.go` `importWorkspace` → `uploadWorkspaceBlobs`
  # — and `scripts/pds-scratch-target.sh` probes a bare path). Squatting an
  # unclaimed key is not a path to another tenant's data: both ways a workspace
  # acquires a key (`upload/3`'s `Blobstore.put_file`, or its own blob push)
  # write the bytes themselves, overwriting any squat.
  defp authorize_blob_key(relative_path, opts) do
    case Keyword.get(opts, :workspace_id) do
      workspace_id when is_binary(workspace_id) ->
        foreign? =
          MediaFile
          |> where([m], m.path == ^relative_path)
          |> where([m], is_nil(m.workspace_id) or m.workspace_id != ^workspace_id)
          |> Repo.exists?()

        if foreign?, do: {:error, :blob_key_not_owned}, else: :ok

      _ ->
        {:error, :unscoped_blob_write}
    end
  end

  # Reached only after `valid_blob_path?/1` AND `authorize_blob_key/2` passed.
  defp put_validated_blob(relative_path, body) do
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
  end

  @doc """
  True iff `relative_path` is a safe server-blob path: a non-empty relative path
  whose every `/`-segment matches `@blob_segment` (so `.`, `..`, an absolute
  leading `/`, a trailing `/`, and any `\\`/null/space shape all fail closed).

  Promoted from a private write-side check to a PUBLIC guard so the read/serve
  seam can enforce the same invariant (`Barkpark.Media.Blobstore`'s
  `serve_strategy`/`ensure_local`/`delete` reject a traversal-shaped `file.path`
  before it reaches `send_file`/`File.rm`). See `put_blob/2` for the write seam.
  """
  @spec valid_blob_path?(term()) :: boolean()
  def valid_blob_path?(relative_path) when is_binary(relative_path) do
    segments = String.split(relative_path, "/")

    relative_path != "" and
      not String.starts_with?(relative_path, "/") and
      Enum.all?(segments, &Regex.match?(@blob_segment, &1))
  end

  # A non-binary path (e.g. nil) is never a safe blob path — fail closed.
  def valid_blob_path?(_relative_path), do: false

  # Stamp tenancy scope (:workspace_id / :project_id) onto write attrs when the
  # caller supplied it via opts. Only non-nil keys are added, so an unscoped
  # upload leaves the attr map untouched — mirrors `Barkpark.Content.put_scope_attrs`.
  #
  # W2 dual-write: also resolve the blob's `dataset` STRING → its `dataset_id`
  # (within the resolved project — opts `:project_id` or the seeded Default
  # project) and stamp BOTH. The string stays as a mirror; `dataset_id` is the
  # new authoritative leaf for the (path, dataset_id) uniqueness.
  #
  # FAIL-CLOSED (felix-w27-bl-media-dataset-swallow-mirror): mirrors #12071's
  # `WriteScope` split in media's ATOM-key dialect. A dataset resolution the
  # Tenancy layer REFUSED is an error, never a silent `dataset_id=nil` stamp.
  # `:workspace_id`/`:project_id` are ALWAYS stamped from opts, independent of
  # dataset resolution, so a workspace-scoped upload whose project can't be
  # resolved still keeps its workspace stamp. Returns a tagged tuple threaded up
  # through `upload/3`:
  #
  #   * `{:ok, attrs}` — scope stamped (`dataset_id` present when resolved, absent
  #     on the legit-nil arms below).
  #   * `{:error, {:invalid_dataset, details}}` — `get_or_create_dataset` rejected
  #     the slug (format/length). 422 `validation_failed`; the changeset messages
  #     are re-keyed under "dataset" (the key the caller sent — the row's `:slug`
  #     is an internal name). Replaces the old silent degrade to `dataset_id=NULL`.
  #   * `{:error, :conflict}` — the insert-ok/reload-nil race (`:dataset_not_found`
  #     twice). 409. errors.ex has NO `:dataset_not_found` clause, so converting it
  #     here is load-bearing: an unconverted `:dataset_not_found` would fall to
  #     `upload/3`'s 503 storage catch-all and mislabel.
  defp put_scope_attrs(attrs, opts) do
    project_id = Keyword.get(opts, :project_id) || default_project_id()

    scoped =
      attrs
      |> maybe_put_scope_attr(:workspace_id, Keyword.get(opts, :workspace_id))
      |> maybe_put_scope_attr(:project_id, Keyword.get(opts, :project_id))

    case resolve_dataset_id(scoped, project_id) do
      {:ok, nil} -> {:ok, scoped}
      {:ok, dataset_id} -> {:ok, Map.put(scoped, :dataset_id, dataset_id)}
      {:error, _reason} = error -> error
    end
  end

  defp default_project_id do
    case Barkpark.Tenancy.get_default_project() do
      %{id: id} -> id
      _ -> nil
    end
  end

  # TOTAL split of the dataset resolution (mirrors
  # `WriteScope.resolve_dataset_id_for_write`). `nil` arises at THREE sites; only
  # the `get_or_create_dataset` error is a DEFECT that must fail closed:
  #
  #   * nil resolved project (incl. the Default-project fallback) — legit
  #     input-absent → `{:ok, nil}`.
  #   * non-binary dataset — legit; currently DEAD from the `is_binary(dataset)`
  #     caller guard at `upload/3`, kept defensively → `{:ok, nil}`.
  #   * `get_or_create_dataset` refused the slug — DEFECT, fail closed →
  #     `{:error, {:invalid_dataset, _}}` / `{:error, :conflict}`.
  defp resolve_dataset_id(_attrs, nil), do: {:ok, nil}

  defp resolve_dataset_id(attrs, project_id) do
    case Map.get(attrs, :dataset) || Map.get(attrs, "dataset") do
      dataset when is_binary(dataset) ->
        resolve_dataset_id_with_retry(project_id, dataset)

      _ ->
        {:ok, nil}
    end
  end

  # Retry exactly once on the insert-ok/reload-nil race, then `{:error, :conflict}`
  # (mirrors `WriteScope.resolve_dataset_id_with_retry`).
  defp resolve_dataset_id_with_retry(project_id, dataset) do
    case resolve_dataset_id_once(project_id, dataset) do
      {:error, :dataset_not_found} ->
        case resolve_dataset_id_once(project_id, dataset) do
          {:error, :dataset_not_found} -> {:error, :conflict}
          other -> other
        end

      other ->
        other
    end
  end

  defp resolve_dataset_id_once(project_id, dataset) do
    case Barkpark.Tenancy.get_or_create_dataset(project_id, dataset) do
      {:ok, %Barkpark.Tenancy.Dataset{id: id}} ->
        {:ok, id}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:invalid_dataset, invalid_dataset_details(changeset)}}

      {:error, :dataset_not_found} ->
        {:error, :dataset_not_found}
    end
  end

  # Flatten the Dataset changeset's per-field messages and RE-KEY them under the
  # STRING "dataset" — the caller supplied a `dataset` string, not a `:slug`
  # field. `Content.Errors.to_envelope` passes `details` through VERBATIM, so the
  # re-key is the caller's job (mirrors `WriteScope.invalid_dataset_details/1`).
  defp invalid_dataset_details(%Ecto.Changeset{} = changeset) do
    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)
      |> Enum.flat_map(fn {_field, msgs} -> msgs end)

    %{"dataset" => messages}
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
