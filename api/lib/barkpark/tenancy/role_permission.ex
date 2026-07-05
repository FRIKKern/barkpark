defmodule Barkpark.Tenancy.RolePermission do
  @moduledoc """
  One granted action on a `Barkpark.Tenancy.Role` — the permission-set row for
  the USER authorization path. `action` is one of `read` / `write` / `admin`
  (the `Tenancy.Auth` action vocabulary), never a token permission string.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions ~w(read write admin)

  @type t :: %__MODULE__{}

  schema "role_permissions" do
    field :action, :string
    belongs_to :role, Barkpark.Tenancy.Role

    timestamps(type: :utc_datetime_usec)
  end

  def actions, do: @actions

  def changeset(perm, attrs) do
    perm
    |> cast(attrs, [:role_id, :action])
    |> validate_required([:role_id, :action])
    |> validate_inclusion(:action, @actions)
    |> assoc_constraint(:role)
    |> unique_constraint(:action, name: :role_permissions_role_action_idx)
  end
end
