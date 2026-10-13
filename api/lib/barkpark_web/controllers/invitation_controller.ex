defmodule BarkparkWeb.InvitationController do
  @moduledoc """
  The invited USER's side of seat consent (OWNER RULING 2026-10-03 #7,
  task-a08da65bc33083d0): list, accept or decline the workspace invitations
  addressed to the signed-in account.

  Mounted on `[:user_auth, :require_user]` beside `/v1/auth/me`, so the caller
  is always a signed-in user and only ever sees its own invitations. An
  invitation addressed to somebody else answers the same 404 as one that does
  not exist.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy.Members
  alias BarkparkWeb.ErrorResponse

  @doc "`GET /v1/auth/invitations`"
  def index(conn, _params) do
    json(conn, %{invitations: Members.list_invitations_for_user(conn.assigns.current_user.id)})
  end

  @doc "`POST /v1/auth/invitations/:id/accept` — take the seat."
  def accept(conn, %{"id" => id}) do
    case Members.accept_invitation(conn.assigns.current_user.id, id) do
      {:ok, member} -> conn |> put_status(:created) |> json(%{member: member})
      {:error, :not_found} -> not_found(conn)
      {:error, _reason} -> unprocessable(conn)
    end
  end

  @doc "`DELETE /v1/auth/invitations/:id` — decline."
  def decline(conn, %{"id" => id}) do
    case Members.decline_invitation(conn.assigns.current_user.id, id) do
      :ok -> json(conn, %{declined: id})
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp not_found(conn) do
    ErrorResponse.emit_fields(conn, :not_found, %{
      code: "not_found",
      message: "no such invitation for this account"
    })
  end

  defp unprocessable(conn) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "unprocessable",
      message: "the invitation could not be accepted"
    })
  end
end
