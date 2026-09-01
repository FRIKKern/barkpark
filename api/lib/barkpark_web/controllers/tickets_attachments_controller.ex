defmodule BarkparkWeb.TicketsAttachmentsController do
  @moduledoc """
  Ticket-scoped attachment upload + retrieval — the outsider-media trust boundary.

  Ticket keys NEVER touch `/media` routes (charter Decision 4). Every attachment
  rides these endpoints, which enforce the MANDATORY allowlist / magic-byte MIME
  / size + count caps in `Barkpark.Plugins.Tickets.Attachments`, and scope both
  upload and retrieval to the ticket the presented key OWNS.

  Routes (declared in the sibling-owned `tickets.ex`):

    * `POST /v1/tickets/:id/attachments`               → `:create`  (submitter key)
    * `GET  /v1/tickets/:id/attachments/:asset_id`     → `:show`    (submitter key)
    * `GET  /v1/tickets/inbox/:id/attachments/:asset_id` → `:show_operator` (operator token)

  A foreign ticket or a foreign attachment always returns **404** — never 403 —
  so the surface never leaks the existence of another key's ticket or asset.

  `:create` is submitter-only in v1 (the outsider files; the operator answers in
  text). Both read paths stream the raw bytes back to an authorized caller only.
  """

  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Content
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Tickets.Attachments

  action_fallback BarkparkWeb.FallbackController

  @ticket_type "ticket"

  # ───────────────────────────────── create ─────────────────────────────────

  @doc "Upload one attachment to a ticket the presenting key owns (multipart)."
  def create(conn, %{"id" => id, "file" => %Plug.Upload{} = upload}) do
    with {:ok, key} <- require_ticket_key(conn),
         {:ok, _ticket} <- owned_ticket(id, key),
         :ok <- check_count(id, key),
         {:ok, binary} <- read_upload(upload),
         {:ok, mime} <-
           Attachments.validate(binary,
             filename: upload.filename,
             content_type: upload.content_type
           ),
         {:ok, ref} <- store_attachment(binary, id, key, mime, upload.filename) do
      conn
      |> put_status(:created)
      |> json(%{attachment: ref})
    else
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  # Authenticated but no file part → honest 400 (mirrors MediaController).
  def create(conn, %{"id" => id}) do
    case require_ticket_key(conn) do
      {:ok, key} ->
        case owned_ticket(id, key) do
          {:ok, _} -> respond_error(conn, :malformed_no_file)
          {:error, reason} -> respond_error(conn, reason)
        end

      {:error, reason} ->
        respond_error(conn, reason)
    end
  end

  # ────────────────────────────── show (submitter) ──────────────────────────

  @doc "Stream an attachment back to the owning key."
  def show(conn, %{"id" => id, "asset_id" => asset_id}) do
    with {:ok, key} <- require_ticket_key(conn),
         {:ok, _ticket} <- owned_ticket(id, key),
         {:ok, file} <-
           Attachments.linked_asset(asset_id, id, key_dataset(key), key_scope(key)) do
      stream_file(conn, file)
    else
      {:error, :unauthorized} -> respond_error(conn, :unauthorized)
      _ -> respond_error(conn, :not_found)
    end
  end

  # ────────────────────────────── show (operator) ───────────────────────────

  @doc "Stream an attachment back to an operator token holder."
  def show_operator(conn, %{"id" => id, "asset_id" => asset_id}) do
    dataset = operator_dataset(conn)
    scope = operator_scope(conn)

    with {:ok, _tok} <- require_operator(conn),
         {:ok, _ticket} <- operator_ticket(id, dataset, scope),
         {:ok, file} <- Attachments.linked_asset(asset_id, id, dataset, scope) do
      stream_file(conn, file)
    else
      {:error, :unauthorized} -> respond_error(conn, :unauthorized)
      _ -> respond_error(conn, :not_found)
    end
  end

  # ─────────────────────────────── auth helpers ─────────────────────────────

  # The RequireTicketKey plug (sibling-owned) assigns the verified key here. In a
  # worktree without that plug, tests assign the key struct/map directly.
  defp require_ticket_key(conn) do
    case conn.assigns[:ticket_key] do
      nil -> {:error, :unauthorized}
      key -> {:ok, key}
    end
  end

  # The `:token_root` pipeline assigns a verified operator token as `:api_token`.
  defp require_operator(conn) do
    case conn.assigns[:api_token] do
      nil -> {:error, :unauthorized}
      tok -> {:ok, tok}
    end
  end

  # ───────────────────────── ticket ownership / scope ───────────────────────

  # A ticket is OWNED when its embedded `key_id` matches the presenting key.
  # Missing ticket OR foreign owner → not_found (never leak existence / 403).
  defp owned_ticket(id, key) do
    case Content.get_document(id, @ticket_type, key_dataset(key), key_scope(key)) do
      {:ok, %{content: content} = ticket} when is_map(content) ->
        if to_string(Map.get(content, "key_id")) == to_string(key_id(key)) do
          {:ok, ticket}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # An operator may read any ticket that exists in their scope.
  defp operator_ticket(id, dataset, scope) do
    case Content.get_document(id, @ticket_type, dataset, scope) do
      {:ok, ticket} -> {:ok, ticket}
      _ -> {:error, :not_found}
    end
  end

  defp check_count(id, key) do
    Attachments.validate_count(Attachments.count_for_ticket(id, key_dataset(key), key_scope(key)))
  end

  defp store_attachment(binary, id, key, mime, filename) do
    Attachments.store(binary,
      mime: mime,
      filename: filename,
      ticket_id: id,
      key_id: to_string(key_id(key)),
      dataset: key_dataset(key),
      scope: key_scope(key)
    )
  end

  # ─────────────────────────── key/token field access ───────────────────────

  # The ticket-key struct is sibling-owned; read fields tolerantly (struct/map,
  # atom or string keys) so this controller does not hard-depend on its shape.
  defp key_id(key), do: key_field(key, :id)

  defp key_dataset(key), do: key_field(key, :dataset) || "production"

  defp key_scope(key) do
    []
    |> put_opt(:workspace_id, key_field(key, :workspace_id))
    |> put_opt(:project_id, key_field(key, :project_id))
  end

  defp key_field(key, field) when is_atom(field) do
    Map.get(key, field) || Map.get(key, Atom.to_string(field))
  end

  defp put_opt(opts, _k, nil), do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  # Operator scope is resolved from the conn assigns the token pipeline set
  # (ResolveWorkspace / ResolveProject), mirroring MediaController.scope_opts/1.
  defp operator_dataset(conn), do: Map.get(conn.params, "dataset", "production")

  defp operator_scope(conn) do
    []
    |> put_scope_assign(:workspace_id, conn.assigns[:current_workspace])
    |> put_scope_assign(:project_id, conn.assigns[:current_project])
  end

  defp put_scope_assign(opts, _k, nil), do: opts
  defp put_scope_assign(opts, k, %{id: id}), do: Keyword.put(opts, k, id)
  defp put_scope_assign(opts, _k, _other), do: opts

  # ─────────────────────────────── file streaming ───────────────────────────

  # These bytes were uploaded by an outsider-held key, so serve them defensively:
  # `nosniff` pins the server-derived MIME (no browser content-sniffing), dangerous
  # types (svg/html/xml/js) are collapsed to a non-executable octet-stream and
  # forced to `attachment` — nosniff alone does NOT stop a browser executing an
  # *honestly* declared `image/svg+xml`. Safe types keep an `inline` disposition
  # with the (sanitized) original name so images stay viewable in Studio. Names
  # that don't survive the ASCII-safe check are served without one rather than
  # risking header games.
  #
  # @sobelow_skip — both findings on this function are accepted false-positives:
  #   * Traversal.SendFile (send_file/3): `file` is resolved by
  #     `Attachments.linked_asset/4`, which only returns a blob STAMPED to the
  #     ticket the presented key owns; its `.path` is a server-generated
  #     `uploads/YYYY/MM/slug-rand.ext` (`Media.upload/3` → `unique_filename/1`
  #     strips directory parts). No request-controlled path reaches `send_file`.
  #   * XSS.ContentType (put_resp_content_type/2): pinned through
  #     `MediaFile.serve_content_type/1` + `nosniff` + an `attachment` disposition
  #     for dangerous types — an outsider-uploaded text/html cannot execute.
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  defp stream_file(conn, file) do
    mime = file.mime_type || MIME.from_path(file.path)

    # The redirect branch (object-storage backend) bakes the same collapsed
    # type + disposition into the presigned query (response-content-*), so a
    # bucket-served attachment carries the identical stored-XSS headers the
    # local send_file path sets below.
    # ROW-ADDRESSED (task-8eb6542ece62aff1) — the outsider-held ticket key is a
    # principal for ONE stamped blob row; resolve that row's own object, never a
    # colliding flat path's. Same seal as MediaController.serve/2.
    case Barkpark.Media.Blobstore.serve_strategy(file,
           response_content_type: MediaFile.serve_content_type(mime),
           response_content_disposition: disposition(file, mime)
         ) do
      {:file, full} ->
        conn
        |> put_resp_content_type(MediaFile.serve_content_type(mime))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", disposition(file, mime))
        |> send_file(200, full)

      {:redirect, url} ->
        conn
        |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
        |> redirect(external: url)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "attachment blob missing"}})
    end
  end

  # Dangerous types download rather than render; everything else stays inline with
  # the sanitized original name (or a bare `inline` when the name isn't ASCII-safe).
  defp disposition(file, mime) do
    if is_binary(mime) and MediaFile.dangerous_mime?(mime) do
      "attachment"
    else
      case safe_filename(file.original_name || file.filename) do
        nil -> "inline"
        name -> ~s(inline; filename="#{name}")
      end
    end
  end

  defp safe_filename(name) when is_binary(name) do
    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9 ._()-]{0,127}\z/, do: name, else: nil
  end

  defp safe_filename(_), do: nil

  # Read the multipart temp file, refusing an oversize blob WITHOUT reading it
  # into memory first (stat-then-read).
  #
  # @sobelow_skip — Traversal.FileModule (File.read/1) is a false-positive: `path`
  # is the `%Plug.Upload{}.path` that Plug.Parsers created (a random temp file
  # under the multipart upload dir), NOT any client-supplied name. The attacker
  # controls the file BYTES and the separate `.filename` field, never this path.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_upload(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        if size > Attachments.max_bytes() do
          {:error, :too_large}
        else
          case File.read(path) do
            {:ok, bin} -> {:ok, bin}
            {:error, _} -> {:error, :storage_unavailable}
          end
        end

      {:ok, _} ->
        # Empty file — no magic bytes to sniff → not an allowed type.
        {:error, :mime_not_allowed}

      {:error, _} ->
        {:error, :storage_unavailable}
    end
  end

  # ────────────────────────────── error envelopes ───────────────────────────

  # Reuse the canonical envelope (code/message/status/hint/request_id) for the
  # reasons Content.Errors already knows; build the ticket-tier-specific ones
  # (413 oversize, 422 mime/count, 400 no-file) inline in the same shape.
  defp respond_error(conn, :not_found), do: enveloped(conn, {:error, :not_found})
  defp respond_error(conn, :unauthorized), do: enveloped(conn, {:error, :unauthorized})

  defp respond_error(conn, :storage_unavailable),
    do: enveloped(conn, {:error, :storage_unavailable})

  defp respond_error(conn, :too_large) do
    custom(conn, 413, "payload_too_large", "attachment exceeds the per-file size limit", %{
      reason: "too_large",
      max_bytes: Attachments.max_bytes()
    })
  end

  defp respond_error(conn, :mime_spoofed) do
    custom(
      conn,
      422,
      "validation_failed",
      "attachment content does not match its declared type",
      %{
        reason: "mime_spoofed"
      }
    )
  end

  defp respond_error(conn, :mime_not_allowed) do
    custom(conn, 422, "validation_failed", "attachment type is not allowed", %{
      reason: "mime_not_allowed",
      allowed: Attachments.allowlist()
    })
  end

  defp respond_error(conn, :too_many_attachments) do
    custom(
      conn,
      422,
      "validation_failed",
      "ticket already has the maximum of #{Attachments.max_attachments()} attachments",
      %{reason: "too_many_attachments", max: Attachments.max_attachments()}
    )
  end

  defp respond_error(conn, :malformed_no_file) do
    custom(conn, 400, "malformed", "missing 'file' field in multipart upload", %{})
  end

  # Fallback: any unmapped reason is a server-side surprise, not a client 4xx.
  defp respond_error(conn, _reason), do: enveloped(conn, {:error, :storage_unavailable})

  # Both route through the ONE shared emitter → code + hint + request_id are
  # stamped by Content.Errors. `custom/5`'s inline request_id fork (Logger-only,
  # missing the x-request-id fallback) is retired here.
  defp enveloped(conn, error), do: BarkparkWeb.ErrorResponse.emit(conn, error)

  defp custom(conn, status, code, message, details),
    do: BarkparkWeb.ErrorResponse.emit_custom(conn, status, code, message, details)
end
