defmodule Barkpark.Tenancy do
  @moduledoc """
  Context for the Workspace -> Project -> (Dataset) tenancy hierarchy.

  Wave 1 foundation: workspace/project lookup + creation and the Default
  Workspace / Default Project the migration backfills. Query scoping,
  token-binding, and auth enforcement are sibling tasks and live elsewhere.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Workspace, Project}

  @default_slug "default"

  @doc "Returns the seeded Default Workspace, or nil if the backfill hasn't run."
  @spec get_default_workspace() :: Workspace.t() | nil
  def get_default_workspace do
    Repo.get_by(Workspace, slug: @default_slug)
  end

  @doc "Returns the Default Project under the Default Workspace, or nil."
  @spec get_default_project() :: Project.t() | nil
  def get_default_project do
    case get_default_workspace() do
      nil -> nil
      %Workspace{id: ws_id} -> Repo.get_by(Project, workspace_id: ws_id, slug: @default_slug)
    end
  end

  @doc "Fetch a Workspace by its slug, or nil."
  @spec get_workspace_by_slug(String.t()) :: Workspace.t() | nil
  def get_workspace_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Workspace, slug: slug)
  end

  @doc """
  Fetch a Project by its Workspace slug + Project slug. Returns nil when
  either the Workspace or the Project is absent.
  """
  @spec get_project(String.t(), String.t()) :: Project.t() | nil
  def get_project(ws_slug, project_slug)
      when is_binary(ws_slug) and is_binary(project_slug) do
    query =
      from p in Project,
        join: w in Workspace,
        on: p.workspace_id == w.id,
        where: w.slug == ^ws_slug and p.slug == ^project_slug

    Repo.one(query)
  end

  @doc "List all Projects under a Workspace (accepts a struct or a workspace id)."
  @spec list_projects(Workspace.t() | binary()) :: [Project.t()]
  def list_projects(%Workspace{id: ws_id}), do: list_projects(ws_id)

  def list_projects(ws_id) when is_binary(ws_id) do
    Repo.all(from p in Project, where: p.workspace_id == ^ws_id, order_by: p.slug)
  end

  @doc "Create a Workspace from attrs."
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a Project under the given Workspace (struct or id). The workspace_id
  in `attrs` is overridden by the resolved workspace.
  """
  @spec create_project(Workspace.t() | binary(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(%Workspace{id: ws_id}, attrs), do: create_project(ws_id, attrs)

  def create_project(ws_id, attrs) when is_binary(ws_id) do
    %Project{}
    |> Project.changeset(Map.put(attrs, :workspace_id, ws_id))
    |> Repo.insert()
  end
end
