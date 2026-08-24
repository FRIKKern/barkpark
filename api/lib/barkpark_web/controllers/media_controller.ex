defmodule BarkparkWeb.MediaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.{Blobstore, Delivery, Renditions}
  alias Barkpark.Media.Storage.{Access, MediaFile}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  # ── Unscoped-read confinement (task-2e4a3692adf5c565) ───────────────────────
  #
  # `AssignDefaultScope` passes the conn through UNTOUCHED when nothing is
  # seeded at slug "default" (its own moduledoc says so — it never halts), so
  # `scope_opts/1` emits no `:workspace_id`, and the `Media` read helpers hand
  # that nil to `Content.Scope.scope_to_workspace_or_global/3`, whose nil arm
  # returns the query UNTOUCHED. Every flat read below then answered from EVERY
  # tenant's rows, to an anonymous caller. Reachable in one admin call:
  # `DELETE /api/workspaces/default` has no guard against removing the seeded
  # Default, and `Seeds.Shared.ensure_default_scope/0` runs only from mix seeds,
  # never at boot — so the absence is permanent once taken.
  #
  # THE RULE: an unscoped caller may see only the SHARED/GLOBAL layer
  # (`workspace_id IS NULL`) — never another tenant's rows. Deliberately a
  # per-ROW rule rather than a blanket refusal, because only a per-row rule does
  # both jobs at once: a legacy single-tenant install (every row NULL) keeps
  # serving everything unchanged, while a multi-tenant install with a missing
  # Default refuses foreign rows. `scope_to_workspace_including_global/3`
  # (content/scope.ex:178) already expresses the same distinction query-side.
  #
  # Applied HERE and not inside `Media`, deliberately: `Media.list_files/1`
  # (plugins/media/assets.ex:205), `Media.get_file_by_path/2` (preview.ex:120)
  # and the unscoped reads in media_test.exs are legitimate internal global
  # callers, so narrowing the shared helper would change behaviour well outside
  # this route family. Making an empty scope fail CLOSED at the Content/Media
  # boundary — which would retire this whole fail-open class rather than its
  # third instance — is filed separately.
  #
  # RESIDUAL, stated rather than left implicit: a NEW flat read action added to
  # this controller fails open again until that boundary work lands. Route any
  # new read through `confine_one/2` or `confine_many/2`.
  defp scope_bound?(opts), do: not is_nil(Keyword.get(opts, :workspace_id))

  defp confine_one(opts, %MediaFile{} = file) do
    if scope_bound?(opts) or is_nil(file.workspace_id),
      do: {:ok, file},
      else: {:error, :not_found}
  end

  defp confine_many(opts, files) do
    if scope_bound?(opts), do: files, else: Enum.filter(files, &is_nil(&1.workspace_id))
  end

  @doc "Upload a file via multipart form data."
  def upload(conn, %{"file" => upload}) do
    dataset = Map.get(conn.params, "dataset", "production")

    case Media.upload(upload, dataset, scope_opts(conn)) do
      {:ok, file} ->
        conn
        |> put_status(:created)
        |> json(render_file(file, conn))

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def upload(conn, _params) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "missing 'file' field in multipart upload")

    conn
    |> put_status(:bad_request)
    |> json(%{error: Map.delete(env, :status)})
  end

  @doc """
  List all media files.

  `dataset` is QUERY-STRING sourced here — the scoped `/w/:ws/p/:proj/media`
  routes carry no `:dataset` path segment. `RequireShareScope.request_dataset/1`
  resolves it the same way, so a `:media` share is checked against the dataset
  this action actually lists; before task-4f26838232b5ece0 the guard compared
  `"production"` while `?dataset=` listed another dataset's library.
  """
  def index(conn, params) do
    dataset = Map.get(params, "dataset", "production")
    mime_filter = Map.get(params, "type")
    opts = scope_opts(conn)

    files =
      dataset
      |> Media.list_files([mime_type: mime_filter] ++ opts)
      |> then(&confine_many(opts, &1))

    json(conn, %{
      files: Enum.map(files, &render_file(&1, conn)),
      count: length(files)
    })
  end

  @doc """
  Get a single media file metadata.

  Gated by `Access.allowed?/4` at `:view`, mirroring `serve/2` (`:original`)
  and `serve_rendition/2` (`:preview`) — without it an anonymous caller could
  read a private asset's filename/path/size here while being refused the bytes
  (the felix W14 field-visibility leak). Fails CLOSED: private + anonymous → 403.
  """
  def show(conn, %{"id" => id}) do
    opts = scope_opts(conn)

    with {:ok, file} <- Media.get_file(id, opts),
         {:ok, file} <- confine_one(opts, file),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :view) do
      json(conn, render_file(file, conn))
    else
      {:error, :not_found} ->
        not_found(conn, "file not found")

      false ->
        forbidden(conn)
    end
  end

  @doc "Serve a file — from disk, or via redirect to the object-storage backend."
  def serve(conn, %{"path" => path_parts}) do
    relative_path = Enum.join(path_parts, "/")
    opts = scope_opts(conn)

    with {:ok, file} <- Media.get_file_by_path(relative_path, opts),
         {:ok, file} <- confine_one(opts, file),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :original) do
      # Serve the path off the RESOLVED record, not the raw URL segment. The
      # lookup already matched on `path == relative_path`, but deriving the blob
      # key from `file.path` (a server-generated `uploads/YYYY/MM/slug-rand.ext`
      # — `Media.unique_filename/1` strips directory parts and non-`[a-z0-9-]`) —
      # instead of the attacker-typed segment removes any raw-input flow into
      # `send_file` / the presigned key. A `../…` URL never matches a stored row
      # → {:error, :not_found}.
      mime = MIME.from_path(file.path)

      # The stored-XSS defense travels with the strategy: the LOCAL branch sets
      # collapse/nosniff/disposition headers itself (maybe_send_file), and the
      # REDIRECT branch bakes the SAME collapsed type + disposition into the
      # presigned query (response-content-*) so the bucket echoes them.
      case Blobstore.serve_strategy(file.path,
             response_content_type: MediaFile.serve_content_type(mime),
             response_content_disposition: disposition(mime)
           ) do
        {:file, full_path} ->
          conn
          |> Delivery.put_file_cache_headers(full_path, Access.visibility(doc))
          |> maybe_send_file(full_path, mime)

        {:redirect, url} ->
          redirect_to_blob(conn, url)

        # HONEST missing-blob 404: a media_files ROW can outlive its blob — most
        # notably right after a workspace bundle import copies the DB rows but the
        # blobs have not been re-pointed/pushed yet (pds W1 G2). Without this guard
        # send_file's internal `{:ok, %File.Stat{}} = File.stat(path)` raises a
        # MatchError on :enoent → a bare 500. Answer a truthful 404 instead.
        {:error, :not_found} ->
          not_found(conn, "media blob missing")
      end
    else
      {:error, :not_found} ->
        not_found(conn, "file not found")

      false ->
        forbidden(conn)
    end
  end

  @doc """
  Serve a cached or on-demand rendition preset.

  Scoped lookup (tsk-url-p0): this was the ONE media action passing no
  scope_opts — an unscoped `get_file/1` served any workspace's renditions
  by id on the flat URL (the cross-scope leak the router comment over the
  scoped-media block calls out). The flat pipeline's AssignDefaultScope
  pins this to the Default workspace; non-Default renditions become
  reachable only via the scoped route (P4) or an item share link.
  """
  def serve_rendition(conn, %{"id" => id, "preset" => preset}) do
    opts = scope_opts(conn)

    with {:ok, file} <- Media.get_file(id, opts),
         {:ok, file} <- confine_one(opts, file),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :preview),
         watermark = Access.watermark_profile(doc),
         {:ok, relative} <- Renditions.ensure(file, preset, watermark: watermark) do
      full_path = Media.file_path(relative)
      mime = MIME.from_path(full_path)

      conn
      |> Delivery.put_file_cache_headers(full_path, Access.visibility(doc))
      |> maybe_send_file(full_path, mime)
    else
      {:error, :not_found} ->
        not_found(conn, "file not found")

      false ->
        forbidden(conn)

      {:error, :unknown_preset} ->
        not_found(conn, "unknown rendition preset")

      {:error, _} ->
        not_found(conn, "rendition unavailable")
    end
  end

  defp maybe_send_file(%Plug.Conn{state: :sent} = conn, _path, _mime), do: conn

  # Serve blobs defensively — these bytes can be written by an outsider-held key
  # and the default asset visibility is public:
  #   * `nosniff` pins the server-declared content-type (no browser MIME sniffing
  #     upgrading an octet-stream back to an executable type).
  #   * dangerous types (svg/html/xml/js) are collapsed to a non-executable
  #     `application/octet-stream` AND served `attachment`, so a browser that
  #     navigates to the blob downloads it instead of executing script on the
  #     API/Studio origin (the stored-XSS vector).
  #   * safe types (images, pdf, …) keep their honest type and serve `inline`
  #     so Studio previews still work.
  #
  # @sobelow_skip — both findings on this function are accepted false-positives:
  #   * Traversal.SendFile (send_file/3): `full_path` is ALWAYS derived from a
  #     server-owned relative path — either a DB-resolved `file.path` (media
  #     `serve/2`, sanitized at write by `Media.unique_filename/1`) or a
  #     `Renditions.ensure/3` output (server-generated, `serve_rendition/2`).
  #     No caller passes a raw request segment; a `../…` URL never resolves a row.
  #   * XSS.ContentType (put_resp_content_type/2): the type is pinned through
  #     `MediaFile.serve_content_type/1` (dangerous svg/html/xml/js collapse to a
  #     non-executable octet-stream) AND paired with `nosniff` + an `attachment`
  #     disposition for dangerous types — the stored-XSS vector is defused here.
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  defp maybe_send_file(conn, full_path, mime) do
    conn
    |> put_resp_content_type(MediaFile.serve_content_type(mime))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-disposition", disposition(mime))
    |> send_file(200, full_path)
  end

  defp disposition(mime) do
    if MediaFile.dangerous_mime?(mime), do: "attachment", else: "inline"
  end

  # 302 to a presigned object-storage URL. `cache-control: private` — the
  # redirect embeds a time-limited signature and may be access-gated, so a
  # shared cache must never serve it to another principal; the blob response
  # itself carries the bucket/CDN cache policy.
  defp redirect_to_blob(conn, url) do
    conn
    |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
    |> redirect(external: url)
  end

  defp not_found(conn, message) do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn
    |> put_status(:not_found)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp forbidden(conn) do
    env =
      {:error, :forbidden}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "access denied")

    conn
    |> put_status(:forbidden)
    |> json(%{error: Map.delete(env, :status)})
  end

  @doc """
  Push a raw blob to this instance at a validated relative path (pds W1 G2).

  Admin-gated (the `:require_admin` pipeline). The cross-instance blob-transfer
  primitive: a workspace bundle import on a TARGET instance copies the source's
  DB rows, then pushes each source blob here by its server-generated relative
  path so `serve/2` (which derives the disk path from the row's `path`) finds
  the bytes. The body is written VERBATIM — no re-encode, no MIME inspection.

  Path safety is enforced by `Media.put_blob/3`'s strict allowlist (each
  `/`-segment must match the server-blob shape; `.`/`..`/absolute/empty
  rejected), so a traversal or malformed path is refused with 422 BEFORE any
  byte touches disk. This is a bare infra route — deliberately NOT in the
  capabilities manifest.

  TENANCY. `:workspace_slug` is BINDING, not decoration. It used to be dropped
  on the floor — the head matched only `%{"path" => path_parts}` — while the
  router's `:require_admin` pipeline checks a workspace-BLIND global permission
  (`Auth.has_permission?(token, "admin")`). Any admin token could therefore
  write arbitrary bytes at any key in the instance-wide blob store, including
  over another tenant's objects. Two halves close it, and neither alone is
  sufficient:

    * the caller is bound to the named workspace with `TenancyAuth.member?/2` —
      the same predicate `WorkspaceController` uses on `create_project`,
      `projects` and `datasets`. An unknown slug and a non-member both collapse
      to 404, the no-existence-leak convention that family already follows.
    * the KEY is bound to the workspace by `Media.put_blob/3` — a legitimate
      admin of workspace B naming B in the URL still cannot address a key
      workspace A owns.

  The authorize half runs BEFORE `read_full_body/1`, so an unauthorized caller
  is refused without this node buffering up to 100 MB of its body.
  """
  def put_blob(conn, %{"workspace_slug" => slug, "path" => path_parts}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id) do
      write_blob(conn, Enum.join(path_parts, "/"), workspace)
    else
      # Unknown slug OR a real workspace the caller is not a member of — never
      # confirm a workspace exists to a non-member.
      _ -> not_found(conn, "workspace not found")
    end
  end

  defp write_blob(conn, relative_path, workspace) do
    case read_full_body(conn) do
      {:ok, body, conn} ->
        case Media.put_blob(relative_path, body, workspace_id: workspace.id) do
          {:ok, written, receipt} ->
            conn
            |> put_status(:ok)
            |> json(
              %{
                # `written` is the legacy key and carries the PATH, not a count
                # — `path` is its honest name; both are emitted so the existing
                # CLI keeps working.
                written: written,
                path: written,
                # RECEIVED. The CLI compares its sent size against this key, so
                # it keeps meaning exactly what it always meant.
                bytes: byte_size(body)
              }
              |> Map.merge(receipt_json(receipt))
            )

          {:error, :not_stored} ->
            readback_failure(
              conn,
              "blob_not_stored",
              "the store accepted the write and a read-back then found no object at that path"
            )

          {:error, {:storage_mismatch, received, stored}} ->
            readback_failure(
              conn,
              "blob_storage_mismatch",
              "received #{received} bytes but the store holds #{stored}"
            )

          {:error, :invalid_path} ->
            unprocessable(conn, "invalid_path", "invalid blob path")

          # The key is claimed by a different workspace (or by an unscoped row
          # every tenant reads). 404, not 403: a 403 would confirm to workspace
          # B that some OTHER tenant holds an object at exactly that path.
          {:error, :blob_key_not_owned} ->
            not_found(conn, "blob path not found in this workspace")

          # Unreachable from HTTP — this action always supplies the resolved
          # workspace. Kept explicit so a future caller that forgets gets an
          # honest 5xx instead of falling through to the storage catch-all and
          # being mislabeled a disk fault.
          {:error, :unscoped_blob_write} ->
            {:error, :storage_unavailable}

          {:error, :empty_body} ->
            # A zero-byte blob is never legitimate media. The common cause is a
            # mislabeled content-type (e.g. application/json) letting
            # Plug.Parsers consume the body before this controller reads it —
            # refuse loudly instead of writing an empty file serve/2 would
            # then happily stream.
            unprocessable(
              conn,
              "empty_body",
              "empty blob body — send the raw bytes as application/octet-stream"
            )

          {:error, :storage_unavailable} ->
            {:error, :storage_unavailable}
        end

      {:error, :too_large, conn} ->
        env =
          {:error, :payload_too_large}
          |> Errors.to_envelope(conn)
          |> Map.put(:message, "blob exceeds the maximum allowed size")

        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: Map.delete(env, :status)})
    end
  end

  # Read the whole request body in one call (the endpoint caps the body at 100 MB
  # via Plug.Parsers `length:`, and the blob-push content-type is a pass-through
  # `application/octet-stream` the parsers leave unread). A body that still spills
  # past `:read_length` returns `{:more, ...}` → an honest 413 rather than a
  # silently truncated blob.
  defp read_full_body(conn) do
    case Plug.Conn.read_body(conn, length: 100_000_000, read_length: 100_000_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
    end
  end

  # The storage claim, rendered so the two numbers can never be read as one:
  # `bytes` (above) is what this instance RECEIVED; `stored` is what a
  # post-condition read of the store found. `stored` degrades to the string
  # "unverified" with a NAMED reason — never to a copy of the received count.
  defp receipt_json(%{stored: :unverified, unverified_reason: reason}) do
    %{stored: "unverified", verified_by: nil, unverified_reason: format_reason(reason)}
  end

  defp receipt_json(%{stored: stored, verified_by: verified_by}) do
    %{stored: stored, verified_by: to_string(verified_by), unverified_reason: nil}
  end

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  # A read-back that proves the bytes are absent (or disagrees about their
  # size) is a FAILED transfer at the storage edge, not a 200 carrying a
  # discrepancy field. 502: this instance is honest about a store below it that
  # was not.
  defp readback_failure(conn, code, message) do
    env = Errors.stamp(%{code: code, message: message, status: 502}, conn)

    conn
    |> put_status(:bad_gateway)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp unprocessable(conn, code, message) do
    # No canonical `:unprocessable` atom exists in Errors; build the 422 envelope
    # directly and stamp it so it still carries hint + request_id like every
    # other error on this surface.
    env =
      %{code: code, message: message, status: 422}
      |> Errors.stamp(conn)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Map.delete(env, :status)})
  end

  @doc "Delete a media file."
  def delete(conn, %{"id" => id}) do
    # RECEIPT LAW (pds w39): `Media.delete_file/2` returns the row `Repo.delete/2`
    # removed (media.ex:425-452). This used to discard it and echo the `:id` path
    # param; `filename` is stored state the request never carries, so reverting
    # to the echo reds the differential.
    with {:ok, deleted} <- Media.delete_file(id, scope_opts(conn)) do
      json(conn, %{deleted: deleted.id, filename: deleted.filename, dataset: deleted.dataset})
    end
  end

  # `dataset` here selects which dataset's asset doc is looked up for the
  # `assetDocId` field, and it is QUERY-STRING sourced on the dataset-less
  # scoped media routes — so `show/2` reads it too, not just `index/2`.
  # `RequireShareScope.request_dataset/1` is aligned to this read
  # (task-4f26838232b5ece0).
  defp render_file(file, conn) do
    dataset = Map.get(conn.params, "dataset", file.dataset)

    base = %{
      id: file.id,
      filename: file.filename,
      originalName: file.original_name,
      path: file.path,
      url: "/media/files/#{file.path}",
      mimeType: file.mime_type,
      size: file.size,
      createdAt: file.inserted_at
    }

    case Barkpark.Plugins.Registry.asset_doc_id_for_media_file(file.id, dataset) do
      nil -> base
      asset_doc_id -> Map.put(base, :assetDocId, asset_doc_id)
    end
  end
end
