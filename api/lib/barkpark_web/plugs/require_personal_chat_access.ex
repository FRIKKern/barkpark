defmodule BarkparkWeb.Plugs.RequirePersonalChatAccess do
  @moduledoc """
  A verified login session and a current workspace seat own a personal chat.
  Runs after RequireUserSession, RequireOrgMfaEnrolment and ResolveWorkspace.
  A grant, API token or anonymous admission cannot supply this scope.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns do
      %{
        current_user: %Barkpark.Accounts.User{id: user},
        current_user_session: %Barkpark.Accounts.UserSession{},
        current_workspace: %Barkpark.Tenancy.Workspace{id: workspace},
        member_user: true
      } ->
        assign(conn, :chat_scope, {:personal, workspace, user})

      _ ->
        BarkparkWeb.ErrorResponse.emit_custom(
          conn,
          403,
          "personal_chat_membership_required",
          "a personal login session with a current workspace seat is required"
        )
        |> halt()
    end
  end
end
