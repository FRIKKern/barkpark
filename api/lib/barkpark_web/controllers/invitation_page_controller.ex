defmodule BarkparkWeb.InvitationPageController do
  @moduledoc """
  The invited user's browser door (task-5306379c9be40c89): `GET /invitations`
  lists the signed-in account's pending workspace invitations with Accept and
  Decline, and the two POSTs act on one. Before this the only way to take a
  seat was the JSON `POST /v1/auth/invitations/:id/accept`.

  Every action goes through `Barkpark.Tenancy.Members`, which only ever acts on
  an invitation addressed to the caller: someone else's id answers the same
  "no longer open" as one that does not exist. Accept lands the user in the
  workspace's Studio. An anonymous visitor is sent to sign in first.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Members
  alias BarkparkWeb.StudioLocale
  alias BarkparkWeb.Studio.ScopeResolver
  alias BarkparkWeb.Studio.StudioLive.Paths

  def index(conn, _params) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> render_page(conn, user_id, nil)
      _ -> redirect(conn, to: "/login?return_to=%2Finvitations")
    end
  end

  def accept(conn, %{"id" => id}) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        with %{workspace_id: ws_id} <- find(user_id, id),
             {:ok, _member} <- Members.accept_invitation(user_id, id) do
          redirect(conn, to: landing(ws_id))
        else
          _ -> render_page(put_status(conn, 422), user_id, :not_open)
        end

      _ ->
        redirect(conn, to: "/login?return_to=%2Finvitations")
    end
  end

  def decline(conn, %{"id" => id}) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        case Members.decline_invitation(user_id, id) do
          :ok -> redirect(conn, to: "/invitations")
          {:error, _} -> render_page(put_status(conn, 422), user_id, :not_open)
        end

      _ ->
        redirect(conn, to: "/login?return_to=%2Finvitations")
    end
  end

  defp find(user_id, id),
    do: Enum.find(Members.list_invitations_for_user(user_id), &(&1.id == id))

  # The joined workspace's Studio: its default project and dataset, the same
  # resolution the bare /studio redirect uses.
  defp landing(ws_id) do
    with %{} = ws <- Tenancy.get_workspace_by_id(ws_id),
         %{} = project <- ScopeResolver.resolve_project(ws) do
      Paths.scoped_root(ws.slug, project.slug, ScopeResolver.resolve_dataset(project, nil))
    else
      _ -> "/studio"
    end
  end

  # The page speaks the viewer's own Studio language (their resolved
  # workspace), like the not-a-member page.
  defp render_page(conn, user_id, error) do
    locale =
      case ScopeResolver.resolve_scope(conn, ScopeResolver.principal(conn)) do
        {:ok, workspace, _project} -> StudioLocale.resolve(workspace)
        :error -> StudioLocale.resolve(nil)
      end

    Gettext.put_locale(BarkparkWeb.Gettext, locale)

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(BarkparkWeb.StudioRefusalHTML)
    |> render("invitations.html",
      invitations: Members.list_invitations_for_user(user_id),
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      error: error
    )
  end
end
