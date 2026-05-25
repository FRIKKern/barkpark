defmodule Barkpark.Tenancy do
  @moduledoc """
  Context for the Workspace -> Project -> (Dataset) tenancy hierarchy.

  Wave 1 foundation: workspace/project lookup + creation and the Default
  Workspace / Default Project the migration backfills. Query scoping,
  token-binding, and auth enforcement are sibling tasks and live elsewhere.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Workspace, Project, Dataset}

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

  @doc "Fetch a Workspace by its id, or nil. `nil` id returns nil."
  @spec get_workspace_by_id(binary() | nil) :: Workspace.t() | nil
  def get_workspace_by_id(nil), do: nil
  def get_workspace_by_id(id) when is_binary(id), do: Repo.get(Workspace, id)

  @doc "Fetch a Project by its id, or nil. `nil` id returns nil."
  @spec get_project_by_id(binary() | nil) :: Project.t() | nil
  def get_project_by_id(nil), do: nil
  def get_project_by_id(id) when is_binary(id), do: Repo.get(Project, id)

  @doc """
  Resolve the `{workspace_slug, project_slug}` pair for a record carrying
  `workspace_id` / `project_id` columns (a Document, Webhook, …). Falls back
  to the default slug (`"default"`) when an id is `nil` (pre-tenancy /
  unscoped) or when the row no longer exists — keeping the emitted sync-tag
  namespace well-formed in every path.
  """
  @spec resolve_scope_slugs(binary() | nil, binary() | nil) :: {String.t(), String.t()}
  def resolve_scope_slugs(workspace_id, project_id) do
    ws_slug =
      case get_workspace_by_id(workspace_id) do
        %Workspace{slug: slug} -> slug
        nil -> @default_slug
      end

    project_slug =
      case get_project_by_id(project_id) do
        %Project{slug: slug} -> slug
        nil -> @default_slug
      end

    {ws_slug, project_slug}
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

  @doc "List all Workspaces, ordered by slug."
  @spec list_workspaces() :: [Workspace.t()]
  def list_workspaces do
    Repo.all(from w in Workspace, order_by: w.slug)
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

  # --- Datasets (Wave 2) ----------------------------------------------------
  #
  # A Dataset lives under a Project; it promotes the plain `dataset` string to
  # a row. Additive seam only — the string stays authoritative for now.

  @doc "Fetch a Dataset by its id, or nil. `nil` id returns nil."
  @spec get_dataset_by_id(binary() | nil) :: Dataset.t() | nil
  def get_dataset_by_id(nil), do: nil
  def get_dataset_by_id(id) when is_binary(id), do: Repo.get(Dataset, id)

  @doc """
  Fetch a Dataset by its Project (struct or id) + slug. Returns nil when the
  Project has no Dataset with that slug.
  """
  @spec get_dataset(Project.t() | binary(), String.t()) :: Dataset.t() | nil
  def get_dataset(%Project{id: project_id}, slug), do: get_dataset(project_id, slug)

  def get_dataset(project_id, slug) when is_binary(project_id) and is_binary(slug) do
    Repo.get_by(Dataset, project_id: project_id, slug: slug)
  end

  @doc "List all Datasets under a Project (accepts a struct or a project id), ordered by slug."
  @spec list_datasets(Project.t() | binary()) :: [Dataset.t()]
  def list_datasets(%Project{id: project_id}), do: list_datasets(project_id)

  def list_datasets(project_id) when is_binary(project_id) do
    Repo.all(from d in Dataset, where: d.project_id == ^project_id, order_by: d.slug)
  end

  @doc """
  Create a Dataset under the given Project (struct or id). The project_id in
  `attrs` is overridden by the resolved project.
  """
  @spec create_dataset(Project.t() | binary(), map()) ::
          {:ok, Dataset.t()} | {:error, Ecto.Changeset.t()}
  def create_dataset(%Project{id: project_id}, attrs), do: create_dataset(project_id, attrs)

  def create_dataset(project_id, attrs) when is_binary(project_id) do
    %Dataset{}
    |> Dataset.changeset(Map.put(attrs, :project_id, project_id))
    |> Repo.insert()
  end

  @doc """
  Fetch the Dataset with `slug` under `project` (struct or id), creating it
  (slug = name = slug) when absent. Returns `{:ok, dataset}` or
  `{:error, changeset}`. Tolerates a concurrent insert by re-fetching on the
  unique-constraint conflict.
  """
  @spec get_or_create_dataset(Project.t() | binary(), String.t()) ::
          {:ok, Dataset.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_dataset(%Project{id: project_id}, slug),
    do: get_or_create_dataset(project_id, slug)

  def get_or_create_dataset(project_id, slug)
      when is_binary(project_id) and is_binary(slug) do
    case get_dataset(project_id, slug) do
      %Dataset{} = dataset ->
        {:ok, dataset}

      nil ->
        case create_dataset(project_id, %{slug: slug, name: slug}) do
          {:ok, dataset} ->
            {:ok, dataset}

          {:error, changeset} ->
            # Lost a race — the row now exists; re-fetch rather than surface
            # the unique-constraint error.
            case get_dataset(project_id, slug) do
              %Dataset{} = dataset -> {:ok, dataset}
              nil -> {:error, changeset}
            end
        end
    end
  end
end
