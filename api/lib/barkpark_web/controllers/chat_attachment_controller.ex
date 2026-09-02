defmodule BarkparkWeb.ChatAttachmentController do
  @moduledoc """
  Chat-owned attachment upload and read under `/v1/chat` (charter D16/D6,
  `ct-bl-chat-attachments`).

  ## The boundary this exists to hold

  Attachments must not ride the media plugin. `GET /media/files/*` is
  any-token-public by design — a plain data-plane bearer, and under a media share
  scope even an anonymous caller, reads it. Routing private conversation bytes
  through that route family would turn a parity feature into a confidentiality
  regression, which is exactly what charter D16 disqualified.

  So these two routes ride `[:api, :require_chat_access]` — the SAME pipeline,
  and the same `chat_scope` (`:global` for a global-admin token, `{:workspace,
  ws}` for a workspace-bound `chat` Connector), as every other
  `/v1/chat/sessions/:id` route. And they run the SAME tenant oracle:
  `fetch_scoped/2` reads the session through the sealed store scope BEFORE any
  attachment work, so a session in another tenant joins the not-found oracle —
  indistinguishable from a missing id, never a distinct 403.

  Three token classes and what each gets, by construction:

    * a **global-admin** token — `:global` scope, reaches every session (D21
      authority unchanged);
    * a **workspace `chat` Connector** — confined to sessions its own workspace
      owns; another tenant's session 404s on both routes;
    * a **plain data-plane token** (`read`/`write`, no `admin`, no `chat`) —
      `RequireChatAccess` halts 403 before the controller is entered at all.

  ## Wire contract

      POST /v1/chat/sessions/:id/attachments   {"data": "<base64>"}   -> 201
      GET  /v1/chat/sessions/:id/attachments/:attachment_id           -> 200

  Both answer JSON `{"attachment": {...}}`. The read returns the bytes as base64
  inside that envelope rather than as a raw body: the store accepts only images
  whose type is sniffed from their own magic bytes (`StudioChat.Attachments`), so
  a JSON envelope means the server never echoes caller-supplied bytes back under
  a caller-influenced `Content-Type` — the stored-XSS shape a raw byte route
  invites is unrepresentable here.

  Strict body validation follows D22: a non-object body, an unknown key, a
  non-string `data`, invalid base64, an over-cap payload, or bytes that are not
  one of the four accepted images all fail with the canonical envelope BEFORE
  anything is written.
  """

  use BarkparkWeb, :controller

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments
  alias BarkparkWeb.ErrorResponse

  # ── POST /v1/chat/sessions/:id/attachments ─────────────────────────────────

  @doc """
  Upload one attachment to a session's chat-owned store. Body `{"data":
  "<base64>"}`; the media type is SNIFFED from the decoded bytes, never taken
  from the caller. 201 `{"attachment": {id, media_type, byte_size, url}}` — the
  opaque content-addressed id and the chat-owned URL that reads it back, with no
  store path and no token anywhere in the payload.
  """
  def create(conn, %{"id" => id} = params) do
    body = Map.drop(params, ["id"])

    # Tenant oracle FIRST (charter D17): a session another tenant owns must 404
    # before this route reveals anything — including whether a body was valid.
    with %StudioChat.Session{} = session <- fetch_scoped(id, scope(conn)),
         {:ok, bytes} <- validate_upload(body),
         {:ok, pointer} <- store(session.id, bytes) do
      conn
      |> put_status(:created)
      |> json(%{attachment: Attachments.reference(pointer, session.id)})
    else
      nil -> not_found(conn)
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── GET /v1/chat/sessions/:id/attachments/:attachment_id ───────────────────

  @doc """
  Read one attachment back. 200 `{"attachment": {id, media_type, byte_size, url,
  data}}` where `data` is the base64 payload. A missing attachment — and an
  attachment id in a session the caller cannot see — is the same 404: the tenant
  oracle runs first, so a UUID guess can never confirm that a session (or the
  attachment on it) exists in another tenant.
  """
  def show(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with %StudioChat.Session{} = session <- fetch_scoped(id, scope(conn)),
         {:ok, attachment} <- Attachments.fetch(session.id, attachment_id) do
      json(conn, %{
        attachment: %{
          id: attachment.id,
          media_type: attachment.media_type,
          byte_size: attachment.byte_size,
          url: Attachments.url(session.id, attachment.id),
          data: Base.encode64(attachment.bytes)
        }
      })
    else
      nil -> not_found(conn)
      {:error, :missing} -> attachment_not_found(conn)
    end
  end

  # ── scope + fetch (the SAME oracle as every other id route) ────────────────

  defp scope(conn), do: conn.assigns.chat_scope

  defp store_scope(:global), do: :global
  defp store_scope({:workspace, ws}), do: ws

  # The sealed store confines the read (charter D17) — `nil` when the session is
  # missing OR owned by another tenant. The controller only threads the scope;
  # the store is the single enforcement point.
  defp fetch_scoped(id, scope), do: StudioChat.get_session(id, store_scope(scope))

  # ── validation (D22 strictness) ────────────────────────────────────────────

  defp validate_upload(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, ["data"]) do
      case Map.get(params, "data") do
        value when not is_binary(value) ->
          {:error, "data must be a base64 string"}

        value ->
          case Base.decode64(value) do
            {:ok, bytes} -> {:ok, bytes}
            :error -> {:error, "data must be valid base64"}
          end
      end
    end
  end

  defp reject_non_object(%{"_json" => _}), do: {:error, "request body must be a JSON object"}
  defp reject_non_object(params) when is_map(params), do: :ok
  defp reject_non_object(_), do: {:error, "request body must be a JSON object"}

  defp reject_unknown_keys(params, allowed) do
    case Map.keys(params) -- allowed do
      [] -> :ok
      extra -> {:error, "unrecognized keys: #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  # Map the store's refusals onto honest wire messages. A write failure is NOT
  # interpolated (D23 — never echo a raw term); the generic message stands and
  # the reason stays server-side.
  defp store(session_id, bytes) do
    case Attachments.put(session_id, bytes) do
      {:ok, pointer} ->
        {:ok, pointer}

      {:error, :empty} ->
        {:error, "data must decode to at least one byte"}

      {:error, :too_large} ->
        {:error, "attachment exceeds #{Attachments.max_bytes()} bytes"}

      {:error, :unsupported_media_type} ->
        {:error, "attachment must be one of: #{Enum.join(Attachments.media_types(), ", ")}"}

      {:error, _reason} ->
        {:error, "attachment could not be stored"}
    end
  end

  # ── responses ──────────────────────────────────────────────────────────────

  defp bad_request(conn, message) do
    ErrorResponse.emit_custom(conn, 400, "invalid_request", message)
  end

  defp not_found(conn) do
    ErrorResponse.emit(conn, {:error, :not_found}, "chat session not found")
  end

  defp attachment_not_found(conn) do
    ErrorResponse.emit(conn, {:error, :not_found}, "chat attachment not found")
  end
end
