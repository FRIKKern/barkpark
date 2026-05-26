defmodule Barkpark.Tenancy do
  @moduledoc """
  Context for the Workspace -> Project -> (Dataset) tenancy hierarchy.

  Wave 1 foundation: workspace/project lookup + creation and the Default
  Workspace / Default Project the migration backfills. Query scoping,
  token-binding, and auth enforcement are sibling tasks and live elsewhere.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.{Workspace, Project, Dataset, Membership}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @default_slug "default"
  @default_project_slug "default"
  @default_project_name "Default Project"
  @production_dataset_slug "production"

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

  @doc """
  List the Workspaces a principal is a MEMBER of, ordered by slug.

  Accepts an `%ApiToken{}` struct or a raw principal id binary. The hard
  tenant boundary: the query INNER-JOINs `workspace_memberships` on
  `principal_id == <token id>` (and `principal_type == "api_token"`), so a
  workspace the caller has no membership row in can never appear — there is no
  unscoped fallback. A nil/unknown principal yields `[]`.
  """
  @spec list_workspaces_for(ApiToken.t() | binary() | nil) :: [Workspace.t()]
  def list_workspaces_for(%ApiToken{id: principal_id}), do: list_workspaces_for(principal_id)

  def list_workspaces_for(principal_id) when is_binary(principal_id) do
    Repo.all(
      from w in Workspace,
        join: m in Membership,
        on: m.workspace_id == w.id,
        where: m.principal_id == ^principal_id and m.principal_type == "api_token",
        order_by: w.slug
    )
  end

  def list_workspaces_for(_), do: []

  @doc "List all Projects under a Workspace (accepts a struct or a workspace id)."
  @spec list_projects(Workspace.t() | binary()) :: [Project.t()]
  def list_projects(%Workspace{id: ws_id}), do: list_projects(ws_id)

  def list_projects(ws_id) when is_binary(ws_id) do
    # Order the canonical `default`-slug project FIRST, then the rest
    # alphabetically. This makes every consumer that takes the first project
    # (web's `projects[0]` from `listProjects`, the switcher, studio mount via
    # `initial_project/1`) resolve the same canonical default. The boolean
    # `slug = 'default'` sorts DESC (true before false), then `slug` ASC.
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^ws_id,
        order_by: [desc: fragment("? = 'default'", p.slug), asc: p.slug]
    )
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

  @doc """
  Bootstrap a brand-new, immediately-usable Workspace for the creating token,
  atomically (single `Repo.transaction`):

    1. the Workspace itself,
    2. a Membership binding the api_token as `"owner"`,
    3. a Default Project, and
    4. a "production" Dataset under that project.

  `attrs` carries `:name` (required) and an optional `:slug` — when the slug is
  absent it is derived from the name (`slugify/1`). `owner_token` is the
  authenticated `%ApiToken{}` (or its id) calling POST /api/workspaces.

  Returns `{:ok, workspace}` with the freshly-created Default Project
  preloaded under `workspace.projects` (and the Dataset under that project's
  `:datasets`) so the controller can render them without a reload, or
  `{:error, changeset}`. A duplicate workspace slug surfaces as a clean
  changeset error on the unique constraint.
  """
  @spec create_workspace_with_owner(map(), ApiToken.t() | binary()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace_with_owner(attrs, %ApiToken{id: principal_id}),
    do: create_workspace_with_owner(attrs, principal_id)

  def create_workspace_with_owner(attrs, principal_id) when is_binary(principal_id) do
    ws_attrs = put_derived_slug(attrs)

    Repo.transaction(fn ->
      with {:ok, workspace} <- create_workspace(ws_attrs),
           {:ok, _membership} <-
             TenancyAuth.create_membership(workspace.id, principal_id, "owner"),
           {:ok, project} <-
             create_project(workspace, %{
               slug: @default_project_slug,
               name: @default_project_name
             }),
           {:ok, dataset} <-
             create_dataset(project, %{
               slug: @production_dataset_slug,
               name: @production_dataset_slug
             }) do
        _ = dataset
        %{workspace | projects: [project]}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Create a Project under `workspace` PLUS its "production" Dataset, atomically.
  `attrs` carries `:name` (required) and an optional `:slug` (derived from the
  name when absent). Returns `{:ok, project}`, or `{:error, changeset}`
  (project slug collides within the workspace → clean unique-constraint error).
  The "production" Dataset is created in the same transaction.
  """
  @spec create_project_with_dataset(Workspace.t() | binary(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project_with_dataset(%Workspace{id: ws_id}, attrs),
    do: create_project_with_dataset(ws_id, attrs)

  def create_project_with_dataset(ws_id, attrs) when is_binary(ws_id) do
    project_attrs = put_derived_slug(attrs)

    Repo.transaction(fn ->
      with {:ok, project} <- create_project(ws_id, project_attrs),
           {:ok, _dataset} <-
             create_dataset(project, %{
               slug: @production_dataset_slug,
               name: @production_dataset_slug
             }) do
        project
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Ensure `attrs` carries a :slug, deriving it from :name when absent/blank.
  # Leaves an explicit slug untouched (the changeset validates its format).
  defp put_derived_slug(attrs) do
    case slug_value(attrs) do
      slug when is_binary(slug) and slug != "" ->
        attrs

      _ ->
        Map.put(attrs, slug_key(attrs), slugify(name_value(attrs)))
    end
  end

  defp slug_value(attrs), do: Map.get(attrs, :slug) || Map.get(attrs, "slug")
  defp name_value(attrs), do: Map.get(attrs, :name) || Map.get(attrs, "name") || ""
  defp slug_key(attrs), do: if(Map.has_key?(attrs, "name"), do: "slug", else: :slug)

  @doc """
  Slugify a name into a workspace/project slug: downcase, collapse any run of
  non-alphanumerics to a single hyphen, trim leading/trailing hyphens. Returns
  `""` for an all-symbol/blank input — the changeset's `validate_required` +
  `validate_format` then surface a clean error.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def slugify(_), do: ""

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
    # `on_conflict: :nothing` keeps a concurrent duplicate insert from ABORTING
    # the surrounding Postgres transaction (apply_mutations wraps this call). On
    # a hit the DB skips the row and Ecto STILL returns {:ok, struct} — but that
    # struct carries the changeset's autogenerated binary_id, NOT the existing
    # row's id, so it can't be trusted as "the persisted row". Callers that need
    # the real row (get_or_create_dataset) reload via get_dataset after :ok.
    # `conflict_target` matches the `datasets_project_id_slug_index` unique index
    # (project_id, slug).
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:project_id, :slug])
  end

  @doc """
  Fetch the Dataset with `slug` under `project` (struct or id), creating it
  (slug = name = slug) when absent. Returns `{:ok, dataset}` or
  `{:error, changeset}`. Tolerates a concurrent insert via `on_conflict:
  :nothing` (see `create_dataset/2`) — a duplicate insert is a no-op that does
  NOT abort the surrounding transaction, and we re-fetch the existing row. This
  matters because the call runs inside `apply_mutations`' `Repo.transaction`;
  letting the unique constraint raise would poison the whole transaction.
  """
  @spec get_or_create_dataset(Project.t() | binary(), String.t()) ::
          {:ok, Dataset.t()} | {:error, Ecto.Changeset.t() | :dataset_not_found}
  def get_or_create_dataset(%Project{id: project_id}, slug),
    do: get_or_create_dataset(project_id, slug)

  def get_or_create_dataset(project_id, slug)
      when is_binary(project_id) and is_binary(slug) do
    case get_dataset(project_id, slug) do
      %Dataset{} = dataset ->
        {:ok, dataset}

      nil ->
        case create_dataset(project_id, %{slug: slug, name: slug}) do
          # Insert returned :ok — but with `on_conflict: :nothing` a duplicate is
          # a SILENT no-op: Ecto hands back the changeset's struct carrying the
          # autogenerated (unpersisted) binary_id, NOT the existing row's id. We
          # can't distinguish "I inserted" from "conflict swallowed" by the id
          # alone, so always reload via get_dataset to return the row that's
          # actually in the DB. The conflict no longer aborts the surrounding
          # transaction, so this re-fetch is safe.
          {:ok, %Dataset{}} ->
            case get_dataset(project_id, slug) do
              %Dataset{} = dataset -> {:ok, dataset}
              nil -> {:error, :dataset_not_found}
            end

          # Changeset validation failed before reaching the DB (e.g. invalid
          # slug) — surface it; the transaction was never touched.
          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Resolve a bare dataset/scope STRING → its `dataset_id` under the seeded
  Default project, get-or-creating the dataset row. Returns the id, or nil when
  the Default project isn't seeded yet (fresh sandbox). Used by single-project
  surfaces (search-intel synonyms / crystals / merge-patterns) whose only scope
  key is the legacy STRING — the W2 dual-write threads the resolved id alongside
  it so the flipped `(surface, dataset_id, …)` uniques stay meaningful.
  """
  @spec default_project_dataset_id(String.t()) :: binary() | nil
  def default_project_dataset_id(slug) when is_binary(slug) do
    case get_default_project() do
      %Project{id: project_id} ->
        case get_or_create_dataset(project_id, slug) do
          {:ok, %Dataset{id: id}} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def default_project_dataset_id(_), do: nil
end
