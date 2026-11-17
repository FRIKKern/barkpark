defmodule BarkparkWeb.WorkspaceAccessRequestController do
  @moduledoc """
  The ADMIN's side of access requests (task-1b99ba8512bb758e): list the
  workspace's pending requests, approve one with a role, deny one.

  Mounted beside the roster (`MemberController`) on `[:scoped_api,
  :scoped_admin]`, so the gate is the same: an owner or admin seat in the
  URL's workspace. A non-admin member and an admin of another workspace are
  refused by that pipeline exactly as on `/v1/members`. A request id of
  another workspace answers 404 and writes nothing.

  Approve seats the user through `Members.add_user_member/4`
  (`Tenancy.AccessRequests.approve/4`), so the invite path's role ceiling
  holds: only an owner grants `owner` (`403 owner_required`).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy.AccessRequests
  alias BarkparkWeb.ErrorResponse

  @default_role "member"

  @doc "`GET /w/:ws/p/:proj/v1/access-requests` — pending requests, oldest first."
  def index(conn, _params) do
    case conn.assigns[:current_workspace] do
      %{id: ws_id} -> json(conn, %{access_requests: AccessRequests.list_pending(ws_id)})
      _ -> unresolved_workspace(conn)
    end
  end

  @doc """
  `POST /w/:ws/p/:proj/v1/access-requests/:id/approve` — seat the asker.
  Body: `{"role": "member|admin|owner|contributor|<custom>"}`, default `member`.
  """
  def approve(conn, %{"id" => id} = params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, role} <- fetch_role(params) do
      case AccessRequests.approve(ws_id, id, role, conn.assigns[:api_token]) do
        {:ok, result} -> json(conn, result)
        {:error, reason} -> deny(conn, reason)
      end
    else
      {:error, :invalid_role} -> unprocessable(conn, "role must be a non-empty string")
      _ -> unresolved_workspace(conn)
    end
  end

  @doc "`POST /w/:ws/p/:proj/v1/access-requests/:id/deny` — refuse; no seat is made."
  def deny_request(conn, %{"id" => id}) do
    with %{id: ws_id} <- conn.assigns[:current_workspace] do
      case AccessRequests.deny(ws_id, id, conn.assigns[:api_token]) do
        {:ok, result} -> json(conn, result)
        {:error, reason} -> deny(conn, reason)
      end
    else
      _ -> unresolved_workspace(conn)
    end
  end

  defp fetch_role(params) do
    case Map.get(params, "role", @default_role) do
      role when is_binary(role) ->
        case String.trim(role) do
          "" -> {:error, :invalid_role}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_role}
    end
  end

  defp deny(conn, :not_found),
    do: fields(conn, :not_found, "not_found", "no pending access request with that id here")

  defp deny(conn, :owner_required),
    do:
      fields(
        conn,
        :forbidden,
        "owner_required",
        "only an owner of this workspace can grant the owner role"
      )

  defp deny(conn, :already_member),
    do:
      fields(
        conn,
        :conflict,
        "already_member",
        "that person already holds a seat here; deny the request to clear it"
      )

  defp deny(conn, %Ecto.Changeset{} = cs) do
    if Keyword.has_key?(cs.errors, :role),
      do: unprocessable(conn, "role is not a role of this workspace"),
      else: unprocessable(conn, "could not complete the request")
  end

  defp deny(conn, _), do: unprocessable(conn, "could not complete the request")

  defp unprocessable(conn, message),
    do: fields(conn, :unprocessable_entity, "unprocessable", message)

  defp unresolved_workspace(conn), do: unprocessable(conn, "workspace could not be resolved")

  defp fields(conn, status, code, message),
    do: ErrorResponse.emit_fields(conn, status, %{code: code, message: message})

  # A dataset-bound admin token: the list is a members read, approve and deny
  # are members writes — observed or refused like `MemberController`'s.
  plug(BarkparkWeb.Plugs.DatasetBoundAdminReads, [surface: "members"] when action in [:index])

  plug(
    BarkparkWeb.Plugs.DatasetBoundAdminWrites,
    [surface: "members_write"] when action in [:approve, :deny_request]
  )
end
