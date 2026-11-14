defmodule BarkparkWeb.Plugs.RequireChatAccess do
  @moduledoc """
  Resolves the caller's `/v1/chat` tenancy scope into `conn.assigns.chat_scope`,
  or halts 403 when the token may not touch chat at all.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.RequireToken` so
  `conn.assigns[:api_token]` is set.

  ## Scope resolution (Connectors charter D18/D19a)

    * a token carrying the `admin` permission => `:global` (instance-global
      authority — the live admin token and `bp chat` keep reading/controlling
      every session on the instance, D21) — but only for the instance
      operator. With the platform operator allowlist armed, that is a token it
      names (task-6ca882967fd95dda, `BarkparkWeb.HostExecutionGate`). With it
      unset, that is an admin token of the Default workspace or of no
      workspace (task-f98c47f23e7bde9a)
    * allowlist unset, an `admin` token of any other workspace =>
      `{:workspace, workspace_id}`: its own tenant's chat, never another's
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
  alias BarkparkWeb.HostExecutionGate

  def init(opts), do: opts

  def call(conn, _opts) do
    # The chat API refuses unknown keys, so the `dataset` a bound token was
    # given upstream (`BoundDataset.resolve/2`) is taken out again here.
    conn = BarkparkWeb.Plugs.BoundDataset.unfill(conn)
    token = conn.assigns[:api_token]

    case chat_scope(token) do
      nil when not is_nil(token) ->
        if Auth.has_permission?(token, "admin") do
          # An admin-bit token refused ONLY by the operator allowlist: say why.
          BarkparkWeb.ErrorResponse.emit_custom(
            conn,
            403,
            Barkpark.StudioChat.HostExecution.reason(),
            "Instance-wide chat is reserved for the platform operator on this instance."
          )
          |> halt()
        else
          forbidden(conn)
        end

      nil ->
        forbidden(conn)

      scope ->
        assign(conn, :chat_scope, scope)
    end
  end

  defp forbidden(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  # `:global` for the instance operator's admin token (D21 authority
  # preserved); a tenant scope for any other workspace-bound admin token and
  # for a workspace-bound `chat` token; otherwise deny.
  defp chat_scope(nil), do: nil

  defp chat_scope(token) do
    cond do
      not Auth.has_permission?(token, "admin") ->
        chat_seat(token)

      # Instance-global chat reach is instance-host reach (task-6ca882967fd95dda):
      # with the operator allowlist armed, an admin-bit token outside it no
      # longer gets `:global` — it falls through to its workspace binding (if it
      # carries `chat`) or is refused.
      HostExecutionGate.allowlist_armed?() ->
        if HostExecutionGate.instance_principal?(token), do: :global, else: chat_seat(token)

      # Allowlist unset (task-f98c47f23e7bde9a): the instance operator is the
      # admin token of the Default workspace or of no workspace. An admin token
      # of any other workspace is that tenant's admin: its own workspace's chat,
      # with or without the `chat` permission, never another tenant's.
      # A no-workspace token needs no lookup.
      is_nil(token.workspace_id) or
          token.workspace_id == HostExecutionGate.default_workspace_id() ->
        :global

      true ->
        {:workspace, token.workspace_id}
    end
  end

  defp chat_seat(token) do
    if Auth.has_permission?(token, "chat") and not is_nil(token.workspace_id),
      do: {:workspace, token.workspace_id},
      else: nil
  end
end
