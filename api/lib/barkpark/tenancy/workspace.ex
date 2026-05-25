defmodule Barkpark.Tenancy.Workspace do
  @moduledoc """
  A Workspace is the hard tenant boundary. It owns Projects and Memberships.
  Slug is unique across all workspaces and appears in the routing path.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Slugs that would collide with reserved routing prefixes / system surfaces.
  @reserved_slugs ~w(admin api _plugins studio login media v1 w p)

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "workspaces" do
    field :slug, :string
    field :name, :string

    has_many :projects, Barkpark.Tenancy.Project
    has_many :memberships, Barkpark.Tenancy.Membership

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def reserved_slugs, do: @reserved_slugs

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint(:slug)
  end
end
