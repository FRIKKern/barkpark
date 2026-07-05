defmodule Barkpark.Tenancy.Organization do
  @moduledoc """
  A thin tier ABOVE the Workspace. An Organization groups one or more
  Workspaces so a single enterprise identity connection (SSO/SCIM, later
  waves) maps to a customer that may span several workspaces.

  The tier is additive: a Workspace's `organization_id` is nullable and no
  authorization path reads it yet. Organizations are the anchor future waves
  hang per-org SSO/SCIM connections and policies on.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "organizations" do
    field :slug, :string
    field :name, :string

    has_many :workspaces, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> unique_constraint(:slug)
  end
end
