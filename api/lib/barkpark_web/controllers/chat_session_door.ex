defmodule BarkparkWeb.ChatSessionDoor do
  @moduledoc """
  The one way the chat HTTP controllers reach a session by id, and the list
  (task-f44bbb6363d28e37).

  Two seals, in order:

    1. The tenant seal (charter D17, Connectors D18/D19a): the store read runs
       in the caller's `chat_scope` (`:global` or `{:workspace, ws}`), so a
       foreign tenant's session is invisible at the DB.
    2. The registered-host seat (`HostExecutionGate.may_see_session?/2`): a
       chat on a workspace's registered host is seen only by a seat that may
       drive it (owner or admin seat there, or a token held for an owner).

  A session either seal refuses is `nil`, the same as a missing id, so every
  door answers the same not-found and a session's existence does not leak.
  """

  alias Barkpark.StudioChat
  alias BarkparkWeb.HostExecutionGate

  @doc "The caller's `chat_scope` as the store's scope arg: `{:workspace, ws}` → `ws`."
  @spec store_scope(:global | {:workspace, binary()}) :: :global | binary()
  def store_scope(:global), do: :global
  def store_scope({:workspace, ws}), do: ws

  @doc "The session `id` names, or nil when it is missing or the caller may not see it."
  @spec fetch(Plug.Conn.t(), term()) :: StudioChat.Session.t() | nil
  def fetch(conn, id) do
    with %StudioChat.Session{} = session <- StudioChat.get_session(id, scope(conn)),
         true <- HostExecutionGate.may_see_session?(conn.assigns[:api_token], session),
         do: session,
         else: (_ -> nil)
  end

  @doc "The sidebar list in the caller's scope, without the host chats it may not see."
  @spec list(Plug.Conn.t(), keyword()) :: [StudioChat.Session.t()]
  def list(conn, opts) do
    HostExecutionGate.visible_sessions(
      conn.assigns[:api_token],
      StudioChat.list_sessions(opts, scope(conn))
    )
  end

  @doc "Archive (`true`) or unarchive (`false`); `:noop` (⇒ 404) when the caller may not see it."
  @spec set_archived(Plug.Conn.t(), term(), boolean()) ::
          {:ok, StudioChat.Session.t()} | :noop | {:error, term()}
  def set_archived(conn, id, archived?) do
    cond do
      is_nil(fetch(conn, id)) -> :noop
      archived? -> StudioChat.archive_session(id, scope(conn))
      true -> StudioChat.unarchive_session(id, scope(conn))
    end
  end

  defp scope(conn), do: store_scope(conn.assigns.chat_scope)
end
