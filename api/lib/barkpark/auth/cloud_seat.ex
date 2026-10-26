defmodule Barkpark.Auth.CloudSeat do
  @moduledoc """
  Where a Barkpark Cloud handoff seats the person it signs in. Shared by the
  browser ticket (`BarkparkWeb.SessionController.ticket/2`) and the Studio
  exchange (`BarkparkWeb.LoginTicketController.exchange/2`).

  Only the DEFAULT workspace is ever touched. A handoff never seats anyone in
  another workspace: a Studio pointed at one must find the person already
  seated there by that workspace's own admins.
  """

  @doc """
  Does this instance accept the Barkpark Cloud handoff? `BARKPARK_CLOUD_HANDOFF=off`
  turns it off on an instance Barkpark Cloud does not manage; the default is on.
  """
  @spec handoff_enabled?() :: boolean()
  def handoff_enabled?, do: Application.get_env(:barkpark, :cloud_handoff, true) != false

  # Owner ruling #26 (2026-10-03, "Match role, revoke"): the handoff seats the
  # user at the Cloud TEAM role the ticket carries — a team member lands as a
  # member, an admin as an admin, the owner as owner. The team is the authority
  # for a managed instance, so an existing BUILT-IN role is synced to it on every
  # handoff (a promoted or demoted teammate lands at their current role). Two
  # things are never touched: a CUSTOM role (an instance admin chose it), and the
  # LAST owner of the workspace (`Members.update_role/3` refuses that demotion).
  #
  # A pre-ruling ticket carries no role (nil): it keeps the old behaviour — an
  # absent membership gets owner, an existing one is left alone.
  def ensure_default_membership(user, role) do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: ws_id} -> seat_default_membership(user, ws_id, role)
      _ -> :ok
    end
  end

  defp seat_default_membership(user, ws_id, role) do
    alias Barkpark.Tenancy.Auth, as: TAuth

    case {TAuth.membership(user, ws_id), role} do
      {nil, nil} ->
        {:ok, _} = TAuth.create_membership(ws_id, user.id, "owner", "user")
        :ok

      {nil, role} ->
        {:ok, _} = TAuth.create_membership(ws_id, user.id, role, "user")
        :ok

      {_existing, nil} ->
        :ok

      {%{role: same}, same} ->
        :ok

      {%{role: current}, role} ->
        # Members.update_role/3 refuses to demote the last owner on its own.
        if current in Barkpark.Tenancy.Membership.roles() do
          _ = Barkpark.Tenancy.Members.update_role(ws_id, %{type: :user, id: user.id}, role)
        end

        :ok
    end
  end
end
