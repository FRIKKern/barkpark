defmodule BarkparkWeb.MediaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.{Blobstore, Delivery, Renditions}
  alias Barkpark.Media.Storage.{Access, MediaFile}

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

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

  @doc "List all media files."
  def index(conn, params) do
    dataset = Map.get(params, "dataset", "production")
    mime_filter = Map.get(params, "type")
    files = Media.list_files(dataset, [mime_type: mime_filter] ++ scope_opts(conn))

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
    with {:ok, file} <- Media.get_file(id, scope_opts(conn)),
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

    with {:ok, file} <- Media.get_file_by_path(relative_path, scope_opts(conn)),
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
          |> Delivery.put_file_cache_headers(full_path)
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
    with {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :preview),
         watermark = Access.watermark_profile(doc),
         {:ok, relative} <- Renditions.ensure(file, preset, watermark: watermark) do
      full_path = Media.file_path(relative)
      mime = MIME.from_path(full_path)

      conn
      |> Delivery.put_file_cache_headers(full_path)
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

  Path safety is enforced by `Media.put_blob/2`'s strict allowlist (each
  `/`-segment must match the server-blob shape; `.`/`..`/absolute/empty
  rejected), so a traversal or malformed path is refused with 422 BEFORE any
  byte touches disk. This is a bare infra route — deliberately NOT in the
  capabilities manifest.
  """
  def put_blob(conn, %{"path" => path_parts}) do
    relative_path = Enum.join(path_parts, "/")

    case read_full_body(conn) do
      {:ok, body, conn} ->
        case Media.put_blob(relative_path, body) do
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
    with {:ok, _} <- Media.delete_file(id, scope_opts(conn)) do
      json(conn, %{deleted: id})
    end
  end

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
