defmodule BarkparkWeb.ChatHostAttachmentController do
  @moduledoc """
  The registered host's read of a chat attachment
  (`/papers/chat-host-attachments-plan`, T3).

      GET /v1/chat-host/leases/:lease_id/attachments/:attachment_id   -> 200

  The route rides the `:registered_chat_host` pipeline, so only an
  `Authorization: Host <credential>` of an enrolled, unrevoked, unexpired host
  arrives here (`RequireChatHost`); an owner bearer token is a 401 before this
  module runs.

  ## The fence

  The host never names a session. It names the lease it is serving, and
  `ChatHosts.live_lease_for_host/2` answers only for a live lease this host
  holds, in its own workspace, on a session that workspace owns. The session id
  comes from that lease row, and only then is the store read, through
  `Attachments.fetch/2`, which refuses any id that is not 64 lowercase hex
  before touching the disk.

  Every miss is ONE 404 body, `chat attachment not found`: another host's
  lease, another workspace's, an ended (completed, cancelled, disconnected),
  expired or revoked lease, a malformed or unknown lease id, an attachment in
  another session, a malformed attachment id, a missing attachment. A caller
  learns nothing about which leg refused.

  ## The answer

  The same JSON envelope as the owner read in `ChatAttachmentController`, with
  the bytes base64 inside and the type sniffed from those bytes:
  `{"attachment": {id, media_type, byte_size, data}}`. No `url` (the host
  credential cannot read the owner route), no store path, no session id.
  """

  use BarkparkWeb, :controller

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.StudioChat.Attachments
  alias BarkparkWeb.ErrorResponse

  def show(conn, %{"lease_id" => lease_id, "attachment_id" => attachment_id}) do
    with %ExecutionLease{session_id: session_id} <-
           ChatHosts.live_lease_for_host(conn.assigns.chat_host, lease_id),
         {:ok, attachment} <- Attachments.fetch(session_id, attachment_id) do
      json(conn, %{
        attachment: %{
          id: attachment.id,
          media_type: attachment.media_type,
          byte_size: attachment.byte_size,
          data: Base.encode64(attachment.bytes)
        }
      })
    else
      _miss -> ErrorResponse.emit(conn, {:error, :not_found}, "chat attachment not found")
    end
  end
end
