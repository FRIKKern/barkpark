defmodule Barkpark.Scim.Group do
  @moduledoc """
  A SCIM Group scoped to an Organization. `role_name` is the Barkpark role the
  group grants to its members (a built-in owner/admin/member or a custom role).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "scim_groups" do
    field :display_name, :string
    field :role_name, :string
    field :external_id, :string

    belongs_to :organization, Barkpark.Tenancy.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:organization_id, :display_name, :role_name, :external_id])
    |> validate_required([:organization_id, :display_name, :role_name])
    |> assoc_constraint(:organization)
    |> unique_constraint(:display_name, name: :scim_groups_org_display_idx)
  end
end
