defmodule BarkparkWeb.ChatStreamSeat do
  @moduledoc """
  The chat SSE streams' re-auth tick (task-aa5e85a40c317b3a).

  Both streams (`GET /v1/chat/sessions/:id/events`, `GET /v1/chat/events`)
  authorize at connect and never shed (D5). The r4a sweep made them re-ask
  `Auth.token_live?/1` before a write, at most once per
  `:chat_sse_reauth_interval_ms` (default 2 s), so a revoked or expired bearer
  is cut off. That tick read only the token row. An owner demoted to member,
  or removed from the workspace, kept an open stream on a chat on the
  workspace's registered host: the full transcript on the per-session stream,
  and that chat's state, heartbeat and title on the fleet stream, until the
  client chose to reconnect.

  The same tick now re-asks the host seat (`HostExecutionGate.may_see_session?/2`):

    * per-session stream: `watch/2` pins a registered-host session on the conn,
      and `live?/1` re-reads it through `ChatSessionDoor.fetch/2` (the tenant
      seal and the seat). A seat that is gone ends the stream with the
      `unauthorized` frame, as a dead token does. A managed session pays nothing
      extra.
    * fleet stream: the forwarder (`ChatFleetSeat.start_forwarder/3`) re-checks
      the host sessions it has cached, in one batch, when a frame arrives more
      than an interval after its last check. A host chat whose seat is gone
      stops getting frames; the stream stays open for the rest.

  COST. At most one re-check per interval per connection, never one per frame.
  """

  alias BarkparkWeb.ChatSessionDoor

  @checked_at :chat_sse_credential_checked_at

  @doc "The re-auth interval in milliseconds (`:chat_sse_reauth_interval_ms`, default 2 s)."
  @spec interval_ms() :: non_neg_integer()
  def interval_ms, do: Application.get_env(:barkpark, :chat_sse_reauth_interval_ms, 2_000)

  @doc """
  Pin the session a per-session stream serves when it is on a registered host,
  so `live?/1` re-asks its seat. On the conn, not the process: a keep-alive
  connection serves its next request from the same process.
  """
  @spec watch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def watch(conn, %{execution_target: "registered_host", id: id}),
    do: Plug.Conn.assign(conn, :chat_stream_host_session, id)

  def watch(conn, _session), do: conn

  @doc """
  True while the stream may write: the bearer is live and, for a watched host
  session, the caller still sees it. Asked before every write, answered from
  the last check until an interval has passed.
  """
  @spec live?(Plug.Conn.t()) :: boolean()
  def live?(conn) do
    now = System.monotonic_time(:millisecond)
    interval = interval_ms()

    case Process.get(@checked_at) do
      at when is_integer(at) and now - at < interval ->
        true

      _ ->
        live? = Barkpark.Auth.token_live?(conn.assigns[:api_token]) and seated?(conn)
        if live?, do: Process.put(@checked_at, now)
        live?
    end
  end

  defp seated?(conn) do
    case conn.assigns[:chat_stream_host_session] do
      nil -> true
      id -> not is_nil(ChatSessionDoor.fetch(conn, id))
    end
  end
end
