defmodule BarkparkWeb.WorkspaceController do
  @moduledoc """
  Membership-scoped LIST surface for the web workspace/project switcher.

    * `GET /api/workspaces` — the Workspaces the bearer token is a MEMBER of
      (via `workspace_memberships`). A workspace the caller has no membership
      row in is NEVER returned — the hard tenant boundary, enforced in the
      `Tenancy.list_workspaces_for/1` query, not here.

    * `GET /api/workspaces/:workspace_slug/projects` — the Projects under that
      workspace, but ONLY when the caller is a member. A non-member (and an
      unknown slug) both return 404 so the endpoint never leaks whether a
      workspace exists. `:require_token` already 401s an absent/invalid token.

  Token is assigned to `conn.assigns[:api_token]` by the `:require_token`
  pipeline. The JSON envelope mirrors the flat `/v1` controllers — a plain map
  rendered with `json/2`, no separate view module.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  action_fallback BarkparkWeb.FallbackController

  def index(conn, _params) do
    token = conn.assigns[:api_token]
    workspaces = Tenancy.list_workspaces_for(token)
    json(conn, %{workspaces: Enum.map(workspaces, &render_workspace/1)})
  end

  def projects(conn, %{"workspace_slug" => slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id) do
      projects = Tenancy.list_projects(workspace)

      json(conn, %{
        workspace: render_workspace(workspace),
        projects: Enum.map(projects, &render_project/1)
      })
    else
      # Unknown slug OR a real workspace the caller is not a member of both
      # collapse to 404 — never confirm a workspace exists to a non-member.
      _ -> {:error, :not_found}
    end
  end

  defp render_workspace(%Tenancy.Workspace{} = ws) do
    %{id: ws.id, slug: ws.slug, name: ws.name}
  end

  defp render_project(%Tenancy.Project{} = project) do
    %{id: project.id, slug: project.slug, name: project.name}
  end
end
