defmodule Barkpark.Tenancy.Project do
  @moduledoc """
  A Project lives under exactly one Workspace. Slug is unique within its
  Workspace (not globally) and appears in the routing path after the
  workspace slug.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @reserved_slugs ~w(admin api _plugins studio login media v1 w p)

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "projects" do
    field :slug, :string
    field :name, :string

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def reserved_slugs, do: @reserved_slugs

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:slug, :name, :workspace_id])
    |> validate_required([:slug, :name, :workspace_id])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> assoc_constraint(:workspace)
    |> unique_constraint([:slug, :workspace_id],
      name: :projects_workspace_id_slug_index,
      message: "already exists in this workspace"
    )
  end
end
