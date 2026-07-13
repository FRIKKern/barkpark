defmodule BarkparkWeb.Plugs.RequireChatAccess do
  @moduledoc """
  Resolves the caller's `/v1/chat` tenancy scope into `conn.assigns.chat_scope`,
  or halts 403 when the token may not touch chat at all.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set.

  ## Scope resolution (Connectors charter D18/D19a)

    * a token carrying the global `admin` permission => `:global`
      (UNCHANGED instance-global authority — the live admin token and `bp chat`
      keep reading/controlling every session on the instance, D21)
    * a workspace-bound token carrying the `chat` permission =>
      `{:workspace, workspace_id}` (a Connector confined to its own tenant)
    * neither => 403 (canonical request-id envelope, same shape as RequireAdmin)

  The controller (`BarkparkWeb.ChatController`) ENFORCES the scope: a `:global`
  caller reads/controls everything; a `{:workspace, ws}` caller is confined to
  sessions its workspace owns, and a wrong-tenant read joins the not-found oracle
  — indistinguishable from a missing id, never a distinct 403, so a UUID guess
  cannot confirm a session exists in another tenant.

  A `chat`-permissioned token with NO workspace binding cannot be confined to a
  tenant, so it is denied (403) rather than silently granted instance-global
  reach.
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    case chat_scope(conn.assigns[:api_token]) do
      nil ->
        env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

        conn
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()

      scope ->
        assign(conn, :chat_scope, scope)
    end
  end

  # `:global` for a global-admin token (D21 authority preserved); otherwise a
  # tenant scope only for a workspace-bound `chat` token; otherwise deny.
  defp chat_scope(nil), do: nil

  defp chat_scope(token) do
    cond do
      Auth.has_permission?(token, "admin") ->
        :global

      Auth.has_permission?(token, "chat") and not is_nil(token.workspace_id) ->
        {:workspace, token.workspace_id}

      true ->
        nil
    end
  end
end
