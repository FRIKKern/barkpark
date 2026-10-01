defmodule BarkparkWeb.HostExecutionGate do
  @moduledoc """
  WHO may reach the INSTANCE HOST from a web door (task-6ca882967fd95dda): a
  host-executing chat turn, instance-global chat scope, the Studio terminal,
  choosing the `self_hosted` chat profile.

  The core half — which sessions may execute on the host at all, and which
  turns would — is `Barkpark.StudioChat.HostExecution`. This is the principal
  half, here because the operator allowlist is a web-layer plug's
  (`RequirePlatformOperator`).

  An INSTANCE PRINCIPAL is: when the platform operator allowlist
  (`BARKPARK_OPERATOR_EMAILS` / `BARKPARK_OPERATOR_TOKEN_IDS`) is armed, only a
  principal it names; when it is unset (single-tenant), an instance-admin
  token, an owner/admin of the Default workspace, or a chat token bound to the
  Default workspace (only a Default admin can mint one).
  """

  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.StudioChat.HostExecution
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  @doc "True when `principal` (an `%ApiToken{}` or `%User{}`) may hold instance-host reach."
  @spec instance_principal?(term()) :: boolean()
  def instance_principal?(principal) do
    if allowlist_armed?(),
      do: RequirePlatformOperator.permits?(principal),
      else: default_owner?(principal)
  end

  @doc """
  `:ok`, or `{:error, :host_execution_not_permitted}` when `principal` would
  start or drive a managed turn on the host for `session` (a map with
  `:provider`, `:execution_target`, `:owner_workspace_id`) that it may not.
  `registered_host` sessions and turns that do not run on the host always pass.
  """
  @spec authorize_turn(term(), map()) :: :ok | {:error, :host_execution_not_permitted}
  def authorize_turn(principal, %{execution_target: target} = session)
      when target in [nil, "managed"] do
    ws = Map.get(session, :owner_workspace_id)

    cond do
      not HostExecution.host_exec?(Map.get(session, :provider) || "claude", ws) -> :ok
      HostExecution.workspace_may_host_exec?(ws) and instance_principal?(principal) -> :ok
      true -> {:error, :host_execution_not_permitted}
    end
  end

  def authorize_turn(_principal, _session), do: :ok

  # The admin bit is the flat instance tier (RequireAdmin) and needs no DB read.
  defp default_owner?(%ApiToken{} = token) do
    Auth.has_permission?(token, "admin") or default_seat?(token, default_workspace_id())
  end

  defp default_owner?(%User{} = user) do
    case default_workspace_id() do
      ws when is_binary(ws) -> TenancyAuth.workspace_admin?(user, ws)
      _ -> false
    end
  end

  defp default_owner?(_), do: false

  defp default_seat?(_token, nil), do: false

  defp default_seat?(token, default) do
    (token.workspace_id == default and Auth.has_permission?(token, "chat")) or
      TenancyAuth.workspace_admin?(token, default)
  end

  defp default_workspace_id do
    case Tenancy.get_default_workspace() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp allowlist_armed? do
    case RequirePlatformOperator.allowlist() do
      %{emails: [], token_ids: []} -> false
      _ -> true
    end
  end
end
