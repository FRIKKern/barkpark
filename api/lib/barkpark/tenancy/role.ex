defmodule Barkpark.Tenancy.Role do
  @moduledoc """
  A named role for USER principals (era-w1-custom-rbac). A `nil` `workspace_id`
  is a GLOBAL built-in (owner/admin/member); a set one is a custom role scoped
  to that workspace. The granted actions live in `role_permissions`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9-]*$/

  @type t :: %__MODULE__{}

  schema "roles" do
    field :workspace_id, Ecto.UUID
    field :name, :string
    field :built_in, :boolean, default: false

    has_many :permissions, Barkpark.Tenancy.RolePermission

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:workspace_id, :name, :built_in])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 63)
    |> validate_format(:name, @name_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> unique_constraint(:name, name: :roles_workspace_name_idx)
    |> unique_constraint(:name, name: :roles_global_name_idx)
  end
end
