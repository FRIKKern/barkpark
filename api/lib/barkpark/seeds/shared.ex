defmodule Barkpark.Seeds.Shared do
  @moduledoc """
  Profile-independent seed groundwork shared by every `Barkpark.Seeds`
  profile: get-or-create of the Default Workspace / Default Project / seed
  dataset row, plus the schema-scope stamp helper. Verbatim extraction of the
  tenancy preamble that lived at the top of `priv/repo/seeds.exs`.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Role, RolePermission}

  @dataset "production"

  # The global built-in USER roles (era-w1-custom-rbac). MUST mirror
  # `Barkpark.Tenancy.Auth`'s compiled-in `@builtin_role_actions` fail-safe —
  # this seed makes them visible as DB rows for custom-role CRUD, while
  # enforcement never depends on the row existing.
  @builtin_roles %{
    "owner" => ~w(read write admin),
    "admin" => ~w(read write admin),
    "member" => ~w(read write)
  }

  @doc "The dataset every seed profile writes into."
  def dataset, do: @dataset

  @doc """
  Idempotently seed the three GLOBAL built-in roles (owner/admin/member) and
  their granted actions. Get-or-create on `(name) where workspace_id IS NULL`;
  action rows are `on_conflict: :nothing`. Safe to run repeatedly.
  """
  def ensure_builtin_roles do
    Enum.each(@builtin_roles, fn {name, actions} ->
      role =
        case Repo.one(from r in Role, where: r.name == ^name and is_nil(r.workspace_id)) do
          nil ->
            {:ok, r} = Repo.insert(Role.changeset(%Role{}, %{name: name, built_in: true}))
            r

          r ->
            r
        end

      Enum.each(actions, fn action ->
        %RolePermission{}
        |> RolePermission.changeset(%{role_id: role.id, action: action})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:role_id, :action])
      end)
    end)

    :ok
  end

  @doc """
  Get-or-create the Default Workspace / Default Project and resolve the
  authoritative `dataset_id` for the seed dataset, printing the scope line.
  Returns `%{workspace_id, project_id, dataset_id, dataset}`.

  Wave 1 tenancy: every seeded schema_definition + document is stamped with
  the Default Workspace / Default Project so a freshly-seeded DB has all
  content under one tenant. The w1-s4 backfill migration seeds these rows on
  `mix ecto.reset` (it runs BEFORE seeds), but seeds also run standalone via
  `mix run priv/repo/seeds.exs` — so reuse Tenancy.get_default_*; create only
  if missing. Idempotent: a present Default is reused, never duplicated.
  """
  def ensure_default_scope do
    default_workspace =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
          ws

        ws ->
          ws
      end

    default_project =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, project} =
            Tenancy.create_project(default_workspace, %{slug: "default", name: "Default Project"})

          project

        project ->
          project
      end

    # Resolve the authoritative `dataset_id` for the seed dataset under the
    # Default project, get-or-creating the dataset row. This is the SAME key
    # the read path resolves to (Content.scope_to_dataset →
    # resolve_read_dataset_id → get_dataset): documents are filtered
    # `WHERE dataset_id = <id>` with NO NULL-fallback, so a seeded doc left
    # with dataset_id = NULL is invisible to every scoped read on a fresh DB.
    # Stamp it onto every seeded document, mirroring
    # Content.resolve_dataset_id_for_write / TenancyFixtures.create_document_in!.
    {:ok, %Barkpark.Tenancy.Dataset{id: default_dataset_id}} =
      Tenancy.get_or_create_dataset(default_project.id, @dataset)

    IO.puts(
      "Default scope: workspace=#{default_workspace.id} project=#{default_project.id} dataset_id=#{default_dataset_id}"
    )

    %{
      workspace_id: default_workspace.id,
      project_id: default_project.id,
      dataset_id: default_dataset_id,
      dataset: @dataset
    }
  end

  @doc """
  Stamp a SchemaDefinition changeset with the Default tenancy scope.

  SchemaDefinition.changeset/2 does not cast the tenancy FKs (they were added
  as belongs_to without a cast slot); put_change them directly so seeded
  schemas land under Default. Documents cast workspace_id/project_id, so those
  go through attrs instead.
  """
  def stamp_schema_scope(changeset, scope) do
    changeset
    |> Ecto.Changeset.put_change(:workspace_id, scope.workspace_id)
    |> Ecto.Changeset.put_change(:project_id, scope.project_id)
  end
end
