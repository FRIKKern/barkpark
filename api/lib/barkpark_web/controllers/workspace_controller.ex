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

  @doc """
  POST /api/workspaces — create a Workspace owned by the bearer token.

  Any authenticated token may create a workspace; the creator is bound as an
  `"owner"` Membership in the same transaction, and a Default Project +
  "production" Dataset are bootstrapped so the workspace is immediately usable.
  201 + the created workspace; 422 (via FallbackController) on an invalid /
  duplicate slug.
  """
  def create(conn, params) do
    token = conn.assigns[:api_token]
    attrs = workspace_attrs(params)

    with {:ok, workspace} <- Tenancy.create_workspace_with_owner(attrs, token) do
      conn
      |> put_status(:created)
      |> json(%{workspace: render_workspace(workspace)})
    end
  end

  @doc """
  POST /api/workspaces/:workspace_slug/projects — create a Project (+ its
  "production" Dataset) under a workspace the caller is a MEMBER of.

  A non-member (and an unknown slug) both collapse to 404 — the same no-leak
  convention as the `projects` LIST action. 201 + the created project on
  success; 422 on an invalid / duplicate slug.
  """
  def create_project(conn, %{"workspace_slug" => slug} = params) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id),
         {:ok, project} <-
           Tenancy.create_project_with_dataset(workspace, project_attrs(params)) do
      conn
      |> put_status(:created)
      |> json(%{project: render_project(project)})
    else
      # A changeset error flows to the FallbackController (422). Anything else
      # (unknown slug / non-member) collapses to 404 — no existence leak.
      {:error, %Ecto.Changeset{}} = err -> err
      _ -> {:error, :not_found}
    end
  end

  # Build the workspace create-attrs from the request body — only :name and an
  # optional :slug are honoured (slug derived from name when absent in the
  # context). Other body keys are ignored.
  defp workspace_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp project_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
